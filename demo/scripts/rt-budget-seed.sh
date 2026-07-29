#!/usr/bin/env bash
#
# rt-budget-seed.sh - seed the node-wide H-CBS real-time budget.
#
# Seeds the top of the pod-cgroup chain, TOP-DOWN:
#     /sys/fs/cgroup (ROOT)  = RT_RUNTIME / RT_PERIOD  (SCALAR, all CPUs equal)
#     kubepods.slice         = RT_RUNTIME / RT_PERIOD
# and leaves the per-QoS slices (besteffort/burstable) and the per-pod/leaf
# scopes to be raised ON DEMAND by the (fixed) runc, which walks up to
# kubepods.slice and, keeping this cap as a per-core FLOOR, grows whichever QoS
# class a pod actually lands in.
#
# Why ROOT too (not kubepods alone): on this HCBS kernel the schedulability
# check walks the WHOLE tree from the ROOT task-group, so kubepods is bounded by
# the ROOT cgroup file /sys/fs/cgroup/cpu.rt_runtime_us, which boots at 0. Until
# root holds budget, ANY kubepods write EINVALs with
# "tg_rt_schedulable fail: children bw <N> > parent bw 0" (N = your requested
# runtime x nr_cpus in 1<<20 units). ROOT must be a SCALAR (all CPUs equal); a
# per-core list at root is rejected.
#
# Why NOT the QoS slices: the kernel enforces Sum(children rt_runtime) <= parent,
# so pre-seeding besteffort AND burstable AND guaranteed to the full cap at once
# is REJECTED (their sum exceeds kubepods). Seeding just root+kubepods keeps it
# legal and QoS-agnostic; runc partitions the cap per-core among the QoS children.
#
# CAP = free DEADLINE budget, node-dependent. Setting the ROOT rt_runtime
# RESERVES SCHED_DEADLINE bandwidth; the kernel refuses any value above
# free = dl_bw->bw - dl_bw->total_bw (read from /sys/kernel/debug/sched/debug,
# fixed-point unit 1<<20). total_bw is the DEADLINE fair-server = the ~20% CFS
# reserve, so the RT ceiling is BELOW 100% and DIFFERS per node (e.g. ~0.79 where
# the fair-server holds 0.20). This script defaults RT_RUNTIME high and CLAMPS it
# down to each node's free budget, so worker-0 gets ~0.75 while a node with more
# headroom can reach 950000. Keep the DRIVER admission threshold <= the seeded
# value or the driver admits pods the cgroup then rejects.
#
# Admission control stays FINITE: sched_rt_runtime_us is NEVER set to -1, so
# throttling/admission remain in force for experiments. The global stays at 100%
# (kubepods, being non-root, is capped by the global ratio, so 95% < 100% is
# writable); the HCBS DEADLINE fair-server (per-CPU total_bw) still holds its CFS
# reserve at the root-domain level. Idempotent; run as root on the worker.
# REQUIRES the fixed runc to be installed (it seeds the QoS + pod + leaf levels
# under this cap).
#
set -uo pipefail

RT_PERIOD=${RT_PERIOD:-1000000}
RT_RUNTIME=${RT_RUNTIME:-950000}   # desired cap; auto-clamped down to the node's free DL budget below
CG=${CG:-/sys/fs/cgroup}
WAIT_SECS=${WAIT_SECS:-120}
KP="$CG/kubepods.slice"

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

# True if the cgroup's cpu.rt_runtime_us holds a nonzero value on any core
# (read format is a positional per-core array or a scalar). Any digit 1-9 in the
# value means some core has nonzero runtime; an all-zero value has none.
has_rt() {
  local v
  v=$(cat "$1/cpu.rt_runtime_us" 2>/dev/null) || return 1
  printf '%s' "$v" | grep -q '[1-9]'
}

# Global RT admission is configured separately and finitely (via
# 99-rt-budget.conf / sysctl --system); do NOT clobber it here and NEVER set -1.
# Just sanity-check it is finite - if it is -1 the kernel admission/CFS
# protection is off and the cap below is not enforced.
g=$(cat /proc/sys/kernel/sched_rt_runtime_us 2>/dev/null || echo 0)
if [[ "$g" == "-1" ]]; then
  log "WARNING: kernel.sched_rt_runtime_us=-1 (admission OFF). Set it finite via 99-rt-budget.conf (sysctl --system) so throttling and the CFS reserve stay in force."
else
  log "global admission finite: sched_rt_runtime_us=$g/$(cat /proc/sys/kernel/sched_rt_period_us 2>/dev/null)"
fi

# Clamp RT_RUNTIME to this node's FREE DEADLINE budget. Setting the ROOT
# rt_runtime reserves SCHED_DEADLINE bandwidth; the kernel refuses any value
# above free = dl_bw->bw - dl_bw->total_bw (fixed-point unit 1<<20). total_bw is
# the DEADLINE fair-server (the ~20% CFS reserve), so the ceiling is node-
# dependent. Read it from debugfs and clamp, keeping a 5%-of-period safety margin.
DL_UNIT=1048576
dbg=/sys/kernel/debug/sched/debug
MARGIN=${MARGIN:-10000}   # us kept below the free ceiling (rounding guard); tune via env
bw=$(grep -m1 'dl_bw->bw'        "$dbg" 2>/dev/null | grep -oE '[0-9]+' | tail -1)
tot=$(grep -m1 'dl_bw->total_bw' "$dbg" 2>/dev/null | grep -oE '[0-9]+' | tail -1)
if [[ -n "$bw" && -n "$tot" ]] && (( bw > tot )); then
  free_us=$(( (bw - tot) * RT_PERIOD / DL_UNIT ))   # free budget in microseconds
  ceil=$(( free_us - MARGIN ))                      # small rounding-guard margin
  (( ceil > 0 )) || ceil=$free_us
  if (( RT_RUNTIME > ceil )); then
    log "free DL budget ~${free_us}us (bw=$bw total_bw=$tot, of which total_bw is the ~20% CFS fair-server); clamping RT_RUNTIME $RT_RUNTIME -> $ceil (margin ${MARGIN}us)"
    RT_RUNTIME=$ceil
  else
    log "free DL budget ~${free_us}us (bw=$bw total_bw=$tot); RT_RUNTIME=$RT_RUNTIME fits"
  fi
else
  log "could not read DL budget from $dbg; using RT_RUNTIME=$RT_RUNTIME as-is (clamp skipped)"
fi

(( RT_RUNTIME < RT_PERIOD )) || die "RT_RUNTIME ($RT_RUNTIME) must be < RT_PERIOD ($RT_PERIOD)."
(( RT_RUNTIME > 0 ))         || die "free DL budget is 0 (bw<=total_bw). Reboot the node (clears committed DEADLINE reservations) and re-run early, before RT pods start."

# Seed TOP-DOWN: ROOT first (SCALAR - all CPUs equal; a per-core list at root is
# rejected), then kubepods.slice. Write period BEFORE runtime at each level (a
# fresh cgroup has period 0, and a nonzero runtime while period is 0 is EINVAL).
# A bare scalar applies the value to every CPU.
seed_scalar() {
  echo "$RT_PERIOD"  > "$1/cpu.rt_period_us"  2>/dev/null || true
  echo "$RT_RUNTIME" > "$1/cpu.rt_runtime_us" 2>/dev/null || true
}
seed_scalar "$CG"     # ROOT  /sys/fs/cgroup
seed_scalar "$KP"     # kubepods.slice

# Confirm BOTH root and kubepods actually STUCK (nonzero).
if has_rt "$CG" && has_rt "$KP"; then
  log "SUCCESS: root=$(cat "$CG/cpu.rt_runtime_us") kubepods=$(cat "$KP/cpu.rt_runtime_us") (period $RT_PERIOD)"
  log "runc grows the per-QoS / per-pod / per-leaf RT budget on demand under this cap."
  log "NOTE: keep the driver admission threshold <= ${RT_RUNTIME}/${RT_PERIOD} or it will admit pods the cgroup then rejects."
  exit 0
fi

die "could not seed root+kubepods. Check RT_GROUP_SCHED is enabled, the global is finite (not -1), the value fits the free DL budget (bw-total_bw in $dbg), and no RT pod has committed conflicting DEADLINE budget (scale down/delete RT pods or reboot, then re-run early)."