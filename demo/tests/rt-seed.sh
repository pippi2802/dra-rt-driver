#!/usr/bin/env bash
#
# rt-seed.sh - Seed the H-CBS real-time (RT) cgroup budget after boot.
#
# The RT budget on the cgroup chain
#     /sys/fs/cgroup (root) -> kubepods.slice -> kubepods-besteffort.slice
# lives only in kernel memory and is reset to 0 on every boot / VM
# reallocation / kernel change. Until it is seeded, the first RT (KubeDeadline)
# pod fails to start with:
#     write .../cpu.rt_runtime_us: invalid argument   (EINVAL)   or
#     write .../cpu.rt_runtime_us: device or resource busy (EBUSY)
#
# This script seeds the chain, automatically picking the largest root RT budget
# the kernel will accept given the SCHED_DEADLINE bandwidth already reserved by
# the kernel's DL "fair server" (see doc/fix_budget_einval.md).
#
# Rules it respects (kernel: HCBS-patch rt-cgroups-multi):
#   - the ROOT cgroup must be a SCALAR (all CPUs equal) -> we write a bare value;
#   - cpu.rt_period_us must be written BEFORE cpu.rt_runtime_us;
#   - the root RT ratio must fit under (dl_bw->bw - dl_bw->total_bw), else EBUSY.
#
# Usage:  sudo ./rt-seed.sh [PERIOD_US]
#   PERIOD_US defaults to 1000000 (1 s). Run with all RT pods deleted for a
#   clean seed, though it also works alongside already-running RT pods.

set -uo pipefail

ROOT=/sys/fs/cgroup
KP=$ROOT/kubepods.slice
BE=$KP/kubepods-besteffort.slice
DEBUG=/sys/kernel/debug/sched/debug
PERIOD=${1:-1000000}

# Fixed-point unit used by the kernel DL bandwidth accounting (1 << BW_SHIFT,
# BW_SHIFT = 20). dl_bw->bw and dl_bw->total_bw are expressed in these units.
BW_UNIT=1048576

# Candidate root runtimes (microseconds), tried high -> low. The first value the
# kernel actually accepts (verified by read-back) is used.
CANDIDATES="950000 900000 850000 800000 750000 700000 650000 600000 500000 400000"

log() { echo "[rt-seed] $*"; }

if [ "$(id -u)" -ne 0 ]; then
	log "ERROR: must run as root (use sudo)"
	exit 1
fi

# Wait for the kubepods slices to appear (kubelet creates them a little after
# boot). Give up after ~60s.
for _ in $(seq 1 30); do
	[ -d "$BE" ] && break
	sleep 2
done
if [ ! -d "$BE" ]; then
	log "ERROR: $BE does not exist - is kubelet running?"
	exit 1
fi

# Read the DL bandwidth budget, if debugfs is available. bw == -1 means DL
# admission control is disabled (sched_rt_runtime_us = -1); in that case any
# value is accepted and there is no over-commit protection.
bw=$(awk '/dl_bw->bw/        {print $3; exit}' "$DEBUG" 2>/dev/null || true)
tot=$(awk '/dl_bw->total_bw/ {print $3; exit}' "$DEBUG" 2>/dev/null || true)
log "DL budget: bw=${bw:-?} total_bw=${tot:-?} (unit=$BW_UNIT)"

# Compute a ceiling (in us) for the root runtime from the free DL bandwidth,
# with a 2% safety margin. If we cannot read the budget, leave it unset and just
# fall back to trying the candidates.
rtmax=""
if [ -n "${bw:-}" ] && [ -n "${tot:-}" ] && [ "$bw" != "-1" ]; then
	free=$(( bw - tot ))
	[ "$free" -lt 0 ] && free=0
	rtmax=$(( free * PERIOD / BW_UNIT ))
	rtmax=$(( rtmax * 98 / 100 ))
	log "free DL bandwidth allows root runtime up to ~${rtmax}us / ${PERIOD}us"
fi

# write VALUE FILE  (returns non-zero on failure)
write() { echo "$1" > "$2" 2>/dev/null; }

# Period first, on every level (scalar => applies to all CPUs).
for d in "$ROOT" "$KP" "$BE"; do
	write "$PERIOD" "$d/cpu.rt_period_us" \
		|| log "warning: could not set period on $d"
done

# Find the largest root runtime the kernel accepts, verified by read-back.
VAL=""
for c in $CANDIDATES; do
	if [ -n "$rtmax" ] && [ "$c" -gt "$rtmax" ]; then
		continue   # skip values we already know exceed the free budget
	fi
	write "$c" "$ROOT/cpu.rt_runtime_us"
	if [ "$(cat "$ROOT/cpu.rt_runtime_us" 2>/dev/null)" = "$c" ]; then
		VAL="$c"
		break
	fi
done

if [ -z "$VAL" ]; then
	log "ERROR: could not seed root cpu.rt_runtime_us."
	log "       Check for leftover RT/DL reservations (total_bw above) or"
	log "       running RT pods; delete them and retry, or reboot the node."
	exit 1
fi
log "root seeded at ${VAL}us / ${PERIOD}us"

# Propagate the same budget down to kubepods and besteffort. runc manages the
# per-pod and per-container levels below these.
for d in "$KP" "$BE"; do
	write "$VAL" "$d/cpu.rt_runtime_us" \
		|| log "warning: could not set runtime on $d"
done

log "final state:"
grep -H . \
	"$ROOT/cpu.rt_runtime_us" \
	"$KP/cpu.rt_runtime_us" \
	"$BE/cpu.rt_runtime_us"
