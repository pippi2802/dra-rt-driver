#!/usr/bin/env bash
#
# rt-budget-seed.sh - seed the node-wide H-CBS real-time budget after boot.
# Keeps global RT admission control FINITE (never -1) and seeds early.
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

# 1) Keep admission control ON with a finite runtime (5% reserve). NEVER -1.
if (( RT_RUNTIME >= RT_PERIOD )); then
  die "RT_RUNTIME ($RT_RUNTIME) must be strictly LESS than RT_PERIOD ($RT_PERIOD)."
fi

cur_rt=$(cat /proc/sys/kernel/sched_rt_runtime_us)
if [[ "$cur_rt" == "-1" ]]; then
  echo "$RT_PERIOD" > /proc/sys/kernel/sched_rt_period_us 2>/dev/null || true
  if ! echo "$RT_RUNTIME" > /proc/sys/kernel/sched_rt_runtime_us 2>/dev/null; then
    die "sched_rt_runtime_us is stuck at -1 and cannot be restored live (EBUSY). REBOOT this node, then run this seed EARLY, before any RT pod."
  fi
fi

log "keeping RT admission control ON: sched_rt_period_us=$RT_PERIOD sched_rt_runtime_us=$RT_RUNTIME"
echo "$RT_PERIOD"  > /proc/sys/kernel/sched_rt_period_us
echo "$RT_RUNTIME" > /proc/sys/kernel/sched_rt_runtime_us

got_rt=$(cat /proc/sys/kernel/sched_rt_runtime_us)
if [[ "$got_rt" == "-1" ]] || (( got_rt <= 0 )); then
  die "global RT runtime reads '$got_rt' (not finite). Reboot and re-run early."
fi

# 2) Wait for kubelet to create kubepods.slice.
KP="$CG/kubepods.slice"
BE="$KP/kubepods-besteffort.slice"
waited=0
while [[ ! -d "$KP" ]]; do
  (( waited < WAIT_SECS )) || die "timed out after ${WAIT_SECS}s waiting for $KP"
  sleep 2; waited=$((waited + 2))
done

# 3) Seed parents (period before runtime). Root best-effort; kubepods+besteffort required.
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

seed_level "$CG" || log "note: root not writable (governed by sched_rt_runtime_us) - continuing"

if ! seed_level "$KP" || ! seed_level "$BE"; then
  die "could not seed the RT budget - bandwidth already committed. Do NOT set -1. REBOOT and run this seed EARLY, before any RT pod."
fi

log "done - node RT budget seeded with admission control ON (kubepods -> besteffort = $RT_RUNTIME/$RT_PERIOD)"