# Copyright 2022 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

GOLANG_VERSION ?= 1.22.2

DRIVER_NAME := dra-rt-driver
MODULE := github.com/pippi2802/$(DRIVER_NAME)

VERSION  ?= v0.1.0
vVERSION := v$(VERSION:v%=%)

VENDOR := example.com
APIS := rt/nas/v1alpha1 rt/v1alpha1

PLURAL_EXCEPTIONS  = DeviceClassParameters:DeviceClassParameters
PLURAL_EXCEPTIONS += RtClaimParameters:RtClaimParameters

ifeq ($(IMAGE_NAME),)
REGISTRY ?= nasimm
IMAGE_NAME = $(REGISTRY)/$(DRIVER_NAME)
endif
