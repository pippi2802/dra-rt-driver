/*
 * Copyright 2023 The Kubernetes Authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package main

import (
	"encoding/hex"
	"fmt"
	"math/rand"
	"os"
	"strconv"
	"strings"

	cdiapi "github.com/container-orchestrated-devices/container-device-interface/pkg/cdi"
	cdispec "github.com/container-orchestrated-devices/container-device-interface/specs-go"
	drapbv1 "k8s.io/kubelet/pkg/apis/dra/v1alpha3"
	klog "k8s.io/klog/v2"

	nascrd "github.com/pippi2802/dra-rt-driver/api/example.com/resource/rt/nas/v1alpha1"
)

const (
	cdiVendor = "k8s." + DriverName
	cdiClass  = "cpu"
	cdiKind   = cdiVendor + "/" + cdiClass

	cdiCommonDeviceName = "common"
)

// rtlog is a thin wrapper around klog used for tracing the RT CDI spec flow.
func rtlog(format string, args ...interface{}) {
	klog.Infof("hcbs-cdi: "+format, args...)
}

// atLeastCDIVersion floors a CDI spec version at v0.5.0. MinimumRequiredVersion
// returns 0.3.0 for our env-only specs, but newer containerd CDI implementations
// reject any spec below v0.5.0 ("the spec version must be at least v0.5.0") and a
// single invalid spec aborts the ENTIRE registry refresh, making every device
// unresolvable. Our specs only use Env edits (valid since 0.3.0), and v0.5.0 is
// the highest version supported by container-device-interface v0.5.4 (the
// version this driver vendors), so it is always a safe floor.
func atLeastCDIVersion(v string) string {
	switch v {
	case "0.1.0", "0.2.0", "0.3.0", "0.4.0":
		return "0.5.0"
	default:
		return v
	}
}

type CDIHandler struct {
	registry cdiapi.Registry
}

func NewCDIHandler(config *Config) (*CDIHandler, error) {
	registry := cdiapi.GetRegistry(
		cdiapi.WithSpecDirs(config.flags.cdiRoot),
	)

	err := registry.Refresh()
	if err != nil {
		return nil, fmt.Errorf("unable to refresh the CDI registry: %v", err)
	}

	handler := &CDIHandler{
		registry: registry,
	}

	return handler, nil
}

func (cdi *CDIHandler) GetDevice(device string) *cdiapi.Device {
	return cdi.registry.DeviceDB().GetDevice(device)
}

func (cdi *CDIHandler) CreateCommonSpecFile() error {
	spec := &cdispec.Spec{
		Kind: cdiKind,
		Devices: []cdispec.Device{
			{
				Name: cdiCommonDeviceName,
				ContainerEdits: cdispec.ContainerEdits{
					Env: []string{
						fmt.Sprintf("RT_NODE_NAME=%s", os.Getenv("NODE_NAME")),
						fmt.Sprintf("DRA_RESOURCE_DRIVER_NAME=%s", DriverName),
					},
				},
			},
		},
	}

	minVersion, err := cdiapi.MinimumRequiredVersion(spec)
	if err != nil {
		return fmt.Errorf("failed to get minimum required CDI spec version: %v", err)
	}
	spec.Version = atLeastCDIVersion(minVersion)
	// randomStr, err := generateRandomString(5)
	specName, err := cdiapi.GenerateNameForTransientSpec(spec, cdiCommonDeviceName)
	if err != nil {
		return fmt.Errorf("failed to generate Spec name: %w", err)
	}
	return cdi.registry.SpecDB().WriteSpec(spec, specName)
	// return nil
}

func generateRandomString(n int) (string, error) {
	bytes := make([]byte, n)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	return hex.EncodeToString(bytes), nil
}

func (cdi *CDIHandler) CreateClaimSpecFile(claimUID string, devices *PreparedCpuset, rtCDIDevices []string) error {
	specName := cdiapi.GenerateTransientSpecName(cdiVendor, cdiClass, claimUID)

	fmt.Println("rtcdidevices:", rtCDIDevices)
	rtlog("CreateClaimSpecFile claim=%s specName=%s rtCDIDevices=%v", claimUID, specName, rtCDIDevices)

	switch devices.Type() {
	case nascrd.RtCpuType:
		if rtCDIDevices == nil || len(rtCDIDevices) < 2 {
			rtlog("CreateClaimSpecFile claim=%s GUARD TRIPPED (rtCDIDevices nil/len<2) -> per-claim spec NOT written", claimUID)
			return fmt.Errorf("rtCDIDevices is nil or incomplete: %v", rtCDIDevices)
		}
	default:
		return fmt.Errorf("unknown device type: %v", devices.Type())
	}

	// The Kind/device name written here MUST match exactly what GetClaimDevices
	// advertises to the kubelet, namely:
	//   QualifiedName(rtCDIDevices[0], "CPUSET", rtCDIDevices[1])
	//   => "<rtCDIDevices[0]>/CPUSET=<rtCDIDevices[1]>"
	// where rtCDIDevices[0] is "runtime-<R>.period-<P>" and rtCDIDevices[1] is
	// the cpuset string (e.g. "1" or "1-2"). Without this spec on disk, a
	// CDI-enforcing containerd rejects the pod with "unresolvable CDI devices".
	kind := rtCDIDevices[0] + "/CPUSET"
	deviceName := rtCDIDevices[1]

	spec := &cdispec.Spec{
		Kind: kind,
		Devices: []cdispec.Device{
			{
				Name: deviceName,
				ContainerEdits: cdispec.ContainerEdits{
					Env: []string{
						fmt.Sprintf("RT_RUNTIME_PERIOD=%s", rtCDIDevices[0]),
						fmt.Sprintf("RT_CPUSET=%s", rtCDIDevices[1]),
					},
				},
			},
		},
	}

	minVersion, err := cdiapi.MinimumRequiredVersion(spec)
	if err != nil {
		return fmt.Errorf("failed to get minimum required CDI spec version: %v", err)
	}
	spec.Version = atLeastCDIVersion(minVersion)
	if werr := cdi.registry.SpecDB().WriteSpec(spec, specName); werr != nil {
		rtlog("CreateClaimSpecFile claim=%s WriteSpec FAILED specName=%s: %v", claimUID, specName, werr)
		return werr
	}
	rtlog("CreateClaimSpecFile claim=%s WriteSpec OK -> per-claim spec WRITTEN to CDI root (kind=%s device=%s)", claimUID, kind, deviceName)
	return nil
}

func (cdi *CDIHandler) DeleteClaimSpecFile(claimUID string) error {
	specName := cdiapi.GenerateTransientSpecName(cdiVendor, cdiClass, claimUID)
	return cdi.registry.SpecDB().RemoveSpec(specName)
}

func (cdi *CDIHandler) GetClaimDevices(claimUID string, devices *PreparedCpuset, rtCDIDevices []string) ([]string, error) {
	cdiDevices := []string{
		// cdiapi.QualifiedName(cdiVendor, cdiClass, cdiCommonDeviceName),
	} // TODO: could we append the cpusets in different cdi devices?

	switch devices.Type() {
	case nascrd.RtCpuType:
		// for _, device := range devices.RtCpu.Cpuset {
		// cdiDevice := cdiapi.QualifiedName(cdiVendor, cdiClass, rtCDIDevices)
		if rtCDIDevices != nil {
			cdiDevice := cdiapi.QualifiedName(rtCDIDevices[0], "CPUSET", rtCDIDevices[1])
			fmt.Println("getclaimdevices:")
			fmt.Println(rtCDIDevices[0])
			fmt.Println(rtCDIDevices[1])
			fmt.Println(cdiDevice)
			cdiDevices = append(cdiDevices, cdiDevice)

		} else {
			return nil, fmt.Errorf("rtcdidevices is nil")
		}
	default:
		return nil, fmt.Errorf("unknown device type: %v", devices.Type())
	}

	return cdiDevices, nil
}

func (cdi *CDIHandler) WriteCgroupToCDI(claim *drapbv1.Claim, crd nascrd.NodeAllocationStateSpec) ([]string, error) {
	if _, ok := crd.AllocatedClaims[claim.Uid]; ok {
		if crd.AllocatedClaims[claim.Uid].RtCpu == nil {
			rtlog("WriteCgroupToCDI claim=%s present in cached NAS but RtCpu==nil", claim.Uid)
			return nil, fmt.Errorf("claim %v does not have rtcpu", claim.Uid)
		} else {
			if crd.AllocatedClaims[claim.Uid].RtCpu.CgroupUID == "" {
				rtlog("WriteCgroupToCDI claim=%s present in cached NAS but CgroupUID empty", claim.Uid)
				return nil, fmt.Errorf("claim %v does not have cgroupuid", claim.Uid)
			}
		}
	} else {
		rtlog("WriteCgroupToCDI claim=%s NOT in cached NAS AllocatedClaims (stale cache / race) -> returning empty", claim.Uid)
		return nil, fmt.Errorf("claim %v does not exist", claim.Uid)
	}
	// allocatedCgroups := crd.AllocatedPodCgroups[cgroupUID]
	rtCDIDevices := []string{}
	runtime := ""
	period := ""
	cpusets := ""
	runtime = fmt.Sprintf("runtime-%v", crd.AllocatedClaims[claim.Uid].RtCpu.Cpuset[0].Runtime)
	period = fmt.Sprintf("period-%v", crd.AllocatedClaims[claim.Uid].RtCpu.Cpuset[0].Period)
	var builder strings.Builder
	for _, cgroup := range crd.AllocatedClaims[claim.Uid].RtCpu.Cpuset {
		fmt.Println("allocatedCgroups:", cgroup)
		if builder.Len() > 0 {
			builder.WriteString("-") // TODO: change this later to comma
		}
		builder.WriteString(strconv.Itoa(cgroup.ID))
	}
	fmt.Println("cgroup.go, builder:", builder.String())
	claimCpuset := builder.String()
	// if claimCpuset == "" {
	// 	claimCpuset = "0"
	// }
	cpusets = fmt.Sprintf("%v", claimCpuset)

	rtCDIDevices = append(rtCDIDevices, fmt.Sprintf("%v.%v", runtime, period))
	rtCDIDevices = append(rtCDIDevices, cpusets)
	fmt.Println("writecgrouptocdi, rtcdidevices:", rtCDIDevices)

	return rtCDIDevices, nil

}
