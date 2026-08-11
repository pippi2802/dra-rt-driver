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
	"context"
	"fmt"
	"strconv"

	corev1 "k8s.io/api/core/v1"
	resourcev1 "k8s.io/api/resource/v1alpha2"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/dynamic-resource-allocation/controller"

	nascrd "github.com/pippi2802/dra-rt-driver/api/example.com/resource/rt/nas/v1alpha1"
	nasclient "github.com/pippi2802/dra-rt-driver/api/example.com/resource/rt/nas/v1alpha1/client"
	rtcrd "github.com/pippi2802/dra-rt-driver/api/example.com/resource/rt/v1alpha1"
	clientset "github.com/pippi2802/dra-rt-driver/pkg/example.com/resource/clientset/versioned"
)

const (
	DriverAPIGroup = rtcrd.GroupName
)

type OnSuccessCallback func()

type driver struct {
	lock      *PerNodeMutex
	namespace string
	clientset clientset.Interface
	rtdriver  *rtdriver
	coreLock  *PerCoreMutex
}

var _ controller.Driver = &driver{}

func NewDriver(config *Config) *driver {
	return &driver{
		lock:      NewPerNodeMutex(),
		namespace: config.namespace,
		clientset: config.clientSets.Example,
		rtdriver:  NewRtDriver(),
		coreLock:  NewPerCoreMutex(),
	}
}

func (d driver) GetClassParameters(ctx context.Context, class *resourcev1.ResourceClass) (interface{}, error) {
	if class.ParametersRef == nil {
		return rtcrd.DefaultDeviceClassParametersSpec(), nil
	}
	if class.ParametersRef.APIGroup != DriverAPIGroup {
		return nil, fmt.Errorf("incorrect API group: %v", class.ParametersRef.APIGroup)
	}
	dc, err := d.clientset.RtV1alpha1().DeviceClassParameters().Get(ctx, class.ParametersRef.Name, metav1.GetOptions{})
	if err != nil {
		return nil, fmt.Errorf("error getting DeviceClassParameters called '%v': %v", class.ParametersRef.Name, err)
	}
	return &dc.Spec, nil
}

func (d driver) GetClaimParameters(ctx context.Context, claim *resourcev1.ResourceClaim, class *resourcev1.ResourceClass, classParameters interface{}) (interface{}, error) {
	if claim.Spec.ParametersRef == nil {
		return rtcrd.DefaultRtClaimParametersSpec(), nil
	}
	if claim.Spec.ParametersRef.APIGroup != DriverAPIGroup {
		return nil, fmt.Errorf("incorrect API group: %v", claim.Spec.ParametersRef.APIGroup)
	}

	switch claim.Spec.ParametersRef.Kind {
	case rtcrd.RtClaimParametersKind:
		gc, err := d.clientset.RtV1alpha1().RtClaimParameters(claim.Namespace).Get(ctx, claim.Spec.ParametersRef.Name, metav1.GetOptions{})
		if err != nil {
			return nil, fmt.Errorf("error getting RtClaimParameters called '%v' in namespace '%v': %v", claim.Spec.ParametersRef.Name, claim.Namespace, err)
		}
		err = d.rtdriver.ValidateClaimParameters(&gc.Spec)
		if err != nil {
			return nil, fmt.Errorf("error validating RtClaimParameters called '%v' in namespace '%v': %v", claim.Spec.ParametersRef.Name, claim.Namespace, err)
		}
		return &gc.Spec, nil
	default:
		return nil, fmt.Errorf("unknown ResourceClaim.ParametersRef.Kind: %v", claim.Spec.ParametersRef.Kind)
	}
}

func (d driver) Allocate(ctx context.Context, cas []*controller.ClaimAllocation, selectedNode string) {
	// In production version of the driver the common operations for every
	// d.allocate looped call should be done prior this loop, and can be reused
	// for every d.allocate() looped call.
	// E.g.: selectedNode=="" check, client stup and CRD fetching.
	for _, ca := range cas {
		ca.Allocation, ca.Error = d.allocate(ctx, ca.Claim, ca.ClaimParameters, ca.Class, ca.ClassParameters, selectedNode)
	}
}

func (d driver) allocate(ctx context.Context, claim *resourcev1.ResourceClaim, claimParameters interface{}, class *resourcev1.ResourceClass, classParameters interface{}, selectedNode string) (*resourcev1.AllocationResult, error) {

	if selectedNode == "" {
		return nil, fmt.Errorf("TODO: immediate allocations is not yet supported")
	}

	d.lock.Get(selectedNode).Lock()
	defer d.lock.Get(selectedNode).Unlock()

	crdconfig := &nascrd.NodeAllocationStateConfig{
		Name:      selectedNode,
		Namespace: d.namespace,
	}
	crd := nascrd.NewNodeAllocationState(crdconfig)

	client := nasclient.New(crd, d.clientset.NasV1alpha1())
	err := client.Get(ctx)
	if err != nil {
		return nil, fmt.Errorf("error retrieving node specific Cpu CRD: %v", err)
	}

	if crd.Status != nascrd.NodeAllocationStateStatusReady {
		return nil, fmt.Errorf("NodeAllocationStateStatus: %v", crd.Status)
	}

	if crd.Spec.AllocatedClaims == nil {
		crd.Spec.AllocatedClaims = make(map[string]nascrd.AllocatedCpuset)
	}

	if crd.Spec.AllocatedUtilToCpu.Cpus == nil {
		utils := make(map[string]nascrd.AllocatedUtil)
		for _, cpu := range crd.Spec.AllocatableCpuset {
			utils[strconv.Itoa(cpu.RtCpu.ID)] = nascrd.AllocatedUtil{
				Util: cpu.RtCpu.Util,
			}
		}
		crd.Spec.AllocatedUtilToCpu = nascrd.AllocatedUtilset{
			Cpus: utils,
		}
	}
	if _, exists := crd.Spec.AllocatedClaims[string(claim.UID)]; exists {
		return buildAllocationResult(selectedNode, true), nil
	}

	var onSuccess OnSuccessCallback
	classParams, _ := classParameters.(*rtcrd.DeviceClassParametersSpec)

	switch claimParams := claimParameters.(type) {
	case *rtcrd.RtClaimParametersSpec:
		onSuccess, err = d.rtdriver.Allocate(crd, claim, claimParams, class, classParams, selectedNode)
	default:
		err = fmt.Errorf("unknown ResourceClaim.ParametersRef.Kind: %v", claim.Spec.ParametersRef.Kind)
	}
	if err != nil {
		return nil, fmt.Errorf("unable to allocate devices on node '%v': %v", selectedNode, err)
	}

	err = client.Update(ctx, &crd.Spec)
	if err != nil {
		return nil, fmt.Errorf("error updating NodeAllocationState CRD: %v", err)
	}

	onSuccess()

	return buildAllocationResult(selectedNode, true), nil
}

func (d driver) Deallocate(ctx context.Context, claim *resourcev1.ResourceClaim) error {
	selectedNode := getSelectedNode(claim)
	if selectedNode == "" {
		return nil
	}
	d.lock.Get(selectedNode).Lock()
	defer d.lock.Get(selectedNode).Unlock()

	crdconfig := &nascrd.NodeAllocationStateConfig{
		Name:      selectedNode,
		Namespace: d.namespace,
	}
	crd := nascrd.NewNodeAllocationState(crdconfig)

	fmt.Println("Before deallocating, crd.Spec.AllocatedClaims:", crd.Spec.AllocatedClaims)
	fmt.Println("Before deallocating, crd.Spec.AllocatedUtilToCpu:", crd.Spec.AllocatedUtilToCpu)

	client := nasclient.New(crd, d.clientset.NasV1alpha1())
	// err := client.Get(ctx)
	// if err != nil {
	// 	return fmt.Errorf("error retrieving node specific Cpu CRD: %v", err)
	// }

	fmt.Println("Before fetch, CRD ResourceVersion:", crd.ResourceVersion)
	err := client.Get(ctx)
	if err != nil {
		return fmt.Errorf("error retrieving node specific Cpu CRD: %v", err)
	}
	fmt.Println("After fetch, CRD ResourceVersion:", crd.ResourceVersion)

	if _, exists := crd.Spec.AllocatedClaims[string(claim.UID)]; !exists {
		fmt.Println("Warning: Claim not found in allocations:", string(claim.UID))
		return nil
	}

	latestCrd := nascrd.NewNodeAllocationState(crdconfig)
	latestClient := nasclient.New(latestCrd, d.clientset.NasV1alpha1())

	// Force fetching latest version
	if latestCrd.ResourceVersion != crd.ResourceVersion {
		err := latestClient.Get(ctx)
		if err != nil {
			return fmt.Errorf("error retrieving latest CRD: %v", err)
		}
		crd = latestCrd // Use latest CRD version
	}

	// Get the list of cores involved in this deallocation
	// coreIDs := []string{}
	// for _, cpuss := range crd.Spec.AllocatedClaims[string(claim.UID)].RtCpu.Cpuset {
	// 	coreIDs = append(coreIDs, strconv.Itoa(cpuss.ID))
	// }
	// if len(coreIDs) == 0 {
	// 	return nil // No cores to lock, return early
	// }

	// Lock all involved cores **before modifying utilization**
	// for _, coreID := range coreIDs {
	// 	d.coreLock.Get(coreID).Lock()
	// }
	// defer func() {
	// 	// Unlock cores after processing
	// 	for _, coreID := range coreIDs {
	// 		d.coreLock.Get(coreID).Unlock()
	// 	}
	// }()

	devices := crd.Spec.AllocatedClaims[string(claim.UID)]
	switch devices.Type() {
	case nascrd.RtCpuType:
		err = d.rtdriver.Deallocate(crd, claim, selectedNode)
	default:
		err = fmt.Errorf("unknown AllocatedDevices.Type(): %v", devices.Type())
	}
	if err != nil {
		return fmt.Errorf("unable to deallocate devices '%v': %v", devices, err)
	}

	if crd.Spec.AllocatedUtilToCpu.Cpus == nil {
		crd.Spec.AllocatedUtilToCpu.Cpus = make(map[string]nascrd.AllocatedUtil)
	}

	for _, cpuss := range devices.RtCpu.Cpuset {
		runtime := cpuss.Runtime
		period := cpuss.Period
		id := strconv.Itoa(cpuss.ID)

		if utilEntry, exists := crd.Spec.AllocatedUtilToCpu.Cpus[id]; exists {
			newUtil := utilEntry.Util - ((runtime * 1000) / period)
			if newUtil < 0 {
				newUtil = 0
			}
			crd.Spec.AllocatedUtilToCpu.Cpus[id] = nascrd.AllocatedUtil{
				Util: newUtil,
			}
		} else {
			fmt.Println("Warning: CPU Utilization entry missing for core:", id)
		}
	}

	delete(crd.Spec.AllocatedClaims, string(claim.UID))

	err = client.Update(ctx, &crd.Spec)
	if err != nil {
		fmt.Println("Error updating CRD:", err)
		return fmt.Errorf("error updating NodeAllocationState CRD: %v", err)
	}
	fmt.Println("After Update, crd.Spec.AllocatedClaims:", crd.Spec.AllocatedClaims)
	fmt.Println("After Update, crd.Spec.AllocatedUtilToCpu:", crd.Spec.AllocatedUtilToCpu)

	return nil
}

func (d driver) UnsuitableNodes(ctx context.Context, pod *corev1.Pod, cas []*controller.ClaimAllocation, potentialNodes []string) error {
	for _, node := range potentialNodes {
		err := d.unsuitableNode(ctx, pod, cas, node)
		if err != nil {
			return fmt.Errorf("error processing node '%v': %v", node, err)
		}
	}

	for _, ca := range cas {
		ca.UnsuitableNodes = unique(ca.UnsuitableNodes)
	}

	return nil
}

func (d driver) unsuitableNode(ctx context.Context, pod *corev1.Pod, allcas []*controller.ClaimAllocation, potentialNode string) error {
	d.lock.Get(potentialNode).Lock()
	defer d.lock.Get(potentialNode).Unlock()

	crdconfig := &nascrd.NodeAllocationStateConfig{
		Name:      potentialNode,
		Namespace: d.namespace,
	}
	crd := nascrd.NewNodeAllocationState(crdconfig)

	client := nasclient.New(crd, d.clientset.NasV1alpha1())
	err := client.Get(ctx)
	if err != nil {
		for _, ca := range allcas {
			ca.UnsuitableNodes = append(ca.UnsuitableNodes, potentialNode)
		}
		return nil
	}

	if crd.Status != nascrd.NodeAllocationStateStatusReady {
		for _, ca := range allcas {
			ca.UnsuitableNodes = append(ca.UnsuitableNodes, potentialNode)
		}
		return nil
	}

	if crd.Spec.AllocatedClaims == nil {
		crd.Spec.AllocatedClaims = make(map[string]nascrd.AllocatedCpuset)
	}

	if crd.Spec.AllocatedUtilToCpu.Cpus == nil {
		utils := make(nascrd.MappedUtil)
		for _, cpu := range crd.Spec.AllocatableCpuset {
			utils[strconv.Itoa(cpu.RtCpu.ID)] = nascrd.AllocatedUtil{
				Util: cpu.RtCpu.Util,
			}
		}
		crd.Spec.AllocatedUtilToCpu = nascrd.AllocatedUtilset{
			Cpus: utils,
		}
	}

	perKindCas := make(map[string][]*controller.ClaimAllocation)
	for _, ca := range allcas {
		switch ca.ClaimParameters.(type) {
		case *rtcrd.RtClaimParametersSpec:
			perKindCas[rtcrd.RtClaimParametersKind] = append(perKindCas[rtcrd.RtClaimParametersKind], ca)
		default:
			return fmt.Errorf("unknown ResourceClaimParameters kind: %T", ca.ClaimParameters)
		}
	}
	for _, kind := range []string{rtcrd.RtClaimParametersKind} {
		var err error
		switch kind {
		case rtcrd.RtClaimParametersKind:
			err = d.rtdriver.UnsuitableNode(crd, pod, perKindCas[kind], allcas, potentialNode)
		default:
			err = fmt.Errorf("unknown ResourceClaimParameters kind: %+v", kind)
		}
		if err != nil {
			return fmt.Errorf("error processing '%v': %v", kind, err)
		}
	}

	return nil
}

func buildAllocationResult(selectedNode string, shareable bool) *resourcev1.AllocationResult {
	nodeSelector := &corev1.NodeSelector{
		NodeSelectorTerms: []corev1.NodeSelectorTerm{
			{
				MatchFields: []corev1.NodeSelectorRequirement{
					{
						Key:      "metadata.name",
						Operator: "In",
						Values:   []string{selectedNode},
					},
				},
			},
		},
	}
	allocation := &resourcev1.AllocationResult{
		AvailableOnNodes: nodeSelector,
		Shareable:        shareable,
	}
	return allocation
}

func getSelectedNode(claim *resourcev1.ResourceClaim) string {
	if claim.Status.Allocation == nil {
		return ""
	}
	if claim.Status.Allocation.AvailableOnNodes == nil {
		return ""
	}
	return claim.Status.Allocation.AvailableOnNodes.NodeSelectorTerms[0].MatchFields[0].Values[0]
}

func unique(s []string) []string {
	set := make(map[string]struct{})
	var news []string
	for _, str := range s {
		if _, exists := set[str]; !exists {
			set[str] = struct{}{}
			news = append(news, str)
		}
	}
	return news
}
