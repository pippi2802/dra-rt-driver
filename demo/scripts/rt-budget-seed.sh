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

if (( RT_RUNTIME >= RT_PERIOD )); then
  die "RT_RUNTIME ($RT_RUNTIME) must be strictly less than RT_PERIOD ($RT_PERIOD); a value >= period (or -1) disables RT group bandwidth and makes the chain un-seedable"
fi

# ----------------------------------------------------------------------------
# 1) Enable global RT group bandwidth (runtime < period). This is the switch
#    that lets any per-cgroup cpu.rt_runtime_us write succeed at all.
# ----------------------------------------------------------------------------
log "enabling global RT bandwidth: sched_rt_period_us=$RT_PERIOD sched_rt_runtime_us=$RT_RUNTIME"
echo "$RT_PERIOD"  > /proc/sys/kernel/sched_rt_period_us
echo "$RT_RUNTIME" > /proc/sys/kernel/sched_rt_runtime_us

got_rt=$(cat /proc/sys/kernel/sched_rt_runtime_us)
if [[ "$got_rt" == "-1" || "$got_rt" -ge "$RT_PERIOD" ]]; then
  die "sched_rt_runtime_us is '$got_rt' (>= period or -1); RT group bandwidth is disabled - refusing to continue. Remove any sysctl drop-in that sets kernel.sched_rt_runtime_us = -1."
fi

# ----------------------------------------------------------------------------
# 2) Build the even per-core write list "<rt> <cpu> <rt> <cpu> ..." across every
#    currently-online CPU, so no core is left at 0 (an uneven seed makes the
#    driver unable to place a cell on an unseeded core).
# ----------------------------------------------------------------------------
online=$(cat /sys/devices/system/cpu/online)   # e.g. "0-3" or "0,2-3"
cpus=()
IFS=',' read -ra ranges <<< "$online"
for r in "${ranges[@]}"; do
  if [[ "$r" == *-* ]]; then
    lo=${r%-*}; hi=${r#*-}
    for ((c=lo; c<=hi; c++)); do cpus+=("$c"); done
  else
    cpus+=("$r")
  fi
done
(( ${#cpus[@]} > 0 )) || die "could not parse online CPUs from '$online'"

pairs=""
for c in "${cpus[@]}"; do
  pairs+="${pairs:+ }$RT_RUNTIME $c"
done
log "online CPUs: ${cpus[*]}  ->  per-core seed: '$pairs'"

# ----------------------------------------------------------------------------
# 3) Wait for kubelet to have created kubepods.slice, then seed it and the
#    besteffort child. NOTE: the cgroup-v2 root (/sys/fs/cgroup) is intentionally
#    NOT written - its budget comes from the global sysctl above and a direct
#    write returns EBUSY.
# ----------------------------------------------------------------------------
KP="$CG/kubepods.slice"
BE="$KP/kubepods-besteffort.slice"

waited=0
while [[ ! -d "$KP" ]]; do
  (( waited < WAIT_SECS )) || die "timed out after ${WAIT_SECS}s waiting for $KP (is kubelet running?)"
  sleep 2; waited=$((waited + 2))
done

# seed_level <dir> : write period first (a fresh cgroup has period 0, and writing
# a non-zero runtime while period is 0 is EINVAL), then the per-core runtime.
seed_level() {
  local dir="$1"
  [[ -d "$dir" ]] || { log "skip (absent): $dir"; return 0; }
  echo "$RT_PERIOD" > "$dir/cpu.rt_period_us"
  echo "$pairs"     > "$dir/cpu.rt_runtime_us"
  log "seeded $(basename "$dir"): period=$RT_PERIOD runtime='$(cat "$dir/cpu.rt_runtime_us")'"
}

seed_level "$KP"
seed_level "$BE"

log "done - node RT budget is seeded and reboot-safe via the systemd unit"
