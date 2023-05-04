#!/bin/bash
# shellcheck disable=SC1090

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

CAPI_VERSION=v1.4.2
KIND_VERSION=v0.18.0
CALICO_VERSION=v3.24.1
TMP_PATH=/tmp/capi-migration
TMP_BIN_PATH=$TMP_PATH/bin
PATH=$TMP_BIN_PATH/:$PATH

PROVIDER=${1:-"docker"}
COMMAND=${2-""}

if [[ ! -d "providers/${PROVIDER}" ]]; then
	echo "Provider not found: $PROVIDER"
	exit 1
fi

usage() {
	echo "Usage: $0 [provider command]"
	echo "Description: This script performs various operations. Leave empty if you want to run them all."
	echo
	echo "Example: $0 docker purge_and_init_mgmt_cluster"
	echo
	echo "Commands:"
	echo "  purge_and_init_mgmt_cluster    Purge and initialize the management cluster."
	echo "  init_workload_cluster          Initialize a new workload cluster."
	echo "  migration_phase_cluster         Perform the migration phase on a cluster."
	echo "  migration_phase_control_plane   Perform the migration phase on the control plane nodes of a cluster."
	echo "  migration_phase_worker          Perform the migration phase on the worker nodes of a cluster."
	echo "  rolling_upgrade_control_plane  Perform a rolling upgrade of the control plane of a cluster."
	echo "  rolling_upgrade_worker         Perform a rolling upgrade of the worker nodes of a cluster."
	echo
}

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

kcp_or_md_ready() {
	jq -e '.items[].status | select(.replicas == .readyReplicas and .readyReplicas == .updatedReplicas and (.unavailableReplicas == 0 or .unavailableReplicas == null)) | true'
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

	# Source the infra specific prereqs and migration functions.
	source "${SCRIPT_DIR}/providers/${PROVIDER}/prereqs.sh"
	source "${SCRIPT_DIR}/providers/${PROVIDER}/migration.sh"
	infra_prereqs
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

	wait_for "KubeadmControlPlane to be ready" "kubectl get kcp -ojson | kcp_or_md_ready"
	wait_for "MachineDeployment to be ready" "kubectl get md -ojson | kcp_or_md_ready"

	rm -f $TMP_PATH/workload-backup/*
	rm -f $SCRIPT_DIR/providers/$PROVIDER/output/*
	echo "🐢 Creating backup for..."
	kubectl get "secret,$(kubectl api-resources -oname | grep cluster.x-k8s.io | cut -d. -f1 | xargs | sed 's/ /,/g')" -oname \
		| while IFS=/ read -r kind name; do
			echo "  $kind/$name"
			# ${kind/.*} removes everything after the first dot.
			kubectl get "$kind" "$name" -ojson > "$TMP_PATH/workload-backup/${kind/.*/}_${name}.json"
		done
}

migration_phase_cluster() {
	echo "🐢 We have an orphaned workload cluster now. Let's try to adopt it 🥳️"
	echo "🐢 Phase 1 - Adopting the Cluster Infrastructure."

	# Apply necessary secrets.
	for secret in kubeconfig ca etcd sa; do
		remove_unneccessary_fields < "secret_capi-quickstart-${secret}.json" \
			| remove_owner_reference \
			| tee "${SCRIPT_DIR}/providers/${PROVIDER}/output/secret_capi-quickstart-${secret}.json" \
			| kubectl apply -f -
	done

	# Apply paused Cluster.
	jq 'del(.spec.controlPlaneRef)' cluster_capi-quickstart.json \
		| remove_unneccessary_fields \
		| add_paused_annotation \
		| tee "${SCRIPT_DIR}/providers/${PROVIDER}/output/cluster_capi-quickstart.json" \
		| kubectl apply -f -

	infra_cluster_migration

	kubectl annotate cluster capi-quickstart cluster.x-k8s.io/paused-
	clusterctl describe cluster capi-quickstart -n default --grouping=false --show-conditions=all
}

migration_phase_control_plane() {
	echo "🐢 Phase 2 - Adopting the Control Planes."

	# Apply control plane kubeadmConfigs.
	for kubeadmConfig in kubeadmconfig_*; do
		if [[ "$kubeadmConfig" == *"-md-"* ]]; then
			continue
		fi
		remove_unneccessary_fields < "$kubeadmConfig" \
			| remove_owner_reference \
			| tee "${SCRIPT_DIR}/providers/${PROVIDER}/output/$(basename "${kubeadmConfig}")" \
			| kubectl apply -f -
	done

	# Apply control plane KubeadmConfigTemplates.
	for kubeadmConfigTemplate in kubeadmconfigtemplate_*; do
		if [[ "$kubeadmConfigTemplate" == *"-md-"* ]]; then
			continue
		fi
		add_cluster_owner_reference < "$kubeadmConfigTemplate" \
			| remove_unneccessary_fields \
			| tee "${SCRIPT_DIR}/providers/${PROVIDER}/output/$(basename "${kubeadmConfigTemplate}")" \
			| kubectl apply -f -
	done

	# Apply paused KubeadmControlPlane.
	jq 'del(.metadata.annotations["cluster.x-k8s.io/cloned-from-groupkind"], .metadata.annotations["cluster.x-k8s.io/cloned-from-name"])' kubeadmcontrolplane_* \
		| add_cluster_owner_reference \
		| remove_unneccessary_fields \
		| add_paused_annotation \
		| tee "${SCRIPT_DIR}/providers/${PROVIDER}/output/kubeadmcontrolplane.json" \
		| kubectl apply -f -
	sleep 1
	kubeadmControlPlaneName=$(jq -r '.metadata.name' kubeadmcontrolplane_*)
	kubeadmControlPlaneUID=$(get_uid kubeadmcontrolplane "$kubeadmControlPlaneName")

	# Patch controlplaneRef in Cluster.
	kubectl patch cluster capi-quickstart --type='json' -p='[{"op": "replace", "path": "/spec/controlPlaneRef", "value":{"apiVersion":"controlplane.cluster.x-k8s.io/v1beta1","kind":"KubeadmControlPlane","name":"'"$kubeadmControlPlaneName"'","namespace":"default"}}]'

	# Create secret-dummy. This secret is needed during node bootstrap and includes the cloud-init data.
	kubectl create secret generic secret-dummy || true

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
			| tee "${SCRIPT_DIR}/providers/${PROVIDER}/output/$(basename "${machine}")" \
			| kubectl apply -f -
	done

	infra_control_plane_migration

	# Unpause KubeadmControlPlane.
	kubectl annotate kubeadmcontrolplane "$kubeadmControlPlaneName" cluster.x-k8s.io/paused-

	wait_for "KubeadmControlPlane to be ready" "kubectl get kcp -ojson | kcp_or_md_ready"

	clusterctl describe cluster capi-quickstart -n default --grouping=false --show-conditions=all
}

migration_phase_worker() {
	echo "🐢 Phase 3 - Adopting the MachineDeployment."

	# Apply worker kubeadmConfigs.
	for kubeadmConfig in kubeadmconfig_*-md-*; do
		remove_unneccessary_fields < "$kubeadmConfig" \
			| remove_owner_reference \
			| tee "${SCRIPT_DIR}/providers/${PROVIDER}/output/$(basename "${kubeadmConfig}")" \
			| kubectl apply -f -
	done

	# Apply worker KubeadmConfigTemplates.
	for kubeadmConfigTemplate in kubeadmconfigtemplate_*-md-*; do
		add_cluster_owner_reference < "$kubeadmConfigTemplate" \
			| remove_unneccessary_fields \
			| tee "${SCRIPT_DIR}/providers/${PROVIDER}/output/$(basename "${kubeadmConfigTemplate}")" \
			| kubectl apply -f -
	done

	# Apply paused MachineDeployment.
	for machineDeployment in machinedeployment_*; do
		add_cluster_owner_reference < "$machineDeployment" \
			| remove_unneccessary_fields \
			| add_paused_annotation \
			| tee "${SCRIPT_DIR}/providers/${PROVIDER}/output/$(basename "${machineDeployment}")" \
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
			| tee "${SCRIPT_DIR}/providers/${PROVIDER}/output/$(basename "${machineSet}")" \
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
			| tee "${SCRIPT_DIR}/providers/${PROVIDER}/output/$(basename "${machine}")" \
			| kubectl apply -f -
	done

	infra_worker_migration

	# Unpause MachineDeployment and MachineSet.
	kubectl annotate machinedeployment "$machineDeploymentName" cluster.x-k8s.io/paused-
	kubectl annotate machineset "$machineSetName" cluster.x-k8s.io/paused-

	wait_for "MachineDeployment to be ready" "kubectl get md -ojson | kcp_or_md_ready"

	clusterctl describe cluster capi-quickstart -n default --grouping=false --show-conditions=all
	echo "🐢 Done! The orphaned cluster has been successfully migraed into Cluster API - wihtout any replacement of the nodes!"
}

rolling_upgrade_control_plane() {
	echo "🐢 Starting rolling upgrade for the control plane nodes."
	clusterctl alpha rollout restart "kubeadmcontrolplane/$(kubectl get kcp -ojson | jq -r '.items[].metadata.name')"
	# Wait a few seconds to let the rolling upgrade begin.
	sleep 5
	wait_for "KubeadmControlPlane to be ready" "kubectl get kcp -ojson | kcp_or_md_ready"
}

rolling_upgrade_worker() {
	echo "🐢 Starting rolling upgrade for the worker nodes."
	machineDeploymentName=$(kubectl get md -ojson | jq -r '.items[].metadata.name')
	# Patch maxSurge and maxUnavailable to 3 to add and remove all 3 worker nodes at once.
	kubectl patch machinedeployment "$machineDeploymentName" --type='json' -p='[{"op": "replace", "path": "/spec/strategy/rollingUpdate", "value":{"maxSurge": 3, "maxUnavailable": 3}}]'
	clusterctl alpha rollout restart "machinedeployment/$machineDeploymentName"
	# Wait a few seconds to let the rolling upgrade begin.
	sleep 5
	wait_for "MachineDeployment to be ready" "kubectl get md -ojson | kcp_or_md_ready"
}

prereqs
pushd $TMP_PATH/workload-backup/ > /dev/null

case "${COMMAND}" in
"purge_and_init_mgmt_cluster")
	purge_and_init_mgmt_cluster
	;;
"init_workload_cluster")
	init_workload_cluster
	;;
"migration_phase_cluster")
	migration_phase_cluster
	;;
"migration_phase_control_plane")
	migration_phase_control_plane
	;;
"migration_phase_worker")
	migration_phase_worker
	;;
"rolling_upgrade_control_plane")
	rolling_upgrade_control_plane
	;;
"rolling_upgrade_worker")
	rolling_upgrade_worker
	;;
"")
	purge_and_init_mgmt_cluster
	init_workload_cluster
	purge_and_init_mgmt_cluster
	migration_phase_cluster
	migration_phase_control_plane
	migration_phase_worker
	rolling_upgrade_control_plane
	rolling_upgrade_worker
	;;
*)
	echo "Invalid command: $1"
	echo
	usage
	exit 1
	;;
esac

pushd $TMP_PATH/workload-backup/ > /dev/null

popd > /dev/null
popd > /dev/null
