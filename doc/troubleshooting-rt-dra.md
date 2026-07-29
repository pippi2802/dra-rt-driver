# RT-DRA / KubeDeadline Troubleshooting Log

This document records the problems we hit while building the real-time (RT)
SCHED_DEADLINE/CBS pipeline across `runc`, the `dra-rt-driver`, and the demo
manifests — and how each one was solved.

## Architecture recap (so the fixes make sense)

- **Kubernetes 1.28 + DRA**: the driver returns CDI devices. Our custom
  containerd parses the CDI device **name**
  `runtime-R.period-P/CPUSET=cpus` to learn the reservation and cpuset.
- **Two-level H-CBS model** (Samimi et al., ECRTS 2025):
  - **Level 1** — the cgroup itself becomes a `SCHED_DEADLINE`/CBS server that
    the kernel builds automatically from `cpu.rt_runtime_us` / `cpu.rt_period_us`.
  - **Level 2** — the tasks inside run `SCHED_FIFO` priority 90.
  - Reservation is `(Q, P, m)` = `(runtime, period, cores)`.
- **Division of responsibility (firm rule):** *cgroup management belongs to
  `runc`*; the driver and kubelet only create the CDI spec and hand it to
  containerd for parsing.
- **cgroup v2 unified** (`cgroup2fs`) → `runc` `fs2` driver.
  - `cpu.rt_runtime_us` **writes** accept per-core **pairs**
    `<runtime> <cpu> <runtime> <cpu> ...`.
  - `cpu.rt_runtime_us` **reads** return a **positional per-core array** indexed
    by cpu. e.g. writing `"100 1 100 2"` reads back as `"0 100 100 0"`
    (cpu0=0, cpu1=100, cpu2=100, cpu3=0).
  - You **must write `cpu.rt_period_us` before `cpu.rt_runtime_us`** or the
    kernel returns `EINVAL`.
- **Kernel budget rule:** for every core, `Σ(children rt_runtime) ≤ parent
  rt_runtime`. There is **no** automatic parent→child propagation; each level
  must be seeded.
- **Slice hierarchy:** `kubepods.slice` / `kubepods-besteffort.slice` carry the
  node RT budget (`950000/1000000`, i.e. 95% on all cores). Per-pod slices and
  per-container scopes are created at `0/0` and must be seeded by `runc`.
- **RT/DEADLINE admission control must be OFF** (`kernel.sched_rt_runtime_us =
  -1`) on the HCBS `7.0.0+` kernel, or the *root* cgroup RT write is refused and
  nothing below it can be seeded — see Problem 0.

---

## Problem 0 — root cgroup RT budget can't be seeded (`EBUSY` / `dl check tg`)

**Symptom.** On the HCBS `7.0.0+` kernel, seeding the RT chain fails at the very
top: writing `/sys/fs/cgroup/cpu.rt_runtime_us` returns `Device or resource busy`
(EBUSY) and the file stays `0`; every child write (`kubepods.slice`, a container
leaf) then fails `Invalid argument` (EINVAL). `dmesg` shows:

```
tg_rt_schedulable fail at 0: children bw 996147 > parent bw 0
tg_rt_schedulable fail: dl check tg
Set Bw Fail: __rt_schedulable
```

Downstream this surfaces as pod events like
`NodePrepareResources failed … rtCDIDevices is nil or incomplete` and
`runc create failed … cpu.rt_runtime_us: invalid argument`.

**Root cause.** The kernel's RT-bandwidth **admission control**. With a *finite*
global RT runtime — this includes **both** `sched_rt_runtime_us = 950000` **and**
`sched_rt_runtime_us == sched_rt_period_us` (e.g. both `1000000`) — the
`tg_rt_schedulable` / `dl check tg` admission test refuses to convert the **root**
task group's RT bandwidth, so the root stays at `0`. Because the kernel enforces
`Σ(children) ≤ parent` per core, a root of `0` makes every descendant write fail.
The root cgroup-v2 file cannot be written directly (EBUSY), and the scalar global
sysctl does **not** populate the root's per-core array while admission is on.

**Things that look like the cause but are NOT:** CPU offline/online, a guest
reboot, an Azure deallocate/reallocate, a stale NAS, a leftover `-1` sysctl, or a
runc/driver change. All were ruled out — a fresh deallocated node with all CPUs
online still failed until admission control was turned off.

**Solution.** Set **`kernel.sched_rt_runtime_us = -1`** (RUNTIME_INF), which
bypasses the admission check, then seed the parents **top-down, scalar**:

```bash
sudo sysctl -w kernel.sched_rt_runtime_us=-1
for d in /sys/fs/cgroup \
         /sys/fs/cgroup/kubepods.slice \
         /sys/fs/cgroup/kubepods.slice/kubepods-besteffort.slice; do
  echo 1000000 | sudo tee "$d/cpu.rt_period_us"
  echo 950000  | sudo tee "$d/cpu.rt_runtime_us"
done
# all three cpu.rt_runtime_us now read 950000
```

The per-cgroup CBS/DEADLINE servers built from `cpu.rt_runtime_us` still throttle
each group, so RT enforcement (and the `rt-verify` / model1 sweeps) works under
`-1`. Make it permanent with
[`demo/scripts/99-rt-budget.conf`](../dra-rt-driver/demo/scripts/99-rt-budget.conf)
(sets `sched_rt_runtime_us = -1`) and the
[`rt-budget-seed`](../dra-rt-driver/demo/scripts/rt-budget-seed.service) systemd
unit (seeds `root → kubepods → besteffort` on every boot). **Never** set a finite
`sched_rt_runtime_us`, and never offline/online CPUs at runtime — isolate at boot.

---

## Problem 1 — RT parameters not applied to *all* containers in a pod

**Symptom.** In a multi-container pod, only one container received its
`cpu.rt_runtime_us` reservation. The sibling container showed
`cpu.rt_runtime_us = 0`, so its FIFO/90 tasks had no CBS bandwidth. This was the
"huge problem": KubeDeadline/runc was not assigning parameters to every
container in a pod.

### Root cause(s)

Two stacked bugs:

1. **Reclaim logic was too broad (v1).** The first fix reclaimed (zeroed) the RT
   budget of *any* sibling cgroup that had no task running an RT scheduling
   policy. But workload containers often start with a `sleep`-style entrypoint
   (SCHED_NORMAL) before the real RT threads spin up. So an idle-but-legitimate
   sibling got its reservation wiped.
2. **Pod-slice budget was never accumulated.** The per-pod slice was seeded only
   for the *first* container's reservation. When the second container tried to
   claim its share, `Σ(children) > parent`, so the write either failed with
   `EINVAL` or stole budget from the sibling.

### Solution (v2) — in `runc/libcontainer/cgroups/fs2/cpu.go`

- **Reclaim only the pause sandbox.** `reclaimSandboxRtBudget()` now enumerates
  the pod's sibling scopes and zeroes RT budget **only** for the infra/"pause"
  container, detected via `isPauseSandbox()` (reads `cgroup.procs` and checks
  `/proc/<pid>/comm == "pause"`). Workload containers are never touched.
- **Accumulate the pod-slice budget.** `podSliceBudget()` sums the per-core RT of
  **every workload child** (skipping the leaf and the pause sandbox) plus this
  leaf's own request, and writes that total to the pod slice **before** writing
  the leaf — so `Σ(children) ≤ parent` always holds.
- **Seed parents that are still zero.** `kubepods` and `kubepods-besteffort` are
  seeded only when `rtRuntimeIsZero()` is true (don't clobber the node budget).
- **Write order fix.** `writeRtPair()` always writes `cpu.rt_period_us` first,
  then `cpu.rt_runtime_us`, to avoid `EINVAL`.
- **Removed** the v1 helpers `cgroupHasRtTask` / `pidIsRealtime` (the
  `/proc/stat` policy sniffing that was too broad).

### Validation

`verify-rt.sh` after the fix showed for a two-container pod:

| scope        | `cpu.rt_runtime_us` (per-core read) |
|--------------|--------------------------------------|
| pod slice    | `0 200 200 0`                        |
| ctr0         | `0 100 100 0`                        |
| ctr1         | `0 100 100 0`                        |
| pause sandbox| `0`                                  |

`cbs-demo.sh 10` showed ctr0 ≈ 10.1% + ctr1 ≈ 10.0% = 20.1% on the shared core —
CBS isolation working for two containers in one pod.

---

## Problem 2 — `EINVAL` writing `cpu.rt_runtime_us`

**Symptom.** Writes to `cpu.rt_runtime_us` rejected with `EINVAL` on fresh
cgroups.

**Root cause.** Two issues: (a) writing runtime **before** period on a cgroup
whose period was still the default; (b) requesting more runtime than the parent
held (because the parent hadn't been seeded).

**Solution.** Always write period first (`writeRtPair()`), and seed every level
of the hierarchy (`kubepods` → `besteffort` → pod slice → leaf) so the
`Σ(children) ≤ parent` invariant is satisfied at write time.

---

## Problem 3 — READ vs WRITE format mismatch of `cpu.rt_runtime_us`

**Symptom.** Code that read back `cpu.rt_runtime_us` and tried to reuse the
string as a write payload corrupted the budget.

**Root cause.** The file's **read** format is a *positional per-core array*
(`"0 100 100 0"` = value indexed by cpu number), while the **write** format is
*`<runtime> <cpu>` pairs*. They are not interchangeable.

**Solution.** `readRtPerCore()` parses the positional read array into a
`map[cpu]runtime` (dropping zeros); `rtPairsList()` converts a map back into the
sorted `<runtime> <cpu> ...` write format. The two helpers bridge the formats
explicitly.

---

## Problem 4 — Two pods never contended on the same core

**Symptom.** When trying to demonstrate two claims contending for the same
cpuset, separate pods always landed on disjoint cores.

**Root cause.** The driver's allocator (`dra-rt-controller/rt.go`) uses
**worst-fit** placement: `cpuPartitioning(worstFit)` picks the `count`
*least-loaded* cpus and adds `claimUtil = runtime*1000/period` (per-mille). A cpu
is only dropped from the candidate set when its util would exceed `950` (the 95%
admission bound). Worst-fit deliberately **spreads** load, so distinct claims
land on disjoint cores **unless** `count` equals the number of allocatable cpus,
which forces full overlap.

**Solution / recipe.** To force same-cpuset contention, set `count` to the number
of allocatable RT cpus on the node (here `count: 4`, cpus `0-3`). That makes both
claims occupy the identical cpuset `0-3`. This is exactly what
[rt-contend.yaml](../dra-rt-driver/demo/rt-contend.yaml) and
[rt-test3.yaml](../dra-rt-driver/demo/rt-test3.yaml) do.

---

## Problem 5 — `kubectl apply -f demo/rt-test3.yaml` schema errors

**Symptom.** Applying the manifest produced three errors and left a partially
created namespace.

### Root causes

1. **Wrong apiVersion on `ResourceClaimTemplate`.** It used
   `resource.k8s.io/v1alpha1`; the correct group/version is
   `resource.k8s.io/v1alpha2`.
2. **Wrong apiGroup on `RtClaimParameters`.** One copy was declared under
   `resource.k8s.io/v1alpha1`; it must be `rt.resource.example.com/v1alpha1`.
3. **A `ResourceClaimTemplate` body mislabeled as `kind: RtClaimParameters`**,
   which produced `unknown field spec.spec`.
4. **Duplicate template name** — both pods referenced the same template
   `rt.example.com`.

### Solution

Rewrote [rt-test3.yaml](../dra-rt-driver/demo/rt-test3.yaml) to the working
schema (matching [rt-test1.yaml](../dra-rt-driver/demo/rt-test1.yaml)):

- Both `ResourceClaimTemplate`s → `resource.k8s.io/v1alpha2`.
- Both `RtClaimParameters` → `rt.resource.example.com/v1alpha1`, carrying only
  `count` / `runtime` / `period`.
- Two distinct templates `rt.example.com-a` and `rt.example.com-b`;
  `pod0`→`-a`, `pod1`→`-b`.

Because the bad apply partially created the namespace, delete before re-applying:

```bash
kubectl delete -f demo/rt-test3.yaml --ignore-not-found
kubectl apply  -f demo/rt-test3.yaml
```

### Gotcha — integer division in `claimUtil`

`claimUtil = runtime*1000/period` is **integer** math. For claim B with
`runtime: 2000, period: 3000000`, that is `2000*1000/3000000 = 0` per-mille — so B
reserves effectively 0% in the driver's admission accounting. Choose values where
`runtime*1000/period` is a whole number if you want visible bandwidth (e.g.
`period: 1000`).

---

## Problem 6 — RT pods fail with `cpu.rt_runtime_us: invalid argument` after experiments

**Symptom.** Pods that used to start now crash-loop with a runc error such as
`failed to write "100 2": ... cpu.rt_runtime_us: invalid argument` (`EINVAL`).

**Root cause.** The RT budget chain
`root (/sys/fs/cgroup) → kubepods.slice → kubepods-besteffort.slice → per-pod
slice → container leaf` got **zeroed** by earlier experiments/manual resets (and
the period sometimes polluted to a stale `1000`). The kernel enforces, per CPU,
`Σ(children rt_runtime) ≤ parent rt_runtime`, so any ancestor stuck at `0` makes
**every** descendant write on that core fail. On this custom H-CBS kernel the
**root cgroup RT budget is enforced** (not cosmetic), `cpu.rt_runtime_us` writes
accept **only per-core pairs** (`"<runtime> <cpu> ..."`, never a bare scalar), and
`cpu.rt_period_us` must be written **before** `cpu.rt_runtime_us`.

**Solution.** Delete all RT pods, then re-seed the chain **top-down**, period
before runtime, with per-core pairs for every cpu (`950000/1000000` = 95%/core):

```bash
KP=/sys/fs/cgroup/kubepods.slice
BE=$KP/kubepods-besteffort.slice
PAIRS="950000 0 950000 1 950000 2 950000 3"   # one <runtime> <cpu> pair per cpu (0-3)

echo 1000000 | sudo tee /sys/fs/cgroup/cpu.rt_period_us $KP/cpu.rt_period_us $BE/cpu.rt_period_us
echo "$PAIRS" | sudo tee /sys/fs/cgroup/cpu.rt_runtime_us   # root FIRST
echo "$PAIRS" | sudo tee $KP/cpu.rt_runtime_us
echo "$PAIRS" | sudo tee $BE/cpu.rt_runtime_us
grep -H . /sys/fs/cgroup/cpu.rt_runtime_us $KP/cpu.rt_runtime_us $BE/cpu.rt_runtime_us
```

`runc` accumulates the pod slice and ancestors per-core at container start, but it
does **not** restore this `950000` node cap — that seed is a node-setup step and
must be re-run whenever an experiment zeroes it. Full step-by-step recovery,
diagnosis commands, and failure-mode troubleshooting are in the dedicated runbook:
[runbook-rt-budget-einval.md](runbook-rt-budget-einval.md).

---

## Verification & demo tooling

- **`dra-rt-driver/demo/tests/verify-rt.sh`** — read-only. Dumps every RT pod
  slice and its child scopes (`rt_runtime_us`, `rt_period_us`, `cpuset`, and each
  task's scheduling policy via `chrt`), maps scope→name via
  `crictl inspect/inspectp`, **warns** if a sandbox still holds RT budget, and
  prints an OK/ATTENTION summary.
- **`dra-rt-driver/demo/tests/cbs-demo.sh`** — live contention demo.
  `sudo ./cbs-demo.sh [seconds] [core]`. Discovers RT workload scopes, launches a
  busy `SCHED_FIFO`/90 loop in every RT container simultaneously (optionally
  pinned to a single forced core), then prints a
  CONTAINER / CORE / RESERVED% / ACHIEVED% table.

### Deploy / verify commands (on the worker)

```bash
cd ~/runc && git pull && make \
  && sudo install -m0755 runc /usr/local/sbin/runc \
  && sudo systemctl restart containerd

sudo ./tests/verify-rt.sh
sudo ./tests/cbs-demo.sh 10 <core>
```

---

## Environment notes

- **Control plane** `rt-cluster-cp-0`: `kubectl` only.
- **Worker** `rt-cluster-worker-0`: `/sys/fs/cgroup`, `crictl`, `chrt`,
  `taskset` only.
- Registry `pippina2` (Docker Hub); git remotes `pippi2802/runc`,
  `pippi2802/dra-rt-driver`. `runc` binary installs to `/usr/local/sbin/runc`.
- Allocatable RT cpus come from `discovery.go`
  (`enumerateAllPossibleDevices`), seeded by `NODE_NAME`; this node exposes cpus
  `0-3`.

## Security note

`ppp.md` reportedly contains a plaintext secret. Rotate it and remove it from the
repo history.
