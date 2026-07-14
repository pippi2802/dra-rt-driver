#!/usr/bin/env bash
#
# rt-budget-seed.sh - seed the node-wide H-CBS real-time budget after boot.
#
# On this HCBS kernel, seeding the RT cgroup chain REQUIRES the global RT
# admission control to be OFF (kernel.sched_rt_runtime_us = -1). Proven
# empirically: on a CLEAN boot with a finite global runtime (950000) and NO
# committed reservations, writing kubepods.slice/cpu.rt_runtime_us is still
# refused - the cgroup-v2 root RT budget is 0 and un-writable under a finite
# global, so no child can be raised. Only -1 makes root/kubepods/besteffort
# writable.
#
# BECAUSE -1 removes the kernel's global RT bandwidth reserve, it is UNSAFE on
# its own: a busy SCHED_FIFO/DEADLINE task can take 100% of a CPU and starve
# the kernel/kubelet/containerd (node hangs; RT pods become unkillable). The
# REQUIRED mitigation is CPU ISOLATION at boot (isolcpus= / nohz_full= on the
# kernel cmdline): dedicate at least one housekeeping CPU that RT never runs on,
# so the control plane always has CPU even under maximum RT load. -1 also cannot
# be restored to a finite value live (EBUSY once reservations exist) - reset
# with a reboot.
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

# 1) Disable global RT admission control (REQUIRED for seeding on this kernel).
#    SAFETY DEPENDS ON CPU ISOLATION - see the header. Ensure at least one
#    housekeeping CPU is isolated from RT before running this on a shared node.
if (( RT_RUNTIME >= RT_PERIOD )); then
  die "RT_RUNTIME ($RT_RUNTIME) must be strictly LESS than RT_PERIOD ($RT_PERIOD)."
fi

log "disabling RT admission control (required to seed): sched_rt_period_us=$RT_PERIOD sched_rt_runtime_us=-1"
echo "$RT_PERIOD" > /proc/sys/kernel/sched_rt_period_us
echo -1          > /proc/sys/kernel/sched_rt_runtime_us

got_rt=$(cat /proc/sys/kernel/sched_rt_runtime_us)
if [[ "$got_rt" != "-1" ]]; then
  die "could not set sched_rt_runtime_us=-1 (reads '$got_rt'); the root/kubepods writes will be refused. Put -1 in the sysctl drop-in and reboot."
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

# Under -1 the cgroup-v2 root RT file is writable; seed root first, then
# kubepods, then besteffort (kernel enforces child <= parent per core).
if ! seed_level "$CG" || ! seed_level "$KP" || ! seed_level "$BE"; then
  die "could not seed the RT budget even with admission control off (-1). REBOOT and run this seed EARLY, before any RT pod commits a reservation."
fi

log "done - node RT budget seeded (root -> kubepods -> besteffort = $RT_RUNTIME/$RT_PERIOD)"
log "REMINDER: -1 has NO global RT reserve - a housekeeping CPU MUST be isolated (isolcpus/nohz_full) or a runaway RT task can hang this node."