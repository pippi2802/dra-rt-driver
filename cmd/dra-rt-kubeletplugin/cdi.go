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

	nascrd "github.com/nasim-samimi/dra-rt-driver/api/example.com/resource/rt/nas/v1alpha1"
)

const (
	cdiVendor = "k8s." + DriverName
	cdiClass  = "cpu"
	cdiKind   = cdiVendor + "/" + cdiClass

	cdiCommonDeviceName = "common"
)

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
	spec.Version = minVersion
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
	// specName := cdiapi.GenerateTransientSpecName(cdiVendor, cdiClass, claimUID)

	spec := &cdispec.Spec{
		Kind:    cdiKind,
		Devices: []cdispec.Device{},
	}
	fmt.Println("rtcdidevices:", rtCDIDevices)
	cpuIdx := 0
	switch devices.Type() {
	case nascrd.RtCpuType:
		for _, device := range devices.RtCpu.Cpuset {
			cdiDevice := cdispec.Device{
				Name: "cpu" + strconv.Itoa(device.id),
				ContainerEdits: cdispec.ContainerEdits{
					Env: []string{
						fmt.Sprintf("RT_DEVICE_%d=%v", cpuIdx, strconv.Itoa(device.id)),
					},
				},
			}
			spec.Devices = append(spec.Devices, cdiDevice)
			cpuIdx++
		}
	default:
		return fmt.Errorf("unknown device type: %v", devices.Type())
	}

	minVersion, err := cdiapi.MinimumRequiredVersion(spec)
	if err != nil {
		return fmt.Errorf("failed to get minimum required CDI spec version: %v", err)
	}
	spec.Version = minVersion

	specName := cdiapi.GenerateTransientSpecName(cdiVendor, cdiClass, claimUID)
	return cdi.registry.SpecDB().WriteSpec(spec, specName)
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
		for _, device := range devices.RtCpu.Cpuset {
			cdiDevices = append(cdiDevices,
				cdiapi.QualifiedName(cdiVendor, cdiClass, "cpu"+strconv.Itoa(device.id)))
		}
	default:
		return nil, fmt.Errorf("unknown device type: %v", devices.Type())
	}

	return cdiDevices, nil
}

func (cdi *CDIHandler) WriteCgroupToCDI(claim *drapbv1.Claim, crd nascrd.NodeAllocationStateSpec) ([]string, error) {
	if _, ok := crd.AllocatedClaims[claim.Uid]; ok {
		if crd.AllocatedClaims[claim.Uid].RtCpu == nil {
			return nil, fmt.Errorf("claim %v does not have rtcpu", claim.Uid)
		} else {
			if crd.AllocatedClaims[claim.Uid].RtCpu.CgroupUID == "" {
				return nil, fmt.Errorf("claim %v does not have cgroupuid", claim.Uid)
			}
		}
	} else {
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
