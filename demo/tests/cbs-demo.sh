#!/usr/bin/env bash
#
# cbs-demo.sh - demonstrate SCHED_DEADLINE / CBS bandwidth isolation between
# competing real-time containers.
#
# WHERE TO RUN: as root, ON THE WORKER node (needs /sys/fs/cgroup + chrt +
# taskset). Cleans up every loop it spawns on exit.
#
#   sudo ./cbs-demo.sh [seconds] [core]
#       seconds : measurement window           (default 5)
#       core    : CPU core to contend on       (default: the core shared by the
#                 most RT containers)
#
# WHAT IT DOES:
#   1. Discovers every RT workload container scope (non-zero cpu.rt_runtime_us).
#   2. Picks one CPU core and selects all RT containers whose cpuset includes it.
#   3. Inside each selected container it starts a 100%-busy loop, pins it to that
#      single core, and promotes it to SCHED_FIFO prio 90 (an H-CBS level-2 task).
#   4. Every loop now *wants* the whole core, but each container is a separate
#      SCHED_DEADLINE/CBS server (level 1) capped at its reservation. After the
#      window it prints the CPU share each container actually obtained.
#
# EXPECTED RESULT: each container is throttled to runtime/period (e.g. 100/1000
# = 10%) no matter how many compete; the CBS servers isolate them and the core
# is left partly idle. That is the SCHED_DEADLINE bandwidth guarantee.
#
set -euo pipefail

CG=${CG:-/sys/fs/cgroup}
DUR=${1:-5}
FORCE_CORE=${2:-}

if [[ $EUID -ne 0 ]]; then
  echo "error: run as root (sudo $0 [seconds] [core])" >&2
  exit 1
fi
HZ=$(getconf CLK_TCK)

LOOP_PIDS=()
cleanup() {
  for p in "${LOOP_PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null || true; done
}
trap cleanup EXIT INT TERM

nonzero_rt() { [[ -n "${1// /}" && -n "$(echo "$1" | tr -d ' 0')" ]]; }

# expand_cpuset "0,2-3" -> "0 2 3"
expand_cpuset() {
  local part lo hi c out=()
  IFS=',' read -ra parts <<<"$1"
  for part in "${parts[@]}"; do
    part=${part// /}
    [[ -z $part ]] && continue
    if [[ $part == *-* ]]; then
      lo=${part%-*}; hi=${part#*-}
      for ((c=lo; c<=hi; c++)); do out+=("$c"); done
    else
      out+=("$part")
    fi
  done
  echo "${out[@]}"
}

# rt_percent <rt_runtime_value> <rt_period_value> -> integer-ish percentage
rt_percent() {
  local runtime period max=0 v
  for v in $1; do (( v > max )) && max=$v; done   # per-core list: take the reserved value
  period=$2
  [[ -z $period || $period -eq 0 ]] && { echo "?"; return; }
  awk -v r="$max" -v p="$period" 'BEGIN{ printf "%.1f", (r/p)*100 }'
}

# scope_name <id>
scope_name() {
  local id=$1 n
  if command -v crictl >/dev/null 2>&1; then
    n=$(crictl inspect "$id" 2>/dev/null | grep -m1 '"name"' \
          | sed -E 's/.*"name": *"([^"]+)".*/\1/') || true
    [[ -n ${n:-} ]] && { echo "$n"; return; }
  fi
  echo "${id:0:13}"
}

# read_jiffies <pid> -> utime+stime in clock ticks (0 if gone)
read_jiffies() {
  local s
  s=$(cat "/proc/$1/stat" 2>/dev/null) || { echo 0; return; }
  s=${s##*) }                       # drop "pid (comm) ", rest starts at field 3
  # shellcheck disable=SC2086
  set -- $s
  echo $(( ${12:-0} + ${13:-0} ))   # field14 utime + field15 stime
}

# ---- 1. discover RT workload scopes -------------------------------------------
declare -a S_PATH S_NAME S_RSV S_PER S_CORES
declare -A CORE_COUNT
mapfile -t scopes < <(find "$CG" -type d -path '*pod*.slice/*.scope' 2>/dev/null | sort)

for s in "${scopes[@]}"; do
  rt=$(cat "$s/cpu.rt_runtime_us" 2>/dev/null || echo 0)
  nonzero_rt "$rt" || continue                       # skip sandbox / non-RT
  per=$(cat "$s/cpu.rt_period_us" 2>/dev/null || echo 0)
  cs=$(cat "$s/cpuset.cpus.effective" 2>/dev/null || cat "$s/cpuset.cpus" 2>/dev/null || echo "")
  cores=$(expand_cpuset "$cs")
  [[ -z $cores ]] && continue
  id=$(basename "$s"); id=${id#cri-containerd-}; id=${id%.scope}
  S_PATH+=("$s"); S_NAME+=("$(scope_name "$id")")
  S_RSV+=("$rt"); S_PER+=("$per"); S_CORES+=("$cores")
  for c in $cores; do CORE_COUNT[$c]=$(( ${CORE_COUNT[$c]:-0} + 1 )); done
done

if [[ ${#S_PATH[@]} -eq 0 ]]; then
  echo "No RT workload containers found. Are the RT pods Running?"
  exit 1
fi

# ---- 2. assign each RT container a core to run on ------------------------------
# Default ("all" mode): every RT container runs simultaneously, each on its own
# first reserved core -> shows N containers each independently guaranteed their
# share under full load. If a core is FORCED and >=2 containers include it, those
# containers contend on that single core -> true same-core competition arbitrated
# by the CBS servers. LOOPS_PER_CTR>1 puts several busy loops in one container to
# show the tasks of a single CBS server sharing that server's reservation.
LOOPS=${LOOPS_PER_CTR:-1}

echo "===================================================================="
echo " CBS bandwidth-isolation demo"
if [[ -n $FORCE_CORE ]]; then
  echo " mode                : forced contention on core $FORCE_CORE"
else
  echo " mode                : all RT containers at once (each on its own core)"
fi
echo " loops per container : $LOOPS"
echo " window              : ${DUR}s   (CLK_TCK=${HZ} Hz)"
echo "===================================================================="

# ---- 3. start busy SCHED_FIFO loop(s) per container ---------------------------
declare -a R_KEY R_NAME R_CORE R_RSV R_PER R_LOOP R_START
for i in "${!S_PATH[@]}"; do
  if [[ -n $FORCE_CORE ]]; then
    case " ${S_CORES[$i]} " in *" $FORCE_CORE "*) core=$FORCE_CORE ;; *) continue ;; esac
  else
    core=${S_CORES[$i]%% *}            # first reserved core of this container
  fi
  leaf=${S_PATH[$i]}
  started=0
  for ((k=0; k<LOOPS; k++)); do
    taskset -c "$core" bash -c 'while :; do :; done' &
    lp=$!
    LOOP_PIDS+=("$lp")
    if ! echo "$lp" > "$leaf/cgroup.procs" 2>/dev/null; then
      echo "  ! could not move pid $lp into ${S_NAME[$i]} cgroup (skipping)"
      kill -9 "$lp" 2>/dev/null || true
      continue
    fi
    chrt -f -p 90 "$lp" 2>/dev/null || echo "  ! could not set SCHED_FIFO on ${S_NAME[$i]}"
    R_KEY+=("${S_NAME[$i]}@$core"); R_NAME+=("${S_NAME[$i]}"); R_CORE+=("$core")
    R_RSV+=("${S_RSV[$i]}"); R_PER+=("${S_PER[$i]}")
    R_LOOP+=("$lp"); R_START+=("$(read_jiffies "$lp")")
    started=$((started+1))
  done
  [[ $started -gt 0 ]] && echo "  started $started busy FIFO/90 loop(s) in '${S_NAME[$i]}' on core $core"
done

if [[ ${#R_LOOP[@]} -eq 0 ]]; then
  echo "No RT container matched. cores in use -> ${!CORE_COUNT[*]}"
  [[ -n $FORCE_CORE ]] && echo "(no RT container includes core $FORCE_CORE)"
  exit 1
fi

# ---- 4. measure ----------------------------------------------------------------
echo "--------------------------------------------------------------------"
echo "running for ${DUR}s ..."
sleep "$DUR"

# Aggregate achieved CPU per container (sum its loops) and per core.
declare -A ACH_BY RSV_BY CORE_OF CORE_TOT
for i in "${!R_LOOP[@]}"; do
  endj=$(read_jiffies "${R_LOOP[$i]}")
  used=$(( endj - R_START[$i] ))
  ach=$(awk -v u="$used" -v d="$DUR" -v hz="$HZ" 'BEGIN{ printf "%.4f", (u/(d*hz))*100 }')
  key=${R_KEY[$i]}
  ACH_BY[$key]=$(awk -v a="${ACH_BY[$key]:-0}" -v b="$ach" 'BEGIN{ printf "%.4f", a+b }')
  RSV_BY[$key]=$(rt_percent "${R_RSV[$i]}" "${R_PER[$i]}")
  CORE_OF[$key]=${R_CORE[$i]}
  CORE_TOT[${R_CORE[$i]}]=$(awk -v a="${CORE_TOT[${R_CORE[$i]}]:-0}" -v b="$ach" 'BEGIN{ printf "%.4f", a+b }')
done

printf '%-26s %-8s %-12s %-12s\n' "CONTAINER" "CORE" "RESERVED%" "ACHIEVED%"
printf '%-26s %-8s %-12s %-12s\n' "--------------------------" "----" "---------" "---------"
for key in "${!ACH_BY[@]}"; do
  printf '%-26s %-8s %-12s %-12s\n' "${key%@*}" "${CORE_OF[$key]}" "${RSV_BY[$key]}" \
         "$(printf '%.1f' "${ACH_BY[$key]}")"
done | sort
echo "--------------------------------------------------------------------"
for c in "${!CORE_TOT[@]}"; do
  printf 'core %-3s total used : %5.1f%%   (rest left idle by the CBS servers)\n' \
         "$c" "${CORE_TOT[$c]}"
done | sort
echo "Each CBS server caps its container at runtime/period regardless of demand."
echo "When >1 container shares a core their guaranteed shares add up but never"
echo "exceed the reservations => SCHED_DEADLINE bandwidth isolation."
