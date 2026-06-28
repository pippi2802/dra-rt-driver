#!/usr/bin/env bash
#
# verify-rt.sh - inspect the H-CBS real-time parameters of every RT container
# currently scheduled on this node.
#
# WHERE TO RUN: as root, ON THE WORKER node (needs /sys/fs/cgroup + crictl).
#   sudo ./verify-rt.sh
#
# WHAT IT SHOWS, for each per-pod cgroup slice that carries an RT reservation:
#   * the pod-slice budget               (cpu.rt_runtime_us / cpu.rt_period_us)
#   * every child scope                  (workload container(s) + pause sandbox)
#       - mapped to its crictl name
#       - per-core rt_runtime_us, rt_period_us, effective cpuset
#       - the scheduling policy + priority of each task in the scope
#
# HOW TO READ IT (the two H-CBS levels, Samimi et al. ECRTS'25):
#   LEVEL 1 - the cgroup itself is a SCHED_DEADLINE/CBS server the kernel builds
#             automatically from cpu.rt_runtime_us / cpu.rt_period_us.
#   LEVEL 2 - the tasks inside run SCHED_FIFO (typically prio 90).
#   A correct workload container therefore shows non-zero rt_runtime and its
#   busy task shows "SCHED_FIFO".  The pause/sandbox scope must show
#   rt_runtime_us == 0 (its budget is reclaimed by runc); if it is non-zero the
#   reclaim fix is missing or the cgroup state is stale -> the script WARNs.
#
set -euo pipefail

CG=${CG:-/sys/fs/cgroup}

if [[ $EUID -ne 0 ]]; then
  echo "error: run as root (sudo $0)" >&2
  exit 1
fi
if ! command -v crictl >/dev/null 2>&1; then
  echo "warning: crictl not found - scope names will show as IDs only" >&2
fi

hr() { printf '%s\n' "--------------------------------------------------------------------"; }

# nonzero_rt <value> : true if the cpu.rt_runtime_us value holds any RT budget.
# Handles both the scalar form ("950000") and the per-core list ("0 100 100 0").
nonzero_rt() { [[ -n "${1// /}" && -n "$(echo "$1" | tr -d ' 0')" ]]; }

# scope_name <id> : resolve a containerd scope id to a human name via crictl.
scope_name() {
  local id=$1 n
  if command -v crictl >/dev/null 2>&1; then
    n=$(crictl inspect "$id" 2>/dev/null | grep -m1 '"name"' \
          | sed -E 's/.*"name": *"([^"]+)".*/\1/') || true
    if [[ -n ${n:-} ]]; then echo "$n"; return; fi
    n=$(crictl inspectp "$id" 2>/dev/null | grep -m1 '"name"' \
          | sed -E 's/.*"name": *"([^"]+)".*/\1/') || true
    if [[ -n ${n:-} ]]; then echo "$n (sandbox)"; return; fi
  fi
  echo "<unknown>"
}

mapfile -t podslices < <(find "$CG" -type d -name '*pod*.slice' 2>/dev/null | sort)

found=0
warned=0
for pod in "${podslices[@]}"; do
  mapfile -t scopes < <(find "$pod" -mindepth 1 -maxdepth 1 -type d -name '*.scope' 2>/dev/null | sort)
  [[ ${#scopes[@]} -eq 0 ]] && continue

  # Does this pod slice (or any child) carry an RT reservation? Skip if not.
  has_rt=0
  podr=$(cat "$pod/cpu.rt_runtime_us" 2>/dev/null || echo 0)
  nonzero_rt "$podr" && has_rt=1
  for s in "${scopes[@]}"; do
    r=$(cat "$s/cpu.rt_runtime_us" 2>/dev/null || echo 0)
    nonzero_rt "$r" && has_rt=1
  done
  [[ $has_rt -eq 0 ]] && continue

  found=1
  hr
  echo "POD SLICE: ${pod#"$CG"/}"
  echo "    cpu.rt_runtime_us = $(cat "$pod/cpu.rt_runtime_us" 2>/dev/null || echo '?')"
  echo "    cpu.rt_period_us  = $(cat "$pod/cpu.rt_period_us"  2>/dev/null || echo '?')"

  for s in "${scopes[@]}"; do
    id=$(basename "$s"); id=${id#cri-containerd-}; id=${id%.scope}
    name=$(scope_name "$id")
    rt=$(cat "$s/cpu.rt_runtime_us" 2>/dev/null || echo '?')
    pr=$(cat "$s/cpu.rt_period_us"  2>/dev/null || echo '?')
    cs=$(cat "$s/cpuset.cpus.effective" 2>/dev/null || cat "$s/cpuset.cpus" 2>/dev/null || echo '?')
    echo "  +-- scope: $name   [${id:0:13}]"
    echo "  |      rt_runtime_us = $rt"
    echo "  |      rt_period_us  = $pr"
    echo "  |      cpuset        = $cs"

    # WARN: a sandbox must not hold RT budget after runc's reclaim.
    if [[ $name == *"(sandbox)"* ]] && nonzero_rt "$rt"; then
      echo "  |      !! WARNING: sandbox holds RT budget ($rt) - reclaim fix missing or stale state"
      warned=1
    fi

    # Tasks + scheduling policy (LEVEL 2 should be SCHED_FIFO for an active RT task).
    while read -r pid; do
      [[ -z $pid ]] && continue
      comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo '?')
      pol=$(chrt -p "$pid" 2>/dev/null | sed -n 's/.*scheduling policy: *//p')
      prio=$(chrt -p "$pid" 2>/dev/null | sed -n 's/.*priority: *//p' | tail -1)
      printf '  |      task pid=%-7s %-18s %-14s prio=%s\n' "$pid" "$comm" "${pol:-?}" "${prio:-?}"
    done < "$s/cgroup.procs"
  done
done

hr
if [[ $found -eq 0 ]]; then
  echo "No RT (real-time) cgroups found on this node."
  echo "Are the RT pods Running?  (on the control plane: kubectl get pods -A -o wide)"
elif [[ $warned -eq 0 ]]; then
  echo "OK: every sandbox scope has rt_runtime_us=0 and workload scopes carry their reservation."
else
  echo "ATTENTION: one or more sandbox scopes still hold RT budget (see WARNING above)."
  echo "Workaround: kubectl delete pod <pod> -n <ns> && kubectl apply -f <manifest>"
fi
