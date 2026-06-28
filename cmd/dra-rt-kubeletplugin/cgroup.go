package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// func UpdateParentCgroup(claim *drapbv1.Claim, crd nascrd.NodeAllocationStateSpec) {
// 	podUID := crd.AllocatedClaims[claim.Uid].RtCpu.CgroupUID

// 	// podUIDFormatted := strings.ReplaceAll(podUID, "-", "_") // TODO: must add to pod cgroup too?

// 	cgroupBasePath := "/sys/fs/cgroup/cpu,cpuacct"

// 	// Update the KubePods cgroup
// 	cgroupKubePods := filepath.Join(cgroupBasePath, "kubepods.slice")
// 	fmt.Println("kubepods:", cgroupKubePods)
// 	writeToParentMultiRuntime(cgroupKubePods, podRuntimes)

// 	// Update the KubePodsBestEffort cgroup
// 	cgroupKubePodsBestEffort := filepath.Join(cgroupBasePath, "kubepods.slice", "kubepods-besteffort.slice")
// 	fmt.Println("kubepodsbesteffort:", cgroupKubePodsBestEffort)
// 	writeToParentMultiRuntime(cgroupKubePodsBestEffort, podRuntimes)

// }

func readCpuRtMultiRuntimeFile(filePath string) ([]int64, error) {

	fileInfo, err := os.Stat(filePath)
	if err != nil {
		fmt.Println("Error stating file:", err)
		return nil, err
	}

	fmt.Printf("File permissions: %v\n", fileInfo.Mode())

	buf, err := os.ReadFile(filePath)
	if err != nil {
		return nil, err
	}

	fmt.Println("buf:", buf)

	runtimeStrings := strings.Split(string(buf), " ")
	runtimeStrings = runtimeStrings[:len(runtimeStrings)-2]
	fmt.Println("runtimeStrings:", runtimeStrings)

	runtimes := make([]int64, 0, len(runtimeStrings))
	for _, runtimeStr := range runtimeStrings {
		v, err := strconv.ParseInt(runtimeStr, 10, 32)
		if err != nil {
			panic(fmt.Errorf("error parsing runtime %s in file %s: %v", runtimeStr, filePath, err))
		}
		runtimes = append(runtimes, v)
	}
	return runtimes, nil
}

func writeToParentMultiRuntime(path string, podRuntimes []int) error {
	filePath := filepath.Join(path, "cpu.rt_multi_runtime_us")
	str := ""
	runtimes, _ := readCpuRtMultiRuntimeFile(filePath)
	fmt.Println("runtimes:", runtimes)
	fmt.Println("podRuntimes:", podRuntimes)

	newRuntimes := runtimes

	for cpu, runtime := range newRuntimes {
		newRuntimes[cpu] = runtimes[cpu] + int64(podRuntimes[cpu])
		str = str + strconv.Itoa(cpu) + " " + strconv.FormatInt(runtime, 10) + " "
	}
	fmt.Println("new runtimes:", newRuntimes)
	fmt.Println("new runtimes string:", str)

	fmt.Println("filepath:", filePath)
	if rerr := os.WriteFile(filePath, []byte(str), os.ModePerm); rerr != nil {
		return rerr
	}
	return nil
}

func removeRuntimeFromParent() error {
	return nil
}
