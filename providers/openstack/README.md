# OpenStack migration

There are some manual steps that must be done during the test of the OpenStack provider.

* Of course an OpenStack Cloud is needed
  * You can use [the local devstack scripts of the CAPO provider](https://github.com/kubernetes-sigs/cluster-api-provider-openstack/pull/1539) which has been used for the tests.
* A SSH key (see env `OPENSTACK_SSH_KEY_NAME` in the [prereqs.sh](prereqs.sh)) must be created in the OpenStack cloud.
* After the first control plane has been provisioned the [OpenStack Cloud Controller Manager](https://github.com/kubernetes/cloud-provider-openstack/tree/master/charts/openstack-cloud-controller-manager) must be deployed (This could be automated as well).

## Overview
![](migration.png)

### Phases

#### Cluster

```mermaid
%%{init:{"fontFamily":"monospace", "sequence":{"showSequenceNumbers":true}}}%%
sequenceDiagram
    kubectl-->>+Secrets: create kubeconfig
    kubectl-->>+Secrets: create etcd
    kubectl-->>+Secrets: create CA
    kubectl-->>+Secrets: create SA
    kubectl-->>+Secrets: create cloud-config
    kubectl-->>+Cluster: create paused cluster-name
    kubectl-->>+OpenStackCluster: create cluster-name
    kubectl-->>+Cluster: unpause cluster-name
```

#### Control Plane

```mermaid
%%{init:{"fontFamily":"monospace", "sequence":{"showSequenceNumbers":true}}}%%
sequenceDiagram
    kubectl-->>+KubeadmConfig: create for KubeadmControlPlane
    kubectl-->>+KubeadmControlPlane: create paused kcp-name
    kubectl-->>+Machine: create for each control plane node
    kubectl-->>+OpenStackMachineTemplate: create for each control plane node
    kubectl-->>+KubeadmControlPlane: patch OpenStackMachineTemplate reference
    kubectl-->>+OpenStackMachine: create for each control plane node
    kubectl-->>+Machine: patch OpenStackMachine reference
    kubectl-->>+KubeadmControlPlane: unpause kcp-name
```

#### Worker

```mermaid
%%{init:{"fontFamily":"monospace", "sequence":{"showSequenceNumbers":true}}}%%
sequenceDiagram
    kubectl-->>+KubeadmConfigTemplate: create for MachineDeployment
    kubectl-->>+MachineDeployment: create paused md-name
    kubectl-->>+MachineSet: create paused ms-name
    kubectl-->>+Machine: create for each worker node
    kubectl-->>+MachineSet: patch DockerMachineTemplate kind in infrastructure reference
    kubectl-->>+MachineDepoloyment: patch DockerMachineTemplate kind in infrastructure reference
    kubectl-->>+OpenStackMachineTemplate: create for each worker node
    kubectl-->>+OpenStackMachine: create for each worker node
    kubectl-->>+Machine: patch OpenStackMachine reference
    kubectl-->>+MachineDeployment: unpause md-name
    kubectl-->>+MachineSet: unpause ms-name
```