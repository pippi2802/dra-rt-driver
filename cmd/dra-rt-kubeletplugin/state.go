package main

import (
	"fmt"
	"strconv"
	"sync"

	nascrd "github.com/pippi2802/dra-rt-driver/api/example.com/resource/rt/nas/v1alpha1"
)

type AllocatableRtCpus map[int]*AllocatableCpusetInfo
type PreparedClaims map[string]*PreparedCpuset
type AllocatedUtil map[int]int

type RtCpuInfo struct {
	id   int
	util int
}

type PreparedRtCpuInfo struct {
	id      int
	util    int
	runtime int
	period  int
}

type PreparedRtCpu struct {
	Cpuset []*PreparedRtCpuInfo
}

type PreparedCpuset struct {
	RtCpu *PreparedRtCpu
}

func (d PreparedCpuset) Type() string {
	if d.RtCpu != nil {
		return nascrd.RtCpuType
	}
	return nascrd.UnknownDeviceType
}

type AllocatableCpusetInfo struct {
	*RtCpuInfo
}

type preparedCgroup struct {
	cgroupUID string
}

type DeviceState struct {
	sync.Mutex
	cdi             *CDIHandler
	allocatable     AllocatableRtCpus
	prepared        PreparedClaims
	allocatedUtil   AllocatedUtil
	preparedCgroups map[string]preparedCgroup
}

func NewDeviceState(config *Config) (*DeviceState, error) {
	// allocatable, err := enumerateAllPossibleDevices()
	// if err != nil {
	// 	return nil, fmt.Errorf("error enumerating all possible devices: %v", err)
	// }
	allocatable, err := enumerateCpusets()
	if err != nil {
		return nil, fmt.Errorf("error enumerating cpusets: %v", err)
	}

	cdi, err := NewCDIHandler(config)
	if err != nil {
		return nil, fmt.Errorf("unable to create CDI handler: %v", err)
	}

	err = cdi.CreateCommonSpecFile()
	if err != nil {
		return nil, fmt.Errorf("unable to create CDI spec file for common edits: %v", err)
	}

	state := &DeviceState{
		cdi:             cdi,
		allocatable:     allocatable,
		prepared:        make(PreparedClaims),
		allocatedUtil:   make(AllocatedUtil),
		preparedCgroups: make(map[string]preparedCgroup),
	}
	err = state.syncAllocatedUtilFromAllocatableRtCpu()
	if err != nil {
		return nil, fmt.Errorf("unable to sync allocated util from allocatable: %v", err)
	}
	err = state.syncPreparedCpusetFromCRDSpec(&config.nascr.Spec)
	if err != nil {
		return nil, fmt.Errorf("unable to sync prepared devices from CRD: %v", err)
	}

	// err = state.syncAllocatedUtilToCRDSpec(&config.nascr.Spec)
	// if err != nil {
	// 	return nil, fmt.Errorf("unable to sync allocated util to crd spec: %v", err)
	// }

	fmt.Println("how many times the allocatable is synced to allocated util?")

	return state, nil
}

func (s *DeviceState) Prepare(claimUID string, allocation nascrd.AllocatedCpuset, rtCDIDevices []string) ([]string, error) {
	s.Lock()
	defer s.Unlock()
	fmt.Println("s.allocatable from state.go prepare function:", s.allocatable)

	if s.prepared[claimUID] != nil {
		cdiDevices, err := s.cdi.GetClaimDevices(claimUID, s.prepared[claimUID], rtCDIDevices)
		if err != nil {
			return nil, fmt.Errorf("unable to get CDI devices names: %v", err)
		}
		return cdiDevices, nil
	}

	prepared := &PreparedCpuset{}

	var err error
	switch allocation.Type() {
	case nascrd.RtCpuType:
		prepared.RtCpu, err = s.prepareRtCpus(claimUID, allocation.RtCpu)
	default:
		err = fmt.Errorf("unknown device type: %v", allocation.Type())
	}
	if err != nil {
		return nil, fmt.Errorf("allocation failed: %v", err)
	}
	err = s.cdi.CreateClaimSpecFile(claimUID, prepared, rtCDIDevices)
	if err != nil {
		return nil, fmt.Errorf("unable to create CDI spec file for claim: %v", err)
	}

	s.prepared[claimUID] = prepared

	cdiDevices, err := s.cdi.GetClaimDevices(claimUID, s.prepared[claimUID], rtCDIDevices)
	if err != nil {
		return nil, fmt.Errorf("unable to get CDI devices names: %v", err)
	}
	return cdiDevices, nil
}

func (s *DeviceState) Unprepare(claimUID string) error {
	s.Lock()
	defer s.Unlock()

	if s.prepared[claimUID] == nil {
		return nil
	}

	switch s.prepared[claimUID].Type() {
	case nascrd.RtCpuType:
		err := s.unprepareRtCpus(claimUID, s.prepared[claimUID])
		if err != nil {
			return fmt.Errorf("unprepare failed: %v", err)
		}
	default:
		return fmt.Errorf("unknown device type: %v", s.prepared[claimUID].Type())
	}

	err := s.cdi.DeleteClaimSpecFile(claimUID)
	if err != nil {
		return fmt.Errorf("unable to delete CDI spec file for claim: %v", err)
	}

	delete(s.prepared, claimUID)

	return nil
}

// func (s *DeviceState) prepareCgroups(claimUID string, allocated nascrd.AllocatedCpuset) (string, error) { // does not handle errors yet
// 	s.Lock()
// 	defer s.Unlock()

// 	cgroup := preparedCgroup{
// 		cgroupUID: allocated.RtCpu.CgroupUID,
// 	}
// 	s.preparedCgroups[claimUID] = cgroup
// 	return nascrd.AllocatedPodCgroupStatus, nil

// }
func (s *DeviceState) UnprepareCgroups() error {
	return nil
}

func (s *DeviceState) GetUpdatedSpec(inspec *nascrd.NodeAllocationStateSpec) (*nascrd.NodeAllocationStateSpec, error) {
	s.Lock()
	defer s.Unlock()

	outspec := inspec.DeepCopy()
	err := s.syncAllocatableRtCpusToCRDSpec(outspec)
	if err != nil {
		return nil, fmt.Errorf("synching allocatable devices to CRD spec: %v", err)
	}

	err = s.syncPreparedRtCpuToCRDSpec(outspec)
	if err != nil {
		return nil, fmt.Errorf("synching prepared devices to CRD spec: %v", err)
	}

	return outspec, nil
}

func (s *DeviceState) prepareRtCpus(claimUID string, allocated *nascrd.AllocatedRtCpu) (*PreparedRtCpu, error) {
	prepared := &PreparedRtCpu{}

	for _, device := range allocated.Cpuset {
		fmt.Println("device.ID:", device.ID)
		fmt.Println("s.allocatable:", s.allocatable)
		// if _, exists := s.allocatable[device.ID]; !exists {
		// 	return nil, fmt.Errorf("requested CPU does not exist: %v", device.ID)
		// }
		cpuInfo := &PreparedRtCpuInfo{
			id:      device.ID, //s.allocatable[device.ID].RtCpuInfo.id,
			util:    int(device.Runtime * 1000 / device.Period),
			runtime: device.Runtime,
		}

		prepared.Cpuset = append(prepared.Cpuset, cpuInfo)
	}

	return prepared, nil
}

func (s *DeviceState) unprepareRtCpus(claimUID string, devices *PreparedCpuset) error {
	return nil
}

func (s *DeviceState) syncAllocatableRtCpusToCRDSpec(spec *nascrd.NodeAllocationStateSpec) error {
	cpus := make(map[int]nascrd.AllocatableCpuset)
	for _, device := range s.allocatable {
		cpus[device.id] = nascrd.AllocatableCpuset{
			RtCpu: &nascrd.AllocatableCpu{
				ID:   device.id,
				Util: device.util,
			},
		}
	}

	var allocatable []nascrd.AllocatableCpuset
	for _, device := range cpus {
		allocatable = append(allocatable, device)
	}

	spec.AllocatableCpuset = allocatable

	return nil
}

func (s *DeviceState) syncPreparedCpusetFromCRDSpec(spec *nascrd.NodeAllocationStateSpec) error {
	cpus := s.allocatable

	prepared := make(PreparedClaims)
	for claim, devices := range spec.PreparedClaims {
		switch devices.Type() {
		case nascrd.RtCpuType:
			prepared[claim] = &PreparedCpuset{RtCpu: &PreparedRtCpu{}}
			for _, d := range devices.RtCpu.Cpuset {
				cpu := &PreparedRtCpuInfo{
					id:   cpus[d.ID].id,
					util: cpus[d.ID].util,
				}
				prepared[claim].RtCpu.Cpuset = append(prepared[claim].RtCpu.Cpuset, cpu)
			}
		default:
			return fmt.Errorf("unknown device type: %v", devices.Type())
		}
	}

	s.prepared = prepared

	return nil
}

func (s *DeviceState) syncPreparedRtCpuToCRDSpec(spec *nascrd.NodeAllocationStateSpec) error {
	outcas := make(map[string]nascrd.PreparedCpuset)
	for claim, devices := range s.prepared {
		var prepared nascrd.PreparedCpuset
		switch devices.Type() {
		case nascrd.RtCpuType:
			prepared.RtCpu = &nascrd.PreparedRtCpu{}
			for _, device := range devices.RtCpu.Cpuset {
				outdevice := nascrd.PreparedCpu{
					ID:   device.id,
					Util: device.util,
				}
				prepared.RtCpu.Cpuset = append(prepared.RtCpu.Cpuset, outdevice)
			}
		default:
			return fmt.Errorf("unknown device type: %v", devices.Type())
		}
		outcas[claim] = prepared
	}
	spec.PreparedClaims = outcas

	return nil
}

// func (s *DeviceState) syncAllocatedUtilFromCRDSpec(spec *nascrd.NodeAllocationStateSpec) error {
// 	allocatedUtil := make(AllocatedUtil)
// 	for _, device := range spec.AllocatedUtilToCpu {
// 		allocatedUtil[device.RtUtil.ID] = device.RtUtil.Util
// 	}
// 	s.allocatedUtil = allocatedUtil
// 	return nil
// }

func (s *DeviceState) syncAllocatedUtilToCRDSpec(spec *nascrd.NodeAllocationStateSpec) error {
	allocatedUtil := make(nascrd.MappedUtil)
	for id, util := range s.allocatedUtil {
		allocatedUtil[strconv.Itoa(id)] = nascrd.AllocatedUtil{
			Util: util,
		}

	}
	spec.AllocatedUtilToCpu = nascrd.AllocatedUtilset{
		Cpus: allocatedUtil,
	}
	return nil
}

func (s *DeviceState) syncAllocatedUtilFromAllocatableRtCpu() error {
	allocatedUtilmap := make(map[int]int)
	for _, device := range s.allocatable {
		allocatedUtilmap[device.id] = device.util
	}
	s.allocatedUtil = allocatedUtilmap
	return nil
}
