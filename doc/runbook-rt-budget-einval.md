# Runbook: RT pods fail with `cpu.rt_runtime_us: invalid argument`

Use this when RT (KubeDeadline / SCHED_DEADLINE) pods that **used to work** suddenly
fail to start, especially after running experiments.

## Symptom

A pod stays crash-looping and the events show a runc error like:

```
failed to create containerd task: ... error setting cgroup config for procHooks process:
failed to write "100 2":
write /sys/fs/cgroup/kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod<UID>.slice/cri-containerd-<id>.scope/cpu.rt_runtime_us:
invalid argument
```

(`FailedPrepareDynamicResources ... rtCDIDevices is nil or incomplete` is a *separate*,
transient driver CDI-cache race — it self-heals and is not this problem.)

## Root cause

The RT budget lives in a chain of cgroups:

```
/sys/fs/cgroup                              (root)
  └─ kubepods.slice
       └─ kubepods-besteffort.slice
            └─ kubepods-besteffort-pod<UID>.slice   (per-pod)
                 └─ cri-containerd-<id>.scope        (container leaf)
```

The kernel enforces, **per CPU**, `Σ(children rt_runtime) ≤ parent rt_runtime`.
If **any ancestor** holds `0` (or has no budget on the specific core the pod is
pinned to), then every descendant write on that core fails with `EINVAL`
(`invalid argument`).

Running experiments / manual resets **zero out** these ancestor slices (and can
pollute `cpu.rt_period_us` to a stale `1000` left over from a small-period test
pod). Once `root` / `kubepods` / `kubepods-besteffort` read `0`, no RT pod can
start. This is **not** a code bug — it is a wiped node RT budget.

Key facts about this custom H-CBS kernel (cgroup v2 / unified):

- The **root cgroup** `cpu.rt_runtime_us` **is enforced** (not cosmetic). If root
  is `0`, nothing below it can be raised.
- `cpu.rt_runtime_us` **writes accept only per-core pairs** `"<runtime> <cpu> <runtime> <cpu> ..."`.
  A bare scalar like `950000` is rejected with `EINVAL`.
- `cpu.rt_runtime_us` **reads** return a positional per-core array (index = cpu id),
  e.g. `950000 950000 950000 950000`.
- You must write `cpu.rt_period_us` **before** `cpu.rt_runtime_us` (writing a
  non-zero runtime while the period is `0` fails with `EINVAL`).

## Diagnosis

On the worker node, dump the whole chain:

```bash
echo "== root ==";       cat /sys/fs/cgroup/cpu.rt_runtime_us; cat /sys/fs/cgroup/cpu.rt_period_us
echo "== kubepods ==";   cat /sys/fs/cgroup/kubepods.slice/cpu.rt_runtime_us; cat /sys/fs/cgroup/kubepods.slice/cpu.rt_period_us
echo "== besteffort =="; cat /sys/fs/cgroup/kubepods.slice/kubepods-besteffort.slice/cpu.rt_runtime_us; cat /sys/fs/cgroup/kubepods.slice/kubepods-besteffort.slice/cpu.rt_period_us
echo "== global ==";     cat /proc/sys/kernel/sched_rt_runtime_us; cat /proc/sys/kernel/sched_rt_period_us
```

If any level's `rt_runtime_us` reads `0`, or a `rt_period_us` reads `1000`
(polluted), that level is the break. The global sysctl is normally
`1000000 / 1000000` (100%) — that is the overall ceiling.

## Fix (recovery)

Do this on the worker node **with all RT pods deleted first** (from the control
plane: `kubectl delete -f <manifest>` or delete the test namespace). Then seed
**top-down** (root → kubepods → besteffort), period **before** runtime, using
per-core pairs for every cpu on the node.

This node has 4 cpus (`0-3`); the budget is `950000/1000000` = 95% per core.

```bash
KP=/sys/fs/cgroup/kubepods.slice
BE=$KP/kubepods-besteffort.slice
PAIRS="950000 0 950000 1 950000 2 950000 3"     # one "<runtime> <cpu>" pair per cpu

# 1) period first, everywhere (fixes any stale period=1000)
echo 1000000 | sudo tee /sys/fs/cgroup/cpu.rt_period_us
echo 1000000 | sudo tee $KP/cpu.rt_period_us
echo 1000000 | sudo tee $BE/cpu.rt_period_us

# 2) runtime, TOP-DOWN (root must be raised before its children)
echo "$PAIRS" | sudo tee /sys/fs/cgroup/cpu.rt_runtime_us
echo "$PAIRS" | sudo tee $KP/cpu.rt_runtime_us
echo "$PAIRS" | sudo tee $BE/cpu.rt_runtime_us

# 3) verify — each should read "950000 950000 950000 950000"
grep -H . \
  /sys/fs/cgroup/cpu.rt_runtime_us \
  $KP/cpu.rt_runtime_us \
  $BE/cpu.rt_runtime_us
```

Troubleshooting the recovery:

- **`tee: ... Invalid argument`** on `kubepods`/`besteffort` → the parent above it
  is still `0`. Seed **root first** (step 2 already does this; run it in order).
- **`Invalid argument` even on root** → you passed a scalar. Use the per-core
  **pairs** format (`950000 0 950000 1 ...`), never a bare `950000`.
- **`Invalid argument` writing runtime** while period looks fine → make sure the
  period write happened first (step 1) and is non-zero.
- A leftover **child scope** may still hold a stale reservation; find and clear it:
  ```bash
  grep -H . $BE/*/cpu.rt_runtime_us 2>/dev/null   # find non-zero children
  echo 0 | sudo tee <that child>/cpu.rt_runtime_us
  ```

After the chain reads `950000` at all three levels, re-apply your manifest. The
container leaf write (e.g. `100 2`) now fits under its ancestors.

## After recovery: redeploy runc (if needed)

```bash
cd ~/runc && make \
  && sudo install -m0755 runc /usr/local/sbin/runc \
  && sudo systemctl restart containerd
```

Then verify:

```bash
sudo ./demo/tests/verify-rt.sh
```

## Why runc alone does not prevent this

The fixed runc (`fs2/cpu.go`) accumulates the **pod slice and ancestors per-core**
each time a container starts (`childrenSum`; `kubepods` keeps existing values as a
floor, `besteffort` self-heals stale values). But runc **does not restore the
`950000` node cap** on `root` / `kubepods` / `kubepods-besteffort` — that node-level
budget is seeded once at node setup. Whenever an experiment zeroes it, you must
re-seed with the steps above (or a `reset-rt.sh` that runs them automatically).

## One-line summary

The RT budget chain `root → kubepods → besteffort` got zeroed; because the kernel
enforces `Σ(children) ≤ parent` per core, a parent at `0` makes every child write
`EINVAL`. Re-seed **top-down**, **period before runtime**, using **per-core pairs**
(`950000 <cpu>` for every cpu), and the pods work again.
