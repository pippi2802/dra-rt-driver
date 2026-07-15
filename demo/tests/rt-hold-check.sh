#!/usr/bin/env bash
#
# rt-hold-check.sh - prove the H-CBS reservation (CBS server) actually THROTTLES.
#
# It creates a small RT reservation (Q/P) under kubepods-besteffort.slice - the
# SAME cgroup chain your pods use - runs a busy SCHED_FIFO/90 loop inside it, and
# measures the CPU% that loop actually gets over a window.
#
#   * correct node (finite global, chain seeded): loop is throttled to ~Q/P  -> PASS
#   * broken node (global sched_rt_runtime_us=-1): loop runs ~100%           -> FAIL
#     (this is the "reserved 10% -> achieved 100%" behaviour you saw before)
#
# Run as root ON THE WORKER. Requires the RT budget chain to be seeded first
# (sudo ./rt-seed.sh). Non-destructive: it removes its test cgroup on exit.
#
# Usage:
#   sudo ./rt-hold-check.sh                                   # 10% on cpu1, 5s
#   sudo RUNTIME=200000 PERIOD=1000000 CORE=2 SECS=8 ./rt-hold-check.sh
#
set -uo pipefail

CG=/sys/fs/cgroup
BE=$CG/kubepods.slice/kubepods-besteffort.slice
TEST=${TEST:-rt-hold-test}
DIR=$BE/$TEST
CORE=${CORE:-1}                 # pin the busy loop to this CPU
RUNTIME=${RUNTIME:-100000}      # Q in microseconds (default 100ms)
PERIOD=${PERIOD:-1000000}       # P in microseconds (default 1000ms -> 10%)
SECS=${SECS:-5}                 # measurement window

[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0"; exit 1; }
[[ -d $BE ]]      || { echo "missing $BE (is kubelet running?)"; exit 1; }

BUSY=""
cleanup() {
  [[ -n $BUSY ]] && kill -9 "$BUSY" 2>/dev/null
  [[ -d $DIR   ]] && rmdir "$DIR" 2>/dev/null
}
trap cleanup EXIT

# ensure the cpu controller is delegated into besteffort's subtree
grep -qw cpu "$BE/cgroup.subtree_control" 2>/dev/null \
  || echo +cpu > "$BE/cgroup.subtree_control" 2>/dev/null || true

mkdir -p "$DIR"

# period BEFORE runtime (writing runtime while period=0 is EINVAL)
echo "$PERIOD" > "$DIR/cpu.rt_period_us"
if ! echo "$RUNTIME" > "$DIR/cpu.rt_runtime_us" 2>/dev/null; then
  echo "FAIL: could not set reservation Q=${RUNTIME}us P=${PERIOD}us under besteffort."
  echo "      The RT budget chain is not seeded (or has no room on this core)."
  echo "      Seed it first:  sudo ./rt-seed.sh   then re-run this check."
  exit 1
fi

# busy loop -> move into the reservation -> SCHED_FIFO 90 -> pin to CORE
( while :; do :; done ) &
BUSY=$!
echo "$BUSY" > "$DIR/cgroup.procs"
chrt -f -p 90 "$BUSY"
taskset -pc "$CORE" "$BUSY" >/dev/null

# utime(14)+stime(15) from /proc/<pid>/stat, robust against comm containing ')'
cpu_ticks() { local s; s=$(cat /proc/$1/stat); s=${s#*) }; set -- $s; echo $(( $12 + $13 )); }

t1=$(cpu_ticks "$BUSY"); sleep "$SECS"; t2=$(cpu_ticks "$BUSY")
HZ=$(getconf CLK_TCK)
ACH=$(( (t2 - t1) * 100 / (HZ * SECS) ))
EXP=$(( RUNTIME * 100 / PERIOD ))

echo "-----------------------------------------------------------"
echo "reservation : Q=${RUNTIME}us / P=${PERIOD}us = ${EXP}%   (cpu${CORE}, SCHED_FIFO 90)"
echo "achieved    : ${ACH}%   over ${SECS}s"
echo "global      : sched_rt_runtime_us=$(cat /proc/sys/kernel/sched_rt_runtime_us)"
echo "-----------------------------------------------------------"
if (( ACH <= EXP + 5 )); then
  echo "RESULT: PASS - CBS server HOLDS (busy RT task throttled to ~reservation)."
else
  echo "RESULT: FAIL - busy RT task ran ${ACH}% (NOT throttled)."
  echo "        Likely global sched_rt_runtime_us=-1 or an unseeded/over-committed chain."
fi
