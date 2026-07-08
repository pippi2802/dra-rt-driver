# RT Resource Driver for Dynamic Resource Allocation (RT-DRA)

This repository contains the resource driver for deploying containers using sched_deadline policy in real-time linux kernel for use with the [Dynamic
Resource Allocation
(DRA)](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)
feature of Kubernetes.

## Quickstart

Before diving into the details of how this example driver is constructed, it's
useful to run through a quick demo of it in action.


### Prerequisites

OS requirements:
* [linux kernel v7.0.0+](https://eur02.safelinks.protection.outlook.com/?url=https%3A%2F%2Fgithub.com%2FYurand2000%2FHCBS-patch%2Ftree%2Frt-cgroups-multi-260514&data=05%7C02%7Cs.brighi%40student.tue.nl%7C35dd77522350446d6dc508decafef25f%7Ccc7df24760ce4a0f9d75704cf60efc64%7C0%7C0%7C639171393504541760%7CUnknown%7CTWFpbGZsb3d8eyJFbXB0eU1hcGkiOnRydWUsIlYiOiIwLjAuMDAwMCIsIlAiOiJXaW4zMiIsIkFOIjoiTWFpbCIsIldUIjoyfQ%3D%3D%7C0%7C%7C%7C&sdata=DtHHZAHqsiiPEYj%2BgqscnEGj8FRRmcJOt64QzNyhxSA%3D&reserved=0)

<!-- * [GNU Make 3.81+](https://www.gnu.org/software/make/)
* [GNU Tar 1.34+](https://www.gnu.org/software/tar/) -->
* [docker v20.10+ (including buildx)](https://docs.docker.com/engine/install/)
* [golang v1.22.5+](https://go.dev/doc/install)
* [helm v3.7.0+](https://helm.sh/docs/intro/install/)
* [kubeadm v1.28+](https://kubernetes.io/docs/reference/setup-tools/kubeadm/)

### Install Kubernetes
To make sure that RT-DRA can be recognised by the Kubernetes and perform correctly, we must install RT-containerd and RT-runc as container runtimes and enable the DRA feature when initiating the Kubernetes cluster. 

For installing the Kubernetes, we follow the steps for a normal installation from [here](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/).
However, we install a custom container runtime (RT-containerd and RT-runc).

To install the RT-containerd, we must clone it's repository, compile, and install it:

```bash
git clone -b rt https://github.com/pippi2802/containerd.git
cd containerd
make
sudo make install
```
create the config file for 

```bash
containerd config default > /etc/containerd/config.toml 
```

containerd requires CNI plugins which can be installed as explained [here](https://github.com/containerd/containerd/blob/main/docs/getting-started.md).

To install the RT-runc, we must clone it's repository, compile, and install it:
```bash
sudo apt install libseccomp-dev
git clone -b rt-v1.1.14 https://github.com/pippi2802/runc.git
cd runc
make
sudo install -D -m0755 runc /usr/local/sbin/runc
```

We prepared a configuration file that enables the DRA feature at cluster initiation. To use the configuation file, we run:
```bash
sudo kubeadn init --config=kubeadm-config.yaml
```
After installing CNI plugin, run the following commands:
```bash
sudo systemctl daemon-reload
sudo systemctl restart containerd
sudo systemctl restart kubelet
```

To join the worker nodes, first we run get the token from the master node by running the following command on the master node:
```bash
kubeadm token create --print-join-command
```
After receiving the token and hash code from the previous command, replae the toke and hash fields in the `worker-config.yaml`. Then to join the worker node run the following command from the worker node:

```bash
sudo kubeadm join --config=worker-config.yaml
```

### Demo
We start by first cloning this repository and `cd`ing into its `demo`
subdirectory. All of the scripts and example Pod specs used in this demo are
contained here, so take a moment to browse through the various files and see
what's available:
```bash
git clone -b rt-v0.1.1 https://github.com/pippi2802/dra-rt-driver.git
cd dra-rt-driver/demo
```

coming up as expected:
```bash
kubectl get pod -A

```

And then install the RT-DRA via `helm`:
```bash
helm upgrade -i \
  --create-namespace \
  --namespace dra-rt-driver \
  --set image.repository=pippina2/dra-rt-driver \
  --set image.tag=v0.1.3 \
  --set image.pullPolicy=Always \
  dra-rt-driver \
  deployments/helm/dra-rt-driver
```

Double check the driver components have come up successfully:
```bash
kubectl get pod -n dra-rt-driver

```

And show the initial state of available GPU devices on the worker node:
```bash
kubectl describe -n dra-rt-driver nas/dra-example-driver-cluster-worker
...
Spec:
  Allocatable Cpuset:
    Rtcpu:
      Id:    2
      Util:  0
    Rtcpu:
      Id:    3
      Util:  0
    Rtcpu:
      Id:    4
      Util:  0
    Rtcpu:
      Id:    0
      Util:  0
    Rtcpu:
      Id:    1
      Util:  0
...
```

Next, deploy four example apps that demonstrate how `ResourceClaim`s,
`ResourceClaimTemplate`s, and custom `ClaimParameter` objects can be used to
request access to resources in various ways:
```bash
kubectl create -f rt-test{1,2,3,4}.yaml
```

And verify that they are coming up successfully:
```bash
kubectl get pod -A
...
```

Use your favorite editor to look through each of the `gpu-test{1,2,3,4}.yaml`
files and see what they are doing. The semantics of each match the figure
below:

![Demo Apps Figure](demo/demo-apps.png?raw=true "Semantics of the applications requesting resources from the example DRA resource driver.")

Then dump the logs of each app to verify that CPUs were allocated to them
according to these semantics:
```bash

```

This should produce output similar to the following:
```bash

```


Likewise, looking at the `ClaimAllocations` section of the
`NodeAllocationState` object on the worker node will show which GPUs have been
allocated to a given `ResourceClaim` by the resource driver:
```bash
kubectl describe -n dra-rt-driver nas/dra-rt-driver-cluster-worker
...
Spec:
  ...
  Prepared Claims:

```

Once you have verified everything is running correctly, delete all of the
example apps:
```bash
kubectl delete --wait=false --f rt-test{1,2,3,4}.yaml
```

Wait for them to terminate:
```bash
kubectl get pod -A

...
```

And show that the `ClaimAllocations` section of the `NodeAllocationState`
object on the worker node is now back to its initial state:
```bash
kubectl describe -n dra-rt-driver nas/dra-example-driver-cluster-worker
...
Spec:
```

## Anatomy of a DRA resource driver

TBD


## References

For more information on the DRA Kubernetes feature and developing custom resource drivers, see the following resources:

* [Dynamic Resource Allocation in Kubernetes](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)


## Building the code 
We start by first cloning this repository and `cd`ing into its `demo`
subdirectory:
```bash
git clone https://github.com/nasim-samimi/dra-rt-driver.git
cd dra-rt-driver/demo
```
We build the image for the example resource driver:
```bash
./build-driver.sh
```
<!-- error with containrd

ls -l /usr/bin/containerd
ls -l /usr/local/bin/containerd

sudo rm -f /usr/bin/containerd  # Remove the existing /usr/bin/containerd binary
sudo ln -s /usr/local/bin/containerd /usr/bin/containerd  # Create a symbolic link -->

### Building with `make`

Alternatively, build and tag the driver image with the Makefile. The Makefile
appends the driver name to `REGISTRY`, so pass only the registry/namespace:

```bash
# REGISTRY=pippina2 + driver name -> pippina2/dra-rt-driver:v0.1.2
make REGISTRY=pippina2 VERSION=v0.1.2 docker-build
docker push pippina2/dra-rt-driver:v0.1.2
```

List the available targets at any time:

```bash
grep -E '^[a-zA-Z0-9_-]+:' Makefile
```

#### Build troubleshooting

* **`make: command not found`** — install it: `sudo apt update && sudo apt install -y make`.
* **`make: *** No rule to make target 'docker-'`** — the target name was split
  by a terminal line-wrap. Type `docker-build` as one unbroken token on a single
  line (the `-build` must stay attached to `docker`).
* **`REGISTRY` value** — use `REGISTRY=pippina2`, not
  `REGISTRY=pippina2/dra-rt-driver`. The Makefile already sets
  `IMAGE_NAME = $(REGISTRY)/$(DRIVER_NAME)`, so passing the full path produces a
  doubled name like `pippina2/dra-rt-driver/dra-rt-driver`.
* **Docker permission denied** — prefer adding your user to the `docker` group
  over running `sudo make`: `sudo usermod -aG docker $USER`, then re-login.

## Real-time (HCBS) cgroup v2 seeding

On a pure cgroup v2 (unified) hierarchy with the systemd cgroup driver, a pod's
leaf cgroup cannot be given a real-time (SCHED_FIFO/RR) budget unless **every**
ancestor slice already has one — the kernel admission test enforces, on every
core, that a child's `rt_runtime` never exceeds its parent's. Stock `runc` on
cgroup v2 never writes any RT budget, so the leaf always ends up with
`cpu.rt_runtime_us = 0`.

To make RT enforcement work, **the driver seeds the whole cgroup chain itself**
during `NodePrepareResources`; `runc` and `containerd` stay stock (no RT patch
required). The chain it seeds is:

```
/sys/fs/cgroup                                       (root)
  kubepods.slice                                     (parent)
    kubepods-besteffort.slice                        (QoS parent)
      kubepods-besteffort-pod<UID>.slice             (pod slice)
        cri-containerd-<containerID>.scope           (leaf)
```

> **Critical prerequisite — turn the RT/DEADLINE admission control OFF.**
> On the HCBS `7.0.0+` kernel the RT-bandwidth admission check
> (`tg_rt_schedulable` / `dl check tg`) **refuses the cgroup-v2 root**
> `cpu.rt_runtime_us` write with `Device or resource busy` (EBUSY) whenever the
> global RT runtime is *finite* — this includes both `sched_rt_runtime_us=950000`
> **and** `sched_rt_runtime_us == sched_rt_period_us`. With the root stuck at `0`,
> the whole chain is un-seedable and every container's RT write fails `EINVAL`
> (kernel log `children bw NNN > parent bw 0`). The fix is to set
> **`kernel.sched_rt_runtime_us = -1`** (RUNTIME_INF), which bypasses the
> admission check; the root/parent slices then accept their scalar budget, and the
> per-cgroup CBS/DEADLINE servers built from `cpu.rt_runtime_us` still throttle
> each group. This is applied by
> [`demo/scripts/99-rt-budget.conf`](demo/scripts/99-rt-budget.conf) and the
> [`rt-budget-seed`](demo/scripts/rt-budget-seed.service) systemd unit, which then
> seeds `root → kubepods → besteffort` with the scalar `950000/1000000` on every
> boot. **Do not** set a finite `sched_rt_runtime_us`, and never offline/online
> CPUs at runtime (isolate at boot instead).

* **Parents** (root, kubepods, besteffort) get a generous scalar reservation
  (`cpu.rt_runtime_us = 950000`, `cpu.rt_period_us = 1000000`) applied to all
  cores, written **top-down (root first)** so each child stays within its parent.
  This requires `sched_rt_runtime_us = -1` (see the callout above).
* **Pod slice and leaf scope(s)** get the exact per-core reservation requested
  by the claim, written in the multi-core form
  `cpu.rt_runtime_us = "<runtime> <cpu> <runtime> <cpu> ..."` (the removed
  `cpu.rt_multi_runtime_us` is no longer used).
* Each level is written in the order **runtime → period → runtime**: a freshly
  created slice starts with `period == 0`, so the first runtime write may be
  rejected with `EINVAL` and is treated as best-effort.
* The pod slice and leaf usually do not exist yet at prepare time (the kubelet
  creates them only when it starts the pod), so the driver defers their seeding
  to a background goroutine that polls for them to appear (default timeout 60s).
  All writes are non-fatal and logged, so a seeding failure never blocks the pod
  from reaching `Running` — it only runs without an RT budget.

### Requirements for seeding to work

* **RT admission control OFF:** `kernel.sched_rt_runtime_us = -1`. This is the
  single most important prerequisite — a finite value makes the root
  `cpu.rt_runtime_us` write fail with EBUSY and the whole chain stays at `0`.
  Confirm with `cat /proc/sys/kernel/sched_rt_runtime_us` (must print `-1`).
* **Kernel:** the RT/HCBS kernel (e.g. `7.0.0+`, or `rt-cgroups-multi-*`) with
  `RT_GROUP_SCHED` and the multi-core HCBS patches. This is what creates the
  `cpu.rt_runtime_us` / `cpu.rt_period_us` files and enforces the admission
  tests. Confirm with `cat /sys/fs/cgroup/cpu.rt_runtime_us`.
* **cgroup driver:** `systemd` (matches the slice/scope path construction).
* **containerd:** stock, with `enable_cdi = true` in
  `/etc/containerd/config.toml`. Confirm with
  `grep -i enable_cdi /etc/containerd/config.toml`.
* **Plugin mount:** the kubelet-plugin DaemonSet mounts the host
  `/sys/fs/cgroup` into the (privileged) plugin container so it can write the RT
  files. This is configured in
  `deployments/helm/dra-rt-driver/templates/kubeletplugin.yaml`.

### Deploy and verify

```bash
# build + push (see "Building with make" above)
make REGISTRY=pippina2 VERSION=v0.1.2 docker-build
docker push pippina2/dra-rt-driver:v0.1.2

# deploy
helm upgrade --install dra-rt-driver deployments/helm/dra-rt-driver \
  --set image.repository=pippina2/dra-rt-driver --set image.tag=v0.1.2
kubectl -n dra-rt-driver rollout restart ds/dra-rt-driver-kubeletplugin

# follow the seeding logs
kubectl -n dra-rt-driver logs ds/dra-rt-driver-kubeletplugin -c plugin | grep hcbs
```

After a test pod is `Running`, verify the leaf actually has an RT budget:

```bash
# nonzero runtime/period on the leaf scope
cat /sys/fs/cgroup/kubepods.slice/kubepods-besteffort.slice/\
kubepods-besteffort-pod<UID>.slice/cri-containerd-<id>.scope/cpu.rt_runtime_us

# the workload can become SCHED_FIFO
chrt -f -p 90 <pid>   # should report SCHED_FIFO
```

> **Note (multi-pod):** the generous scalar at the parents works cleanly for a
> single RT pod. Running multiple concurrent RT pods requires cumulative
> per-core accounting at the besteffort/kubepods slices (the sum of children
> must stay within the parent reservation on each core).