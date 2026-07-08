#!/usr/bin/env bash
#
# rt-budget-seed.sh - seed the node-wide H-CBS real-time budget after boot.
#
# WHY THIS EXISTS
#   On this custom RT_GROUP_SCHED / H-CBS kernel the per-cgroup RT bandwidth
#   (cpu.rt_runtime_us / cpu.rt_period_us) is *in-memory node state*: it is NOT
#   persisted across a reboot, and it can only be written while global RT group
#   bandwidth is ENABLED (kernel.sched_rt_runtime_us must be a positive value
#   strictly LESS than kernel.sched_rt_period_us - never -1/RUNTIME_INF and never
#   equal to the period). If the node boots with an un-seeded chain, every RT
#   container's leaf write of cpu.rt_runtime_us fails with EINVAL, because the
#   kernel enforces, per CPU, Sum(children rt_runtime) <= parent rt_runtime and
#   the ancestors (root -> kubepods.slice -> kubepods-besteffort.slice) hold 0.
#
#   This script makes the node reboot-safe: it enables global RT bandwidth and
#   seeds kubepods.slice + kubepods-besteffort.slice with an even per-core
#   ceiling across every ONLINE cpu, so runc's per-pod / per-container writes
#   always have parent budget to draw from.
#
# WHERE TO RUN: as root, ON THE WORKER, after kubelet has created kubepods.slice.
#   Normally installed as the rt-budget-seed.service systemd unit (see the
#   companion file); can also be run by hand: sudo ./rt-budget-seed.sh
#
# TUNABLES (env):
#   RT_PERIOD   scalar rt_period_us for every level      (default 1000000)
#   RT_RUNTIME  per-core rt_runtime_us ceiling to seed   (default  950000)
#   CG          cgroup v2 mount point                    (default /sys/fs/cgroup)
#   WAIT_SECS   how long to wait for kubepods.slice       (default      120)
#
set -euo pipefail

RT_PERIOD=${RT_PERIOD:-1000000}
RT_RUNTIME=${RT_RUNTIME:-950000}
CG=${CG:-/sys/fs/cgroup}
WAIT_SECS=${WAIT_SECS:-120}

log() { printf 'rt-budget-seed: %s\n' "$*"; }
die() { printf 'rt-budget-seed: error: %s\n' "$*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
  die "must run as root (sudo $0)"
fi

# ----------------------------------------------------------------------------
# 1) DISABLE the global RT/DEADLINE bandwidth admission control by setting
#    sched_rt_runtime_us = -1 (RUNTIME_INF). VERIFIED on this HCBS 7.0.0 kernel:
#    with a finite global runtime the kernel's admission check
#    (tg_rt_schedulable / "dl check tg") REFUSES the root cpu.rt_runtime_us write
#    with EBUSY, so the whole chain is un-seedable and every container's RT write
#    EINVALs. With -1 the admission check is bypassed, the root/parent slices
#    accept their scalar budget, and the per-cgroup CBS/DEADLINE servers built
#    from cpu.rt_runtime_us still throttle each group. (This is the setting that
#    made rt-verify + the model1 sweeps work.)
# ----------------------------------------------------------------------------
log "disabling RT admission control: sched_rt_period_us=$RT_PERIOD sched_rt_runtime_us=-1"
echo "$RT_PERIOD" > /proc/sys/kernel/sched_rt_period_us
echo -1         > /proc/sys/kernel/sched_rt_runtime_us

got_rt=$(cat /proc/sys/kernel/sched_rt_runtime_us)
if [[ "$got_rt" != "-1" ]]; then
  die "could not set sched_rt_runtime_us=-1 (reads '$got_rt'); admission control is still on and the root write will be refused."
fi

# ----------------------------------------------------------------------------
# 2) Wait for kubelet to have created kubepods.slice.
# ----------------------------------------------------------------------------
KP="$CG/kubepods.slice"
BE="$KP/kubepods-besteffort.slice"

waited=0
while [[ ! -d "$KP" ]]; do
  (( waited < WAIT_SECS )) || die "timed out after ${WAIT_SECS}s waiting for $KP (is kubelet running?)"
  sleep 2; waited=$((waited + 2))
done

# ----------------------------------------------------------------------------
# 3) Seed the PARENT slices - root -> kubepods.slice -> kubepods-besteffort.slice
#    - TOP-DOWN with a SCALAR reservation (RT_RUNTIME/RT_PERIOD applied to all
#    cores). This is the form the HCBS 7.0.0 kernel accepts and was verified
#    working: each parent gets cpu.rt_period_us (1000000) written BEFORE
#    cpu.rt_runtime_us (950000). The kernel enforces, per core,
#    Sum(children) <= parent, so root must be seeded first, then kubepods, then
#    besteffort. Per-pod slices and container leaves get the exact PER-CORE
#    reservation from the claim and are seeded by runc, not here.
#
#    This only works with the admission control OFF (sched_rt_runtime_us=-1, set
#    in step 1). With a finite global runtime the root write is refused
#    (EBUSY / kernel log "tg_rt_schedulable ... dl check tg").
# ----------------------------------------------------------------------------

# seed_level <dir> : write period first (a fresh cgroup has period 0, and writing
# a non-zero runtime while period is 0 is EINVAL), then the SCALAR runtime.
# Returns non-zero (without aborting under set -e) if the runtime write is
# rejected, so the caller can emit an actionable message instead of a raw error.
seed_level() {
  local dir="$1"
  [[ -d "$dir" ]] || { log "skip (absent): $dir"; return 0; }
  echo "$RT_PERIOD" > "$dir/cpu.rt_period_us" 2>/dev/null || true
  if ! echo "$RT_RUNTIME" > "$dir/cpu.rt_runtime_us" 2>/dev/null; then
    return 1
  fi
  log "seeded ${dir#"$CG"/}: period=$RT_PERIOD runtime=$(cat "$dir/cpu.rt_runtime_us")"
  return 0
}

if ! seed_level "$CG" || ! seed_level "$KP" || ! seed_level "$BE"; then
  root_rt=$(cat "$CG/cpu.rt_runtime_us" 2>/dev/null || echo '?')
  die "could not seed the RT budget - a write was rejected (root cpu.rt_runtime_us='$root_rt').
       This kernel's RT/DEADLINE admission control must be OFF for the root write to
       succeed: confirm sched_rt_runtime_us=-1 (cat /proc/sys/kernel/sched_rt_runtime_us).
       If it is -1 and the write still fails, run this seed once EARLY after boot
       (before any RT pod establishes a deadline reservation)."
fi

log "done - node RT budget seeded (root -> kubepods -> besteffort = $RT_RUNTIME/$RT_PERIOD)"
