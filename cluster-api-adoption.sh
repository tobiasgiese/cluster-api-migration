#!/bin/bash

set -euo pipefail

CAPI_VERSION=v1.4.1
KIND_VERSION=v0.18.0
CALICO_VERSION=v3.24.1
TMP_PATH=/tmp/capi-adoption
TMP_BIN_PATH=$TMP_PATH/bin
PATH=$TMP_BIN_PATH/:$PATH

wait_for() {
    echo -n "🐢 Waiting for $1"
    until eval "$2" &> /dev/null; do
        printf .
        sleep 1
    done
    echo
}

add_paused_annotation() {
    jq '.metadata.annotations["cluster.x-k8s.io/paused"] = "true"'
}

remove_unneccessary_fields() {
    jq 'del(
        .status,
        .spec.topology,
        .metadata.resourceVersion,
        .metadata.uid,
        .metadata.finalizers,
        .metadata.generation,
        .metadata.creationTimestamp,
        .metadata.labels["topology.cluster.x-k8s.io/owned"],
        .metadata.labels["topology.cluster.x-k8s.io/deployment-name"],
        .spec.machineTemplate.metadata.labels["topology.cluster.x-k8s.io/owned"],
        .spec.machineTemplate.metadata.labels["topology.cluster.x-k8s.io/deployment-name"],
        .spec.template.metadata.labels["topology.cluster.x-k8s.io/owned"],
        .spec.template.metadata.labels["topology.cluster.x-k8s.io/deployment-name"],
        .spec.selector.matchLabels["topology.cluster.x-k8s.io/owned"],
        .spec.selector.matchLabels["topology.cluster.x-k8s.io/deployment-name"]
    )'
}

remove_owner_reference() {
    jq 'del(.metadata.ownerReferences)'
}

get_uid() {
    kubectl get "$1" "$2" -ojsonpath='{.metadata.uid}'
}

add_cluster_owner_reference() {
    jq ".metadata.ownerReferences[].uid = \"$(get_uid cluster capi-quickstart)\""
}

prereqs() {
    if [[ "$OSTYPE" != "linux-gnu"* ]]; then
        echo "⚠️ This script is optimized for Linux. It may not run correctly under $OSTYPE."
    fi

    if ! command -v docker > /dev/null; then
        echo "❗ Docker not found - please install docker on your client first!"
        echo "❗ See https://docs.docker.com/engine/install/"
        exit 1
    fi

    mkdir -p "$TMP_BIN_PATH"
    mkdir -p $TMP_PATH/workload-backup

    clusterctl_location="$TMP_BIN_PATH/clusterctl"
    if [[ ! -f "${clusterctl_location}" ]]; then
        wget -qO "${clusterctl_location}" https://github.com/kubernetes-sigs/cluster-api/releases/download/${CAPI_VERSION}/clusterctl-linux-amd64
        chmod +x "${clusterctl_location}"
    fi

    kind_location="$TMP_BIN_PATH/kind"
    if [[ ! -f "${kind_location}" ]]; then
        wget -qO "${kind_location}" https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-linux-amd64
        chmod +x "${kind_location}"
    fi

    # Ensure jq and kubectl binaries if not found. It's not necessary to have a specific version.
    if ! command -v jq > /dev/null; then
        wget -qO "$TMP_BIN_PATH/jq" https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64
    fi
    if ! command -v kubectl > /dev/null; then
        k8sVersion=$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)
        wget -qO "$TMP_BIN_PATH/kubectl" "https://storage.googleapis.com/kubernetes-release/release/${k8sVersion}/bin/linux/amd64/kubectl"
    fi
}

purge_and_init_mgmt_cluster() {
    # Delete cluster first.
    kind delete cluster --name capi-test

    # Init CAPD cluster.
    curl -s https://raw.githubusercontent.com/kubernetes-sigs/cluster-api/$CAPI_VERSION/hack/kind-install-for-capd.sh | bash

    # Enable the experimental Cluster topology feature.
    export CLUSTER_TOPOLOGY=true

    clusterctl init --infrastructure docker
    kubectl -n capd-system rollout status deploy capd-controller-manager
    kubectl -n capi-system rollout status deploy capi-controller-manager
    kubectl -n capi-kubeadm-bootstrap-system rollout status deploy capi-kubeadm-bootstrap-controller-manager
    kubectl -n capi-kubeadm-control-plane-system rollout status deploy capi-kubeadm-control-plane-controller-manager
}

init_workload_cluster() {
    # Delete workload cluster if it exists.
    kind delete cluster --name capi-quickstart
    # And create a new workload cluster.
    clusterctl generate cluster capi-quickstart --flavor development \
        --kubernetes-version v1.27.0 \
        --control-plane-machine-count=1 \
        --worker-machine-count=3 | kubectl apply -f -
    wait_for "kubeconfig to be created" "kubectl get secret capi-quickstart-kubeconfig"

    # Deploy CNI to have a ready KCP.
    kubectl get secret capi-quickstart-kubeconfig -ojson | jq -r .data.value | base64 -d > $TMP_PATH/kubeconfig-workloadcluster
    # Preload CNI images to not hit the docker rate limit.
    docker pull -q docker.io/calico/cni:$CALICO_VERSION
    docker pull -q docker.io/calico/node:$CALICO_VERSION
    docker pull -q docker.io/calico/kube-controllers:$CALICO_VERSION
    wait_for "kube-apiserver to be reachable to deploy CNI" "timeout 1 kubectl --kubeconfig=$TMP_PATH/kubeconfig-workloadcluster get nodes"
    # Wait until all workload machines have a docker provider ID. This ensures that the nodes have been created and we can preload the images.
    wait_for "all Machines to be provisioned" "kubectl get machine -ojson | jq -e 'select(([select(.items[].spec.providerID != null)] | length) == (.items | length)) | true'"
    kind load docker-image --name capi-quickstart docker.io/calico/cni:$CALICO_VERSION docker.io/calico/node:$CALICO_VERSION docker.io/calico/kube-controllers:$CALICO_VERSION
    kubectl --kubeconfig=$TMP_PATH/kubeconfig-workloadcluster apply -f https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/calico.yaml

    wait_for "KubeadmControlPlane to be ready" "kubectl get kcp -ojson | jq -e '.items[].status | select(.replicas == .readyReplicas and .readyReplicas == .updatedReplicas and .unavailableReplicas == 0)'"
    wait_for "MachineDeployment to be ready" "kubectl get md -ojson | jq -e '.items[].status | select(.replicas == .readyReplicas and .readyReplicas == .updatedReplicas and .unavailableReplicas == 0)'"

    rm -f $TMP_PATH/workload-backup/*
    echo "🐢 Creating backup for..."
    kubectl get "secret,$(kubectl api-resources -oname | grep cluster.x-k8s.io | cut -d. -f1 | xargs | sed 's/ /,/g')" -oname \
        | while IFS=/ read -r kind name; do
            echo "  $kind/$name"
            # ${kind/.*} removes everything after the first dot.
            kubectl get "$kind" "$name" -ojson > "$TMP_PATH/workload-backup/${kind/.*/}_${name}.json"
        done
}

adoption_phase_cluster() {
    echo
    echo "🐢 We have an orphaned workload cluster now. Let's try to adopt it 🥳️"
    echo "🐢 Phase 1 - Adopting the Cluster Infrastructure."
    echo

    # Apply necessary secrets.
    for secret in kubeconfig ca etcd sa; do
        remove_unneccessary_fields < "secret_capi-quickstart-${secret}.json" \
            | remove_owner_reference \
            | kubectl apply -f -
    done

    # Apply paused Cluster.
    jq 'del(.spec.controlPlaneRef)' cluster_capi-quickstart.json \
        | remove_unneccessary_fields \
        | add_paused_annotation \
        | kubectl apply -f -

    # Apply DockerCluster
    add_cluster_owner_reference < dockercluster_* \
        | remove_unneccessary_fields \
        | kubectl apply -f -

    kubectl annotate cluster capi-quickstart cluster.x-k8s.io/paused-
}

adoption_phase_control_plane() {
    echo
    echo "🐢 Phase 2 - Adopting the Control Planes."
    echo

    # Apply control plane kubeadmConfigs.
    for kubeadmConfig in kubeadmconfig_*; do
        if [[ "$kubeadmConfig" == *"-md-"* ]]; then
            continue
        fi
        remove_unneccessary_fields < "$kubeadmConfig" \
            | remove_owner_reference \
            | kubectl apply -f -
    done

    # Apply control plane DockerMachineTemplates.
    for dockerMachineTemplate in dockermachinetemplate_*; do
        if [[ "$dockerMachineTemplate" == *"-md-"* ]]; then
            continue
        fi
        add_cluster_owner_reference < "$dockerMachineTemplate" \
            | remove_unneccessary_fields \
            | kubectl apply -f -
    done

    # Apply control plane KubeadmConfigTemplates.
    for kubeadmConfigTemplate in kubeadmconfigtemplate_*; do
        if [[ "$kubeadmConfigTemplate" == *"-md-"* ]]; then
            continue
        fi
        add_cluster_owner_reference < "$kubeadmConfigTemplate" \
            | remove_unneccessary_fields \
            | kubectl apply -f -
    done

    # Apply paused KubeadmControlPlane.
    jq 'del(.metadata.annotations["cluster.x-k8s.io/cloned-from-groupkind"], .metadata.annotations["cluster.x-k8s.io/cloned-from-name"])' kubeadmcontrolplane_* \
        | add_cluster_owner_reference \
        | remove_unneccessary_fields \
        | add_paused_annotation \
        | kubectl apply -f -
    sleep 1
    kubeadmControlPlaneName=$(jq -r '.metadata.name' kubeadmcontrolplane_*)
    kubeadmControlPlaneUID=$(get_uid kubeadmcontrolplane "$kubeadmControlPlaneName")

    # Create secret-dummy. This secret is needed during node bootstrap and includes the cloud-init data.
    kubectl create secret generic secret-dummy

    # Apply paused control plane Machines.
    for machine in machine_*; do
        if [[ "$machine" == *"-md-"* ]]; then
            continue
        fi
        kubeadmConfigName=$(jq -r '.spec.bootstrap.configRef.name' "${machine}")
        kubeadmConfigUID=$(kubectl get kubeadmconfig "$kubeadmConfigName" -ojsonpath='{.metadata.uid}')
        jq ".metadata.ownerReferences[].uid = \"$kubeadmControlPlaneUID\"" "$machine" \
            | jq '.spec.bootstrap.configRef.uid = "'"$kubeadmConfigUID"'"' \
            | jq '.spec.bootstrap.dataSecretName = "secret-dummy"' \
            | remove_unneccessary_fields \
            | add_paused_annotation \
            | kubectl apply -f -
    done

    # Apply control plane DockerMachines and unpause Machine and DockerMachine.
    for dockerMachine in dockermachine_*; do
        if [[ "$dockerMachine" == *"-md-"* ]]; then
            continue
        fi
        machineName=$(jq -r '.metadata.ownerReferences[].name' "$dockerMachine")
        machineUID=$(get_uid machine "$machineName")
        # Apply DockerMachine.
        jq ".metadata.ownerReferences[].uid = \"$machineUID\"" "$dockerMachine" \
            | remove_unneccessary_fields \
            | add_paused_annotation \
            | kubectl apply -f -
        sleep 1
        dockerMachineName=$(jq -r '.metadata.name' "$dockerMachine")
        dockerMachineUID=$(get_uid dockermachine "$dockerMachineName")

        # Patch DockerMachine UID in Machine.
        kubectl patch machine "$machineName" --type='json' -p='[{"op": "replace", "path": "/spec/infrastructureRef/uid", "value":"'"$dockerMachineUID"'"}]'
        kubectl annotate machine "$machineName" cluster.x-k8s.io/paused-
        kubectl annotate dockermachine "$dockerMachineName" cluster.x-k8s.io/paused-
    done

    # Unpause KubeadmControlPlane.
    kubectl annotate kubeadmcontrolplane "$kubeadmControlPlaneName" cluster.x-k8s.io/paused-
}

adoption_phase_worker() {
    echo
    echo "🐢 Phase 3 - Adopting the MachineDeployment."
    echo

    # Apply worker kubeadmConfigs.
    for kubeadmConfig in kubeadmconfig_*-md-*; do
        remove_unneccessary_fields < "$kubeadmConfig" \
            | remove_owner_reference \
            | kubectl apply -f -
    done

    # Apply worker DockerMachineTemplates.
    for dockerMachineTemplate in dockermachinetemplate_*-md-*; do
        add_cluster_owner_reference < "$dockerMachineTemplate" \
            | remove_unneccessary_fields \
            | kubectl apply -f -
    done

    # Apply worker KubeadmConfigTemplates.
    for kubeadmConfigTemplate in kubeadmconfigtemplate_*-md-*; do
        add_cluster_owner_reference < "$kubeadmConfigTemplate" \
            | remove_unneccessary_fields \
            | kubectl apply -f -
    done

    # Apply paused MachineDeployment.
    for machineDeployment in machinedeployment_*; do
        add_cluster_owner_reference < "$machineDeployment" \
            | remove_unneccessary_fields \
            | add_paused_annotation \
            | kubectl apply -f -
    done
    sleep 1
    machineDeploymentName=$(jq -r '.metadata.name' machinedeployment_*)
    machineDeploymentUID=$(get_uid machinedeployment "$machineDeploymentName")

    # Apply Machineset.
    for machineSet in machineset_*; do
        jq ".metadata.ownerReferences[].uid = \"$machineDeploymentUID\"" "$machineSet" \
            | remove_unneccessary_fields \
            | add_paused_annotation \
            | kubectl apply -f -
    done
    sleep 1
    machineSetName=$(jq -r '.metadata.name' machineset_*)
    machineSetUID=$(get_uid machineset "$machineSetName")

    # Apply paused worker Machines.
    for machine in machine_*-md-*; do
        jq ".metadata.ownerReferences[].uid = \"$machineSetUID\"" "$machine" \
            | jq '.spec.bootstrap.dataSecretName = "secret-dummy"' \
            | remove_unneccessary_fields \
            | kubectl apply -f -
    done

    # Apply paused worker DockerMachines.
    for dockerMachine in dockermachine_*-md-*; do
        machineName=$(jq -r '.metadata.ownerReferences[].name' "$dockerMachine")
        machineUID=$(get_uid machine "$machineName")
        # Apply DockerMachine.
        jq ".metadata.ownerReferences[].uid = \"$machineUID\"" "$dockerMachine" \
            | remove_unneccessary_fields \
            | kubectl apply -f -
        sleep 1
        dockerMachineName=$(jq -r '.metadata.name' "$dockerMachine")
        dockerMachineUID=$(get_uid dockermachine "$dockerMachineName")

        # Patch DockerMachine UID in Machine.
        kubectl patch machine "$machineName" --type='json' -p='[{"op": "replace", "path": "/spec/infrastructureRef/uid", "value":"'"$dockerMachineUID"'"}]'
    done

    # Unpause MachineDeployment and MachineSet.
    kubectl annotate machinedeployment "$machineDeploymentName" cluster.x-k8s.io/paused-
    kubectl annotate machineset "$machineSetName" cluster.x-k8s.io/paused-

    echo
    echo "🐢 Done! The orphaned cluster has been successfully migraed into Cluster API - wihtout any replacement of the nodes!"
    echo
}

rolling_upgrade_control_plane() {
    echo
    echo "🐢 Starting rolling upgrade for the control plane nodes."
    echo
    clusterctl alpha rollout restart "kubeadmcontrolplane/$(kubectl get kcp -ojson | jq -r '.items[].metadata.name')"
    # Wait a few seconds to let the rolling upgrade begin.
    sleep 5
    wait_for "KubeadmControlPlane to be ready" "kubectl get kcp -ojson | jq -e '.items[].status | select(.replicas == .readyReplicas and .readyReplicas == .updatedReplicas and .unavailableReplicas == 0)'"
}

rolling_upgrade_worker() {
    echo
    echo "🐢 Starting rolling upgrade for the worker nodes."
    echo
    clusterctl alpha rollout restart "machinedeployment/$(kubectl get md -ojson | jq -r '.items[].metadata.name')"
    # Wait a few seconds to let the rolling upgrade begin.
    sleep 5
    wait_for "MachineDeployment to be ready" "kubectl get md -ojson | jq -e '.items[].status | select(.replicas == .readyReplicas and .readyReplicas == .updatedReplicas and .unavailableReplicas == 0)'"
}

prereqs
pushd $TMP_PATH/workload-backup/ > /dev/null

case "${1:-""}" in
"purge_and_init_mgmt_cluster")
    purge_and_init_mgmt_cluster
    ;;
"init_workload_cluster")
    init_workload_cluster
    ;;
"adoption_phase_cluster")
    adoption_phase_cluster
    ;;
"adoption_phase_control_plane")
    adoption_phase_control_plane
    ;;
"adoption_phase_worker")
    adoption_phase_worker
    ;;
"rolling_upgrade_control_plane")
    rolling_upgrade_control_plane
    ;;
"rolling_upgrade_worker")
    rolling_upgrade_worker
    ;;
*)
    purge_and_init_mgmt_cluster
    init_workload_cluster
    purge_and_init_mgmt_cluster
    adoption_phase_cluster
    adoption_phase_control_plane
    adoption_phase_worker
    rolling_upgrade_control_plane
    rolling_upgrade_worker
    ;;
esac

pushd $TMP_PATH/workload-backup/ > /dev/null

kubectl get cluster,dockercluster,kcp,md,ma,dockermachine

popd > /dev/null
