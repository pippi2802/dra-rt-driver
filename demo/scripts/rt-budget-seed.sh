#!/usr/bin/env bash
#
# rt-budget-seed.sh - seed the node-wide H-CBS real-time budget.
#
# Establishes the RT cgroup cap so runc's per-pod/leaf writes always have parent
# budget: kubepods.slice + kubepods-besteffort.slice = RT_RUNTIME/RT_PERIOD
# (default 950000/1000000). Idempotent; run as root on the worker.
#
# It PREFERS finite admission control (kernel.sched_rt_runtime_us = RT_RUNTIME,
# strictly < RT_PERIOD), which keeps a per-core RESERVE for non-RT work
# (kernel/kubelet/containerd) - so NO CPU isolation and NO -1 are needed, and a
# busy RT task cannot hang the node. It falls back to -1 (admission OFF) ONLY if
# the kernel refuses to seed under a finite global; in that case it warns that a
# housekeeping CPU must be isolated (isolcpus=), because -1 removes the reserve.
# The script auto-detects which mode works and prints it.
#
set -uo pipefail

RT_PERIOD=${RT_PERIOD:-1000000}
RT_RUNTIME=${RT_RUNTIME:-950000}
CG=${CG:-/sys/fs/cgroup}
WAIT_SECS=${WAIT_SECS:-120}
KP="$CG/kubepods.slice"
BE="$KP/kubepods-besteffort.slice"

log() { printf 'rt-budget-seed: %s\n' "$*"; }
die() { printf 'rt-budget-seed: error: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root (sudo $0)"
(( RT_RUNTIME < RT_PERIOD )) || die "RT_RUNTIME ($RT_RUNTIME) must be < RT_PERIOD ($RT_PERIOD)."

# Wait for kubelet to create kubepods.slice.
waited=0
while [[ ! -d "$KP" ]]; do
  (( waited < WAIT_SECS )) || die "timed out after ${WAIT_SECS}s waiting for $KP (is kubelet up?)"
  sleep 2; waited=$((waited + 2))
done

# Write period BEFORE runtime for one cgroup dir (fresh cgroup has period 0, and
# writing a nonzero runtime while period is 0 is EINVAL). Errors are tolerated;
# success is judged by has_rt() below, not by the write's exit status.
seed_dir() {
  local d="$1"
  [[ -d "$d" ]] || return 0
  echo "$RT_PERIOD"  > "$d/cpu.rt_period_us"  2>/dev/null || true
  echo "$RT_RUNTIME" > "$d/cpu.rt_runtime_us" 2>/dev/null || true
}

# True if the cgroup's cpu.rt_runtime_us holds a nonzero value on any core
# (read format is a positional per-core array or a scalar). Any digit 1-9 in the
# value means some core has nonzero runtime; an all-zero value has none.
has_rt() {
  local v
  v=$(cat "$1/cpu.rt_runtime_us" 2>/dev/null) || return 1
  printf '%s' "$v" | grep -q '[1-9]'
}

# Seed kubepods + besteffort and confirm the values actually STUCK (nonzero) -
# a write can "succeed" then be re-zeroed by an unfixed runc on a churning pod.
seed_and_verify() {
  seed_dir "$KP"
  seed_dir "$BE"
  has_rt "$KP" && has_rt "$BE"
}

# ---- Attempt 1: FINITE admission control (preferred; keeps a reserve) ---------
log "attempt 1: FINITE admission sched_rt_runtime_us=$RT_RUNTIME/$RT_PERIOD (keeps a non-RT reserve)"
echo "$RT_PERIOD"  > /proc/sys/kernel/sched_rt_period_us  2>/dev/null || true
echo "$RT_RUNTIME" > /proc/sys/kernel/sched_rt_runtime_us 2>/dev/null || true
if seed_and_verify; then
  log "SUCCESS (finite): global=$(cat /proc/sys/kernel/sched_rt_runtime_us) kubepods=$(cat "$KP/cpu.rt_runtime_us") besteffort=$(cat "$BE/cpu.rt_runtime_us")"
  log "No -1 and no CPU isolation needed - the finite global reserves CPU for non-RT work."
  exit 0
fi

# ---- Attempt 2: fall back to -1 (admission OFF) ------------------------------
log "finite seeding did not stick; falling back to sched_rt_runtime_us=-1 (admission OFF)"
echo -1 > /proc/sys/kernel/sched_rt_runtime_us 2>/dev/null || true
if [[ "$(cat /proc/sys/kernel/sched_rt_runtime_us)" != "-1" ]]; then
  die "could not set -1 (a finite value is stuck / reservations committed). Reboot the node and re-run this EARLY, before any RT pod."
fi
seed_dir "$CG"   # under -1 the cgroup-v2 root RT file is writable; best-effort
if seed_and_verify; then
  log "SUCCESS (-1): global=-1 kubepods=$(cat "$KP/cpu.rt_runtime_us") besteffort=$(cat "$BE/cpu.rt_runtime_us")"
  log "WARNING: -1 has NO global RT reserve. Isolate a housekeeping CPU (isolcpus=) or a runaway RT task can hang this node."
  exit 0
fi

die "could not seed under finite OR -1. Delete all RT pods (kubectl/crictl) so nothing rewrites the chain, then retry; if it still fails, reboot."