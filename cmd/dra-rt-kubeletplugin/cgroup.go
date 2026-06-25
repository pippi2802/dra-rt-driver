package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"k8s.io/klog/v2"

	nascrd "github.com/nasim-samimi/dra-rt-driver/api/example.com/resource/rt/nas/v1alpha1"
)

// Real-time (HCBS) cgroup v2 seeding.
//
// On a pure cgroup v2 (unified) hierarchy with the systemd cgroup driver, the
// leaf scope of a pod cannot be given an RT (SCHED_FIFO/RR) budget unless every
// ancestor slice already has one. The kernel admission test enforces, on every
// core, that a child's rt_runtime never exceeds its parent's rt_runtime.
//
// The driver therefore seeds the whole chain itself:
//
//	/sys/fs/cgroup                                                  (root)
//	  kubepods.slice                                               (parent)
//	    kubepods-besteffort.slice                                  (QoS parent)
//	      kubepods-besteffort-pod<UID>.slice                       (pod slice)
//	        cri-containerd-<containerID>.scope                     (leaf)
//
// Parents (root, kubepods, besteffort) get a generous *scalar* reservation that
// applies to all cores. The pod slice and the leaf scope(s) get the exact
// per-core reservation requested by the claim.
//
// The pod slice and leaf scope usually do not exist yet at NodePrepareResources
// time (the kubelet creates them only when it actually starts the pod), so the
// pod/leaf seeding runs in a background goroutine that polls for them to appear.

const (
	// cgroupRoot is the unified cgroup v2 mount point inside the plugin
	// container (the host /sys/fs/cgroup is mounted here, see the DaemonSet).
	cgroupRoot = "/sys/fs/cgroup"

	rtRuntimeFile = "cpu.rt_runtime_us"
	rtPeriodFile  = "cpu.rt_period_us"

	// Generous reservation for the stable parent slices: 95% of a 1s period,
	// applied as a scalar to every core. This is the standard global RT bound
	// (kernel.sched_rt_runtime_us / kernel.sched_rt_period_us) and leaves enough
	// headroom for any per-pod reservation that fits the global bound.
	parentRtPeriodUs  = "1000000"
	parentRtRuntimeUs = "950000"

	// How long to wait for the pod slice and leaf scope to appear before giving
	// up, and how often to poll for them.
	seedPollInterval = 200 * time.Millisecond
	seedTimeout      = 60 * time.Second
)

// seedRtCgroupForClaim seeds the full RT cgroup chain for the pod that owns the
// given claim. The stable parents are seeded synchronously; the pod slice and
// its leaf scope(s) are seeded by a background goroutine because they may not
// exist yet. This function never returns an error: a failure to seed must not
// prevent the pod from reaching Running, it only means it will run without an
// RT budget (which is logged).
func seedRtCgroupForClaim(claimUID string, crd nascrd.NodeAllocationStateSpec) {
	alloc, ok := crd.AllocatedClaims[claimUID]
	if !ok || alloc.RtCpu == nil {
		klog.Warningf("hcbs: claim %v has no rtcpu allocation; skipping cgroup seeding", claimUID)
		return
	}
	if len(alloc.RtCpu.Cpuset) == 0 {
		klog.Warningf("hcbs: claim %v has empty cpuset; skipping cgroup seeding", claimUID)
		return
	}
	podUID := alloc.RtCpu.CgroupUID
	if podUID == "" {
		klog.Warningf("hcbs: claim %v has no cgroupUID; skipping cgroup seeding", claimUID)
		return
	}

	runtimeList := buildPerCoreRuntime(alloc.RtCpu.Cpuset)
	periodVal := strconv.Itoa(alloc.RtCpu.Cpuset[0].Period)

	klog.Infof("hcbs: seeding RT cgroup chain for claim %v pod %v: runtime=%q period=%q",
		claimUID, podUID, runtimeList, periodVal)

	// 1) Stable parents: these always exist, seed them now (idempotent).
	seedStableParents()

	// 2) Pod slice + leaf scope(s): may not exist yet, seed in the background.
	go seedPodAndLeafDeferred(podUID, runtimeList, periodVal)
}

// buildPerCoreRuntime renders the allocated cores in the HCBS multi-core form
// expected by cpu.rt_runtime_us on the rt-cgroups-multi kernel:
//
//	"<runtime> <cpu> <runtime> <cpu> ..."
//
// The runtime always comes first and any core not listed is reset to 0.
func buildPerCoreRuntime(cpuset []nascrd.AllocatedCpu) string {
	parts := make([]string, 0, len(cpuset))
	for _, c := range cpuset {
		parts = append(parts, fmt.Sprintf("%d %d", c.Runtime, c.ID))
	}
	return strings.Join(parts, " ")
}

// seedStableParents writes the generous scalar reservation to the root,
// kubepods and besteffort slices. These writes are best-effort: the root may
// already be at the global bound and reject the write, which is fine.
func seedStableParents() {
	parents := []string{
		cgroupRoot,
		filepath.Join(cgroupRoot, "kubepods.slice"),
		filepath.Join(cgroupRoot, "kubepods.slice", "kubepods-besteffort.slice"),
	}
	for _, dir := range parents {
		if _, err := os.Stat(dir); err != nil {
			klog.Warningf("hcbs: parent slice %s does not exist: %v", dir, err)
			continue
		}
		writeRtBudget(dir, parentRtRuntimeUs, parentRtPeriodUs)
	}
}

// podSlicePath builds the systemd cgroup v2 path of a BestEffort pod slice.
// systemd escapes '-' in the pod UID to '_' inside the slice name.
func podSlicePath(podUID string) string {
	escaped := strings.ReplaceAll(podUID, "-", "_")
	return filepath.Join(
		cgroupRoot,
		"kubepods.slice",
		"kubepods-besteffort.slice",
		"kubepods-besteffort-pod"+escaped+".slice",
	)
}

// seedPodAndLeafDeferred polls for the pod slice and its leaf scope(s) to be
// created by the kubelet and seeds each one with the exact per-core
// reservation. It seeds the pod slice as soon as it appears, then keeps seeding
// every new "*.scope" leaf (pause + workload containers) until the timeout.
func seedPodAndLeafDeferred(podUID, runtimeList, periodVal string) {
	podDir := podSlicePath(podUID)

	deadline := time.Now().Add(seedTimeout)
	seededPod := false
	seededLeaves := map[string]bool{}

	for time.Now().Before(deadline) {
		if !seededPod {
			if _, err := os.Stat(podDir); err == nil {
				writeRtBudget(podDir, runtimeList, periodVal)
				seededPod = true
				klog.Infof("hcbs: seeded pod slice %s", podDir)
			}
		}

		if seededPod {
			entries, err := os.ReadDir(podDir)
			if err == nil {
				for _, e := range entries {
					name := e.Name()
					if e.IsDir() && strings.HasSuffix(name, ".scope") && !seededLeaves[name] {
						leafDir := filepath.Join(podDir, name)
						writeRtBudget(leafDir, runtimeList, periodVal)
						seededLeaves[name] = true
						klog.Infof("hcbs: seeded leaf scope %s", leafDir)
					}
				}
			}
		}

		time.Sleep(seedPollInterval)
	}

	if !seededPod {
		klog.Warningf("hcbs: pod slice %s never appeared within %s; pod will run without RT budget", podDir, seedTimeout)
	} else if len(seededLeaves) == 0 {
		klog.Warningf("hcbs: no leaf scope appeared under %s within %s; pod will run without RT budget", podDir, seedTimeout)
	}
}

// writeRtBudget seeds a single cgroup directory with an RT reservation, using
// the runtime -> period -> runtime ordering recommended for HCBS.
//
// A freshly created slice starts with period == 0, so a runtime-first write can
// be rejected with EINVAL; that first write is therefore best-effort. Writing
// the period and then the runtime is what actually installs the reservation.
// All writes are non-fatal and logged, so a seeding failure never blocks the
// pod.
func writeRtBudget(dir, runtimeVal, periodVal string) {
	// Best-effort priming write (expected to fail while period is still 0).
	if runtimeVal != "" {
		_ = writeCgroupFile(dir, rtRuntimeFile, runtimeVal)
	}

	if periodVal != "" {
		if err := writeCgroupFile(dir, rtPeriodFile, periodVal); err != nil {
			klog.Warningf("hcbs: failed to write %s in %s: %v", rtPeriodFile, dir, err)
			return
		}
	}

	if runtimeVal != "" {
		if err := writeCgroupFile(dir, rtRuntimeFile, runtimeVal); err != nil {
			klog.Warningf("hcbs: failed to write %s in %s: %v (check that all ancestor slices are seeded)", rtRuntimeFile, dir, err)
			return
		}
		klog.V(4).Infof("hcbs: seeded %s with runtime=%q period=%q", dir, runtimeVal, periodVal)
	}
}

// writeCgroupFile writes value to a cgroup control file. cgroup files must be
// opened O_WRONLY (no truncate), so we do not use os.WriteFile here.
func writeCgroupFile(dir, name, value string) error {
	path := filepath.Join(dir, name)
	f, err := os.OpenFile(path, os.O_WRONLY, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := f.Write([]byte(value)); err != nil {
		return fmt.Errorf("writing %q to %s: %w", value, path, err)
	}
	return nil
}
