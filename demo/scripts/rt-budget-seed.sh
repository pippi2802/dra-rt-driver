#!/usr/bin/env bash
#
# rt-budget-seed.sh - seed the node-wide H-CBS real-time budget (Model A).
#
# Seeds ONLY the top pod-cgroup cap:
#     kubepods.slice = RT_RUNTIME / RT_PERIOD   (default 950000 / 1000000 = 95%)
# on every CPU, and leaves the per-QoS slices (besteffort/burstable) and the
# per-pod/leaf scopes to be raised ON DEMAND by the (fixed) runc, which walks up
# to kubepods.slice and, keeping this cap as a per-core FLOOR, grows whichever
# QoS class a pod actually lands in.
#
# Why only kubepods.slice: the kernel enforces Sum(children rt_runtime) <=
# parent, so pre-seeding besteffort AND burstable AND guaranteed to the full cap
# at once is REJECTED (their sum exceeds kubepods). Seeding just the cap keeps it
# legal and QoS-agnostic; runc partitions it per-core among the QoS children.
#
# Why 95%: it MATCHES the driver's admission control (Eq.1: Sum Qi/Pi <= 0.95
# per core; a cpu is dropped only when util > 950 per-mille). The cgroup cap must
# be >= what the driver admits, or the driver would accept pods whose leaf RT
# writes the cgroup then rejects. Keep this in lockstep with the driver threshold.
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
RT_RUNTIME=${RT_RUNTIME:-950000}   # 95% cap on RT under kubepods; matches driver admission (Eq.1 <= 0.95)
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

# Seed the cap on kubepods.slice ONLY (Model A). Write period BEFORE runtime (a
# fresh cgroup has period 0, and writing a nonzero runtime while period is 0 is
# EINVAL). A bare scalar applies the value to every CPU.
echo "$RT_PERIOD"  > "$KP/cpu.rt_period_us"  2>/dev/null || true
echo "$RT_RUNTIME" > "$KP/cpu.rt_runtime_us" 2>/dev/null || true

# Confirm the cap actually STUCK (nonzero on some core).
if has_rt "$KP"; then
  log "SUCCESS: kubepods.slice cap = $(cat "$KP/cpu.rt_runtime_us") (period $(cat "$KP/cpu.rt_period_us"))"
  log "Model A: per-QoS, per-pod and per-leaf RT budget is grown on demand by runc under this cap."
  exit 0
fi

die "could not seed kubepods.slice. Check RT_GROUP_SCHED is enabled, the global is finite (not -1), and no RT pod has committed conflicting budget (delete RT pods or reboot, then re-run early)."