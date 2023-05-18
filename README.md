# Migrating Kubernetes clusters into CAPI

**⚠️ It is highly experimental and should only be used for educational or research purposes! ⚠️**

This repository is a proof of concept that demonstrates how to adopt Kubernetes clusters into the [Cluster API](https://cluster-api.sigs.k8s.io/) (CAPI) management, which is not originally managed by CAPI.  

This approach is about the following talk from the KubeCon + CloudNativeCon 2022 in Valencia:  
[How to Migrate 700 Kubernetes Clusters to Cluster API with Zero Downtime](https://kccnceu2022.sched.com/event/yttp/)

To test the migration a unmanaged cluster is necessary. To achieve this in a scripted solution we can easily use the [CAPI Quick Start](https://cluster-api.sigs.k8s.io/user/quick-start.html) - which deploys a workload cluster - and delete the CAPI management cluster afterwards. This ensures that no state is present of the workload cluster.

Disclaimer: If you want to test this with your own clusters keep in mind that each provider has different requirements. Some rely on the resource names (e.g., CAPO), others use IDs (e.g., CAPA) to identify resources.

## Prerequisites

The following tools are required but will be downloaded to the tmp directory if not found.

* [jq](https://github.com/stedolan/jq)
* [yq](https://github.com/mikefarah/yq)
* kubectl
* curl (will not be downloaded automatically)

## Usage

You can simply run the script locally. Depending on how good the client resources are the script takes about 5-10 minutes.

```
Usage: ./cluster-api-migration.sh [<provider> <command>]
Description: This script performs various operations. Leave empty if you want to run them all.
             If you do not define any command, all stages will be performed.

Example: ./cluster-api-migration.sh docker purge_and_init_mgmt_cluster

Providers:
    docker (default)
    openstack

Commands:
    purge_and_init_mgmt_cluster    Purge and initialize the management cluster.
    kustomize_workload_manifest    Create the workload cluster manifest using kustomize.
    init_workload_cluster          Initialize a new workload cluster.
    migration_phase_cluster        Perform the migration phase on a cluster.
    migration_phase_control_plane  Perform the migration phase on the control plane nodes of a cluster.
    migration_phase_worker         Perform the migration phase on the worker nodes of a cluster.
    rolling_upgrade_control_plane  Perform a rolling upgrade of the control plane of a cluster.
    rolling_upgrade_worker         Perform a rolling upgrade of the worker nodes of a cluster.
```

### Script Stages

The script has the following stages:

* install prereqs
* deploy a kind CAPI management cluster
* install a workload cluster with CAPI
* create a backup of all CAPI resources of the workload cluster
* purge and redeploy the CAPI management
    * the state is now gone
* start the migration to adopt the orphaned cluster
    * phase 1: Cluster infrastructure
    * phase 2: KubeadmControlPlane
    * phase 3: MachineDeployment
* verify the migration with a rolling upgrade

## Acknowledgements

I would like to thank the following people:

- Stefan Büringer ([@sbueringer](https://github.com/sbueringer)) for the initial idea of migrating unmanaged clusters to Cluster API.
- Christian Schlotter ([@chrischdi](https://github.com/chrischdi)) for helping with the implementation of the migration.
- And last but not least the complete Kubernetes platform team at [@mercedes-benz](https://github.com/mercedes-benz).
