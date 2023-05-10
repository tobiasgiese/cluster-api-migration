# Docker migration

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
    kubectl-->>+Cluster: create paused Cluster
    kubectl-->>+DockerCluster: create DockerCluster
    kubectl-->>+Cluster: unpause Cluster
```

#### Control Plane

```mermaid
%%{init:{"fontFamily":"monospace", "sequence":{"showSequenceNumbers":true}}}%%
sequenceDiagram
    kubectl-->>+KubeadmConfig: create for KCP
    kubectl-->>+KubeadmControlPlane: create paused KCP
    kubectl-->>+Machine: create paused for each control plane node
    kubectl-->>+DockerMachineTemplate: create for each control plane node
    kubectl-->>+KubeadmControlPlane: patch DockerMachineTemplate reference
    kubectl-->>+DockerMachine: create for each control plane node
    kubectl-->>+Machine: patch DockerMachine reference
    kubectl-->>+Machine: unpause Machine
    kubectl-->>+KubeadmControlPlane: unpause KCP
```

#### Worker

```mermaid
%%{init:{"fontFamily":"monospace", "sequence":{"showSequenceNumbers":true}}}%%
sequenceDiagram
    kubectl-->>+KubeadmConfigTemplate: create for MachineDeployment
    kubectl-->>+MachineDeployment: create paused MD
    kubectl-->>+MachineSet: create paused MS
    kubectl-->>+Machine: create paused for each worker node
    kubectl-->>+MachineSet: patch DockerMachineTemplate kind in infrastructure reference
    kubectl-->>+MachineDepoloyment: patch DockerMachineTemplate kind in infrastructure reference
    kubectl-->>+DockerMachineTemplate: create for each worker node
    kubectl-->>+DockerMachine: create for each worker node
    kubectl-->>+Machine: patch DockerMachine reference
    kubectl-->>+Machine: unpause Machine
    kubectl-->>+MachineDeployment: unpause MD
    kubectl-->>+MachineSet: unpause MS
```
