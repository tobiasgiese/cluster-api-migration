# Adopting Kubernetes clusters into CAPI management

This repository is a proof of concept that demonstrates how to adopt Kubernetes clusters into the [Cluster API](https://cluster-api.sigs.k8s.io/) (CAPI) management, which is not originally managed by CAPI.  

**⚠️ It is highly experimental and should only be used for educational or research purposes.**

The approach is about the following talk from the KubeCon + CloudNativeCon 2022 in Valencia:  
[How to Migrate 700 Kubernetes Clusters to Cluster API with Zero Downtime](https://kccnceu2022.sched.com/event/yttp/)

## Prerequisites

The following tools are required before running the script:

* [jq](https://github.com/stedolan/jq)
* kubectl

All other prerequisites will be automatically downloaded by the script.

## Usage

You can simply run the script locally. Depending on how good the client resources are the script takes about 5-10 minutes.

```
./cluster-api-migration
```

> Note: currently only the `docker` (CAPD) provider is supported. In future more providers may be added.

After a successful run the generated manifests are stored in `providers/<chosen provider>/output/`

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
