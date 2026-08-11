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
	"strconv"
	"sync"

	nascrd "github.com/pippi2802/dra-rt-driver/api/example.com/resource/rt/nas/v1alpha1"
)

type PerNodeAllocatedClaims struct {
	sync.RWMutex
	allocations map[string]map[string]nascrd.AllocatedCpuset
	utilisation map[string]nascrd.AllocatedUtilset
}

func NewPerNodeAllocatedClaims() *PerNodeAllocatedClaims {
	// initialise allocated util set from crd
	return &PerNodeAllocatedClaims{
		allocations: make(map[string]map[string]nascrd.AllocatedCpuset),
		utilisation: make(map[string]nascrd.AllocatedUtilset),
	}
}

func (p *PerNodeAllocatedClaims) Exists(claimUID, node string) bool {
	p.RLock()
	defer p.RUnlock()

	_, exists := p.allocations[claimUID]
	if !exists {
		return false
	}

	_, exists = p.allocations[claimUID][node]
	return exists
}
func (p *PerNodeAllocatedClaims) ExistsUtil(node string) bool {
	p.RLock()
	defer p.RUnlock()

	_, exists := p.utilisation[node]
	return exists
}

func (p *PerNodeAllocatedClaims) Get(claimUID, node string) nascrd.AllocatedCpuset {
	p.RLock()
	defer p.RUnlock()

	if !p.Exists(claimUID, node) {
		return nascrd.AllocatedCpuset{}
	}
	return p.allocations[claimUID][node]
}
func (p *PerNodeAllocatedClaims) GetUtil(node string) nascrd.AllocatedUtilset {
	p.RLock()
	defer p.RUnlock()

	if !p.ExistsUtil(node) {
		return nascrd.AllocatedUtilset{}
	}
	return p.utilisation[node]
}

// func (p *PerNodeAllocatedClaims) GetCgroup(node string) map[string]nascrd.PodCgroup {
// 	p.RLock()
// 	defer p.RUnlock()

// 	if !p.ExistsUtil(node) {
// 		return make(map[string]nascrd.PodCgroup)
// 	}
// 	return p.cgroups[node]
// }

func (p *PerNodeAllocatedClaims) VisitNode(node string, visitor func(claimUID string, allocation nascrd.AllocatedCpuset, utilisation nascrd.AllocatedUtilset)) {
	p.RLock()
	// defer p.RUnlock()
	for claimUID := range p.allocations {
		if allocation, exists := p.allocations[claimUID][node]; exists {
			utilisation := p.utilisation[node]
			// cgroup := p.cgroups[node][p.allocations[claimUID][node].RtCpu.CgroupUID]
			p.RUnlock()
			visitor(claimUID, allocation, utilisation)
			p.RLock()
		}
	}
	p.RUnlock()
}

func (p *PerNodeAllocatedClaims) Visit(visitor func(claimUID, node string, allocation nascrd.AllocatedCpuset)) {
	p.RLock()
	for claimUID := range p.allocations {
		for node, allocation := range p.allocations[claimUID] {
			p.RUnlock()
			visitor(claimUID, node, allocation)
			p.RLock()
		}
	}
	p.RUnlock()
}

func (p *PerNodeAllocatedClaims) Set(claimUID, node string, devices nascrd.AllocatedCpuset) {
	p.Lock()
	defer p.Unlock()

	if devices.RtCpu == nil {
		return
	}
	_, exists := p.allocations[claimUID]
	if !exists {
		p.allocations[claimUID] = make(map[string]nascrd.AllocatedCpuset)
	}

	p.allocations[claimUID][node] = devices
}

func (p *PerNodeAllocatedClaims) SetUtil(node string, devices nascrd.AllocatedUtilset) {
	p.Lock()
	defer p.Unlock()

	_, exists := p.utilisation[node]
	if !exists {
		p.utilisation[node] = nascrd.AllocatedUtilset{}
	}

	p.utilisation[node] = devices
}

// func (p *PerNodeAllocatedClaims) SetCgroup(cgroupUID string, node string, devices nascrd.PodCgroup) {
// 	p.Lock()
// 	defer p.Unlock()

// 	_, exists := p.cgroups[node]
// 	if !exists {
// 		p.cgroups[node] = make(map[string]nascrd.PodCgroup)
// 	}
// 	if _, exists = p.cgroups[node][cgroupUID]; !exists {
// 		if devices.Containers != nil {

// 			p.cgroups[node][cgroupUID] = devices
// 		}
// 	}
// }

func (p *PerNodeAllocatedClaims) RemoveNode(claimUID, node string) {
	p.Lock()
	defer p.Unlock()

	_, exists := p.allocations[claimUID]
	if !exists {
		return
	}

	delete(p.allocations[claimUID], node)
}

func (p *PerNodeAllocatedClaims) Remove(claimUID string) {
	p.Lock()
	defer p.Unlock()

	delete(p.allocations, claimUID)
}

func (p *PerNodeAllocatedClaims) RemoveUtil(claimUID string) {
	p.Lock() // Lock the entire structure
	defer p.Unlock()

	for node, allocated := range p.allocations[string(claimUID)] {
		if _, exists := p.utilisation[node]; !exists {
			continue // Skip if the node has no utilization data
		}

		util := p.utilisation[node].Cpus

		for _, allocatedCpu := range allocated.RtCpu.Cpuset {
			runtime := allocatedCpu.Runtime
			period := allocatedCpu.Period
			id := strconv.Itoa(allocatedCpu.ID)

			newUtil := util[id].Util - (runtime * 1000 / period)
			if newUtil < 0 {
				newUtil = 0
			}
			util[id] = nascrd.AllocatedUtil{
				Util: newUtil,
			}
		}

		p.utilisation[node] = nascrd.AllocatedUtilset{
			Cpus: util,
		}
	}
}

func (p *PerNodeAllocatedClaims) RemoveUtilOtherNodes(claimUID string, currentNode string) {
	p.Lock() // Lock the entire structure
	defer p.Unlock()

	for node, allocated := range p.allocations[string(claimUID)] {
		if _, exists := p.utilisation[node]; !exists {
			continue // Skip if the node has no utilization data
		}
		if node == currentNode {
			continue
		}

		util := p.utilisation[node].Cpus

		for _, allocatedCpu := range allocated.RtCpu.Cpuset {
			runtime := allocatedCpu.Runtime
			period := allocatedCpu.Period
			id := strconv.Itoa(allocatedCpu.ID)

			newUtil := util[id].Util - (runtime * 1000 / period)
			if newUtil < 0 {
				newUtil = 0
			}
			util[id] = nascrd.AllocatedUtil{
				Util: newUtil,
			}
		}

		p.utilisation[node] = nascrd.AllocatedUtilset{
			Cpus: util,
		}
	}
}

// func (p *PerNodeAllocatedClaims) RemoveCgroup(claimUID string) {
// 	p.Lock()
// 	defer p.Unlock()

// 	for node, allocated := range p.allocations[claimUID] {
// 		cgroupUID := allocated.RtCpu.CgroupUID
// 		delete(p.cgroups[node], cgroupUID)
// 	}

// }
