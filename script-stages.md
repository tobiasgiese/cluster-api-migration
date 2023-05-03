1. Prerequisites:
   * Checks for required tools and installs it if not already installed (i.e., `clusterctl`, `kind`, `jq`, `kubectl`).
   * Further, each provider can add prereqs, like env variables for access tokens or the network.
2. Install a [kind](https://github.com/kubernetes-sigs/kind) cluster and deploy CAPI with the given infra provider (default: docker).
3. Initialize a CAPI cluster with `clusterctl generate cluster` and create a backup to have the state.
4. Delete the kind cluster, which stores the CAPI state. We now have an orphaned cluster that could be installed with some different tools as well (e.g., Terraform, Kops, ...).
5. Now the adoption comes into place.
   1. Phase 1 - Cluster:
      * Apply all necessary secrets, like the kubeconfig, CA, etcd cert, and SA (see: https://cluster-api.sigs.k8s.io/tasks/certs/using-custom-certificates.html).
      * Apply the Cluster with the paused annotation.
      * Apply the infra-cluster steps.
        * For the Docker provider as an example:
          * Apply the DockerCluster.
      * Remove the paused annotation from the Cluster.
   2. Phase 2 - Control Plane Nodes:
      * Apply the `kubeadmconfig` that matches your kubeadm configured cluster.
      * Apply the `kubeadmconfigtemplate`.
      * Apply the `KubeadmControlPlane` with the paused annotation.
      * Create a secret dummy that can be used for the Machines (kubectl create secret generic secret-dummy).
      * Create all control plane Machines with the paused annotation.
        * Add the `KubeadmControlPlane` UID to `metadata.ownerReferences[].uid`.
        * The `kubeadmconfig` UID must be added to `spec.bootstrap.configRef.uid`.
        * Add the `secret-dummy` name to `spec.bootstrap.dataSecretName`.
      * Apply the infra-control-plane steps.
        * For the Docker provider as an example:
          * Apply the `dockermachinetemplate`.
          * Apply all `DockerMachines` with the paused annotation.
            * Add the `Machine` UID to `metadata.ownerReferences[].uid`.
          * Patch the Machine with the UID of the `DockerMachine` in `spec.infrastructureRef.uid`.
      * Unpause all `InfraMachines` and `Machines`.
   3. Phase 3 - Worker Nodes:
      * Apply all `KubeadmConfig` that matches your worker machines.
      * Apply all `KubeadmConfigTemplates`.
      * Apply the `MachineDeployment` with the paused annotation.
      * Apply the `MachineSet` with the paused annotation.
        * Add the `MachineDeployment` UID to `metadata.ownerReferences[].uid`.
      * Apply all Machines.
        * Add the `KubeadmControlPlane` UID to `metadata.ownerReferences[].uid`.
        * The `kubeadmconfig` UID must be added to `spec.bootstrap.configRef.uid`.
        * Add the `secret-dummy` name to `spec.bootstrap.dataSecretName`.
      * Apply the infra-worker steps.
        * For the Docker provider as an example:
          * Apply the `dockermachinetemplate`.
          * Apply all `DockerMachines`.
            * Again, you have to add the owner references UID of the Machine.
          * Patch the Machine with the UID of the `DockerMachine` in `spec.infrastructureRef.uid`.
      * Unpause the `MachineSet` and `MachineDeployment`.
6. After a successful adoption, we are ready to create rolling upgrades of the KubeadmControlPlane and MachineDeployment