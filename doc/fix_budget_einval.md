# RT pods fail to start: `cpu.rt_runtime_us: invalid argument` / `device or resource busy`

When an RT (KubeDeadline / SCHED_DEADLINE) pod fails to start and the events show
a runc error like:

```
failed to create containerd task: ... error setting cgroup config for procHooks process:
failed to write "100 2":
write /sys/fs/cgroup/kubepods.slice/kubepods-besteffort.slice/.../cpu.rt_runtime_us:
invalid argument            # EINVAL
```
or the seeding write itself returns `Device or resource busy` (`EBUSY`).

(The separate warning `FailedPrepareDynamicResources ... rtCDIDevices is nil or
incomplete` is a transient DRA driver CDI-cache race — it self-heals and is *not*
this problem.)

---

## 1. Why this happens

RT bandwidth is stored in a chain of cgroups, and the kernel enforces, **per
CPU**, `Σ(children rt_runtime) ≤ parent rt_runtime`:

```
/sys/fs/cgroup                              (root)
  └─ kubepods.slice
       └─ kubepods-besteffort.slice
            └─ kubepods-besteffort-pod<UID>.slice   (per-pod, runc)
                 └─ cri-containerd-<id>.scope        (container leaf, runc)
```

The budget on `root` / `kubepods` / `kubepods-besteffort` lives **only in kernel
memory** — it is never persisted. It resets to `0` on every **reboot**, **VM
reallocation**, **new VM**, or **new kernel**. Once an ancestor is `0`, every
descendant write fails, so the container leaf write (e.g. `100 2` = 100µs on cpu
2) is rejected.

On the current kernel (`HCBS-patch`, branch `rt-cgroups-multi`) there are three
extra rules that shape the exact error:

1. **The root cgroup must be a scalar** — the same runtime/period on *all* CPUs.
   Writing per-core pairs (`950000 0 950000 1 ...`) to the root fails `EINVAL`
   ("root cgroup runtime/period mismatch") because any CPU you don't list stays
   `0`. (Non-root levels *may* use per-core values; only the root must be
   uniform.)
2. **`cpu.rt_period_us` must be written before `cpu.rt_runtime_us`** — writing a
   non-zero runtime while the period is still `0` fails `EINVAL`.
3. **Setting the root RT budget reserves SCHED_DEADLINE bandwidth**, checked by
   `dl_check_tg`. It fails with **`EBUSY`** if the request does not fit under the
   free DL budget: `dl_bw->bw − dl_bw->total_bw`. The kernel keeps a per-CPU DL
   "fair server" reservation (`total_bw ≈ 0.20`) for normal (CFS) tasks, so the
   usable RT ceiling is *below* 100%.

So the two errors mean:

- **`EINVAL`** → an ancestor is `0` on the needed CPU (chain not seeded), or the
  root got per-core pairs instead of a scalar, or runtime written before period.
- **`EBUSY`** → the root RT request exceeds the free DL bandwidth
  (`bw − total_bw`); something already holds DL bandwidth.

---

## 2. How to find out (diagnosis)

On the worker node:

```bash
# (a) Is the chain seeded? Any level reading 0 (or period 1000) is the break.
echo "== root ==";       cat /sys/fs/cgroup/cpu.rt_runtime_us; cat /sys/fs/cgroup/cpu.rt_period_us
echo "== kubepods ==";   cat /sys/fs/cgroup/kubepods.slice/cpu.rt_runtime_us; cat /sys/fs/cgroup/kubepods.slice/cpu.rt_period_us
echo "== besteffort =="; cat /sys/fs/cgroup/kubepods.slice/kubepods-besteffort.slice/cpu.rt_runtime_us; cat /sys/fs/cgroup/kubepods.slice/kubepods-besteffort.slice/cpu.rt_period_us

# (b) DL budget: how much RT can the root actually take?  free = bw - total_bw
sudo grep -iE "dl_bw->bw|total_bw" /sys/kernel/debug/sched/debug | sort -u

# (c) Global RT limit (sets dl_bw->bw): 950000 => 95% cap, 1000000 => 100% cap
cat /proc/sys/kernel/sched_rt_runtime_us
cat /proc/sys/kernel/sched_rt_period_us

# (d) Any real-time tasks still holding bandwidth? (kernel FF threads are normal)
ps -eLo pid,cls,rtprio,comm | grep -w DLN
```

Interpreting `dl_bw` values (fixed-point, unit `1 << 20 = 1048576`):

| reading | meaning |
|---------|---------|
| `dl_bw->bw = 1048576` | RT/DL cap = 100% (`sched_rt_runtime_us = 1000000`) |
| `dl_bw->bw = 996147`  | RT/DL cap = 95%  (`sched_rt_runtime_us = 950000`)  |
| `dl_bw->total_bw = 209712` | ~0.20 already reserved (kernel DL fair server) |
| free budget | `bw − total_bw` → the max ratio the root RT can take |

Example: `bw=996147`, `total_bw=209712` → free `≈ 0.75`, so the root can hold at
most ~`750000/1000000`. Requesting `950000` there → `EBUSY`.

---

## 3. Consequences

- **Until seeded, no RT pod starts** on that node — it crash-loops with the
  `EINVAL`/`EBUSY` above. Non-RT pods are unaffected.
- **The usable RT ceiling per node = `bw − total_bw`**, not the full CPU. With a
  0.20 fair-server reservation and a 95% cap, that is ~0.75; with a 100% cap,
  higher.
- **Different nodes can differ.** `sched_rt_runtime_us` may be `950000` on one VM
  and `1000000` on another, so the same seed value can be accepted on one node
  and rejected on another. Align it (section 6) for uniform behaviour.
- **Per-container enforcement is never affected by this.** Each container's CBS
  server is still throttled to its own `(Q, P)`; this problem is only about the
  *ancestor* budget needed to admit the reservation.

---

## 4. How to fix it

### Recommended: run the seeding script

`dra-rt-driver/demo/tests/rt-seed.sh` reads the DL budget, picks the largest root
runtime the kernel accepts, and seeds `root → kubepods → besteffort` correctly
(scalar root, period before runtime):

```bash
cd dra-rt-driver/demo/tests
sudo ./rt-seed.sh            # optional arg: period in us (default 1000000)
```

Expected tail:
```
[rt-seed] root seeded at 700000us / 1000000us     # or 950000 where there is room
/sys/fs/cgroup/cpu.rt_runtime_us:700000
/sys/fs/cgroup/kubepods.slice/cpu.rt_runtime_us:700000
/sys/fs/cgroup/kubepods.slice/kubepods-besteffort.slice/cpu.rt_runtime_us:700000
```

Then (re)apply your RT pod and verify:
```bash
kubectl delete ns rt-verify --ignore-not-found
kubectl apply -f <rt-verify manifest>
sudo ./verify-rt.sh
```

### Manual equivalent (if you prefer)

Delete RT pods first, then seed top-down, **scalar**, period before runtime:
```bash
KP=/sys/fs/cgroup/kubepods.slice
BE=$KP/kubepods-besteffort.slice
echo 1000000 | sudo tee /sys/fs/cgroup/cpu.rt_period_us $KP/cpu.rt_period_us $BE/cpu.rt_period_us
# use a value that fits under (bw - total_bw): 950000 if room, else 700000
echo 700000  | sudo tee /sys/fs/cgroup/cpu.rt_runtime_us
echo 700000  | sudo tee $KP/cpu.rt_runtime_us
echo 700000  | sudo tee $BE/cpu.rt_runtime_us
grep -H . /sys/fs/cgroup/cpu.rt_runtime_us $KP/cpu.rt_runtime_us $BE/cpu.rt_runtime_us
```

### Troubleshooting

| symptom | cause | action |
|---------|-------|--------|
| `EINVAL` on `kubepods`/`besteffort` | root still `0` | seed root first (top-down) |
| `EINVAL` on root with per-core pairs | root needs a scalar | write a bare value, not `950000 0 ...` |
| `EINVAL` writing runtime | period was `0` | write `cpu.rt_period_us` first |
| `EBUSY` on root even when seeding low | leftover / kernel DL reservation | check `total_bw`; delete RT pods; if it survives a reboot it is the kernel fair server → seed below `bw − total_bw` |

If `total_bw` stays non-zero after deleting all RT pods **and** survives a reboot,
it is the kernel's DL fair server (expected) — just seed under the free budget.
If it is non-zero because of a *leaked* reservation from a killed experiment (no
owning task, cleared by reboot), reboot to reclaim it.

---

## 5. Do I have to re-seed on every VM / reboot?

**Yes.** The budget is not persisted, so re-seed after every **reboot**, **VM
reallocation/deallocation**, **new VM**, or **new kernel**. Ordinary pod
create/delete does **not** need re-seeding (runc maintains the pod/leaf levels).

Automate it with a systemd oneshot on each worker so it runs on every boot:

```ini
# /etc/systemd/system/rt-seed.service
[Unit]
Description=Seed RT (H-CBS) cgroup budget after boot
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rt-seed.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

Install once per node:
```bash
sudo install -m0755 dra-rt-driver/demo/tests/rt-seed.sh /usr/local/sbin/rt-seed.sh
sudo cp <the unit above> /etc/systemd/system/rt-seed.service
sudo systemctl enable --now rt-seed.service
```

---

## 6. Background: `sched_rt_runtime_us`, the DL server, and enforcement guarantees

`dl_bw->bw` (the DL admission cap) is derived from
`sched_rt_runtime_us / sched_rt_period_us`:

- **`sched_rt_runtime_us = 1000000`** (period `1000000`) → cap = **100%**
  (`dl_bw->bw = 1048576`). Throttling/accounting is still **active**; the ceiling
  is just the whole CPU. (worker-2)
- **`sched_rt_runtime_us = 950000`** → cap = **95%** (`dl_bw->bw = 996147`).
  (worker-0 — which is why worker-0 accepted only `700000` while worker-2 took
  `950000`.)
- **`sched_rt_runtime_us = -1`** → `RUNTIME_INF`: RT throttling **and DL admission
  control are disabled**. `dl_check_tg` is guarded by `if (dl_b->bw != -1 && ...)`,
  so with `-1` the check is **skipped** — over-commit becomes possible and the
  per-CPU bandwidth guarantee is lost. **`1000000` is *not* the same as `-1`;**
  do not use `-1` if you rely on isolation.

Running at 100% (`1000000`):

1. **Per-container CBS enforcement is unaffected** — each container's DEADLINE/CBS
   server is still throttled to its own `(Q, P)`, independent of the global value.
2. **DL admission still guards over-commit** — because `bw = 100%` (not `-1`), the
   kernel still rejects reservations beyond the budget (the `EBUSY` path).
3. **CFS/non-RT starvation protection moves to the DL "fair server."** The classic
   5% RT-throttle margin is gone at 100%, but the kernel reserves ~**0.20** of DL
   bandwidth per CPU (`total_bw`) for the fair/CFS server, keeping normal tasks
   (kubelet, daemons) alive under RT load. Confirm it exists on every node:
   ```bash
   sudo grep -iE "dl_bw->bw|total_bw" /sys/kernel/debug/sched/debug | sort -u
   ```
   A node with `total_bw = 0` **and** `sched_rt_runtime_us = 1000000` has **no**
   CFS protection under RT load — treat that as a red flag.

Make budgets uniform across the cluster and persist the limit:
```bash
echo 'kernel.sched_rt_runtime_us = 1000000' | sudo tee /etc/sysctl.d/99-rt.conf
sudo sysctl --system
```