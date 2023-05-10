#!/bin/bash
# shellcheck disable=SC1090,SC2002

set -eo pipefail

PROVIDER=${1:-"docker"}
COMMAND=${2-""}
FORCE=${FORCE:-"false"}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

TMP_PATH=$SCRIPT_DIR/output
TMP_BIN_PATH=$TMP_PATH/bin
PATH=$TMP_BIN_PATH/:$PATH

CAPI_VERSION=v1.4.2
KIND_VERSION=v0.18.0
YQ_VERSION=v4.33.3
CALICO_VERSION=v3.24.1
KUBERNETES_VERSION=v1.27.1
KUSTOMIZE_VERSION=v5.0.2
WORKER_NODE_COUNT=3
CONTROL_PLANE_NODE_COUNT=1

PROVIDER_MANIFESTS_DIR="$SCRIPT_DIR/providers/$PROVIDER/manifests"

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
	echo "Providers:"
	echo "  docker (default)"
	echo
	echo "Commands:"
	echo "  purge_and_init_mgmt_cluster    Purge and initialize the management cluster."
	echo "  kustomize_workload_manifest    Adjust the workload cluster manifest with kustomize."
	echo "  init_workload_cluster          Initialize a new workload cluster."
	echo "  migration_phase_cluster        Perform the migration phase on a cluster."
	echo "  migration_phase_control_plane  Perform the migration phase on the control plane nodes of a cluster."
	echo "  migration_phase_worker         Perform the migration phase on the worker nodes of a cluster."
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

get_uid() {
	kubectl get "$1" "$2" -ojsonpath='{.metadata.uid}'
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

	echo "🐢 Downloading prereqs."

	mkdir -p "$TMP_BIN_PATH"
	mkdir -p $TMP_PATH/workload-backup

	clusterctl_location="$TMP_BIN_PATH/clusterctl"
	if [[ ! -f "${clusterctl_location}" ]]; then
		wget -qO "${clusterctl_location}" https://github.com/kubernetes-sigs/cluster-api/releases/download/$CAPI_VERSION/clusterctl-linux-amd64
		chmod +x "${clusterctl_location}"
	fi

	kind_location="$TMP_BIN_PATH/kind"
	if [[ ! -f "${kind_location}" ]]; then
		wget -qO "${kind_location}" https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-linux-amd64
		chmod +x "${kind_location}"
	fi

	if ! command -v yq > /dev/null || file "$(command -v yq)" | grep -qi python; then
		yq_location="$TMP_BIN_PATH/yq"
		if [[ ! -f "$yq_location" ]]; then
			wget -qO "${yq_location}" https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/yq_linux_amd64
			chmod +x "${yq_location}"
		fi
	fi

	# Ensure jq and kubectl binaries if not found. It's not necessary to have a specific version.
	if ! command -v jq > /dev/null; then
		wget -qO "$TMP_BIN_PATH/jq" https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64
		chmod +x "$TMP_BIN_PATH/jq"
	fi
	if ! command -v kubectl > /dev/null; then
		k8sVersion=$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)
		wget -qO "$TMP_BIN_PATH/kubectl" "https://storage.googleapis.com/kubernetes-release/release/${k8sVersion}/bin/linux/amd64/kubectl"
		chmod +x "$TMP_BIN_PATH/kubectl"
	fi
	if ! command -v kustomize > /dev/null; then
		wget -qO "/tmp/kustomize.tgz" https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz
		tar xfz /tmp/kustomize.tgz -C "$TMP_BIN_PATH"
		chmod +x "$TMP_BIN_PATH/kustomize"
	fi

	# Source the infra specific prereqs and migration functions.
	source "${SCRIPT_DIR}/providers/${PROVIDER}/prereqs.sh"
	source "${SCRIPT_DIR}/providers/${PROVIDER}/migration.sh"
	infra_prereqs
}

purge_and_init_mgmt_cluster() {
	# Delete cluster first.
	kind delete cluster --name capi-test

	# Init management kind cluster.
	cat <<- EOF | kind create cluster --name="capi-test" --config=-
		kind: Cluster
		apiVersion: kind.x-k8s.io/v1alpha4
		nodes:
		- role: control-plane
		  extraMounts:
		    - hostPath: /var/run/docker.sock
		      containerPath: /var/run/docker.sock
	EOF
	kind get kubeconfig --name="capi-test" > $TMP_PATH/kubeconfig-capi-mgmt

	# Enable the experimental Cluster topology feature.
	export CLUSTER_TOPOLOGY=true

	clusterctl init --infrastructure "$PROVIDER" --wait-providers
}

kustomize_resource() {
	manifest_path=$1
	manifest_filename=${manifest_path##*/}
	mkdir -p $TMP_PATH/kustomize
	rm -f $TMP_PATH/kustomize/*

	cp "$manifest_path" "$TMP_PATH/kustomize/base_$manifest_filename"
	cp "${SCRIPT_DIR}/providers/${PROVIDER}/kustomize/"* "$TMP_PATH/kustomize/"
	cat <<- EOF > "$TMP_PATH/kustomize/kustomization.yaml"
		resources:
		- base_$manifest_filename
	EOF

	cat "${SCRIPT_DIR}/providers/${PROVIDER}/kustomize/kustomization.yaml" >> "$TMP_PATH/kustomize/kustomization.yaml"

	kustomize build "$TMP_PATH/kustomize"
}

kustomize_workload_manifest() {
	export KUBECONFIG=$TMP_PATH/kubeconfig-capi-mgmt

	# Start with the prereqs for this stage.
	init_workload_cluster_prereqs

	# And create a new workload cluster.
	clusterctl generate cluster capi-quickstart --flavor "$PROVIDER_FLAVOR" \
		--kubernetes-version $KUBERNETES_VERSION \
		--infrastructure="$PROVIDER" \
		--control-plane-machine-count=$CONTROL_PLANE_NODE_COUNT \
		--worker-machine-count=$WORKER_NODE_COUNT \
		> "$TMP_PATH/capi-quickstart.yaml"

	kustomize_resource "$TMP_PATH/capi-quickstart.yaml" > "$TMP_PATH/capi-quickstart-kustomized.yaml"

}

init_workload_cluster() {
	if [[ ! -f "$TMP_PATH/capi-quickstart-kustomized.yaml" ]]; then
		echo "No capi-quickstart-kustomized.yaml manifest has been written. Run kustomize_workload_manifest first!"
		exit 1
	fi

	kustomize_resource "$TMP_PATH/capi-quickstart-kustomized.yaml" | kubectl apply -f -

	wait_for "kubeconfig to be created" "kubectl get secret capi-quickstart-kubeconfig"

	# Deploy CNI to have a ready KCP.
	kubectl get secret capi-quickstart-kubeconfig -ojsonpath='{.data.value}' | base64 -d > $TMP_PATH/kubeconfig-workloadcluster
	wait_for "kube-apiserver to be reachable to deploy CNI" "timeout 1 kubectl --kubeconfig=$TMP_PATH/kubeconfig-workloadcluster get nodes"
	kubectl --kubeconfig=$TMP_PATH/kubeconfig-workloadcluster apply -f https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/calico.yaml

	wait_for "KubeadmControlPlane to be ready" "kubectl get kcp -ojson | kcp_or_md_ready"
	wait_for "MachineDeployment to be ready" "kubectl get md -ojson | kcp_or_md_ready"

	rm -f $TMP_PATH/workload-backup/*
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
	for secret in ca etcd sa; do
		cert=$(jq -r '.data["tls.crt"]' < "secret_capi-quickstart-${secret}.json")
		key=$(jq -r '.data["tls.key"]' < "secret_capi-quickstart-${secret}.json")

		kustomize_resource "$SCRIPT_DIR/manifests/secret_cert.yaml" \
			| yq ".metadata.name = \"capi-quickstart-$secret\"" \
			| yq ".data[\"tls.crt\"] = \"$cert\"" \
			| yq ".data[\"tls.key\"] = \"$key\"" \
			| kubectl apply -f -
	done

	kubeconfig=$(jq -r '.data.value' < "secret_capi-quickstart-kubeconfig.json")
	kustomize_resource "$SCRIPT_DIR/manifests/secret_kubeconfig.yaml" \
		| yq ".data.value = \"$kubeconfig\"" \
		| kubectl apply -f -

	# Get Cluster info from backup.
	controlPlaneEndpointHost=$(jq -r ".spec.controlPlaneEndpoint.host" < cluster_capi-quickstart.json)
	controlPlaneEndpointPort=$(jq -r ".spec.controlPlaneEndpoint.port" < cluster_capi-quickstart.json)
	podsCidr=$(jq -cr ".spec.clusterNetwork.pods.cidrBlocks" < cluster_capi-quickstart.json)
	servicesCidr=$(jq -cr ".spec.clusterNetwork.services.cidrBlocks" < cluster_capi-quickstart.json)

	# If no services cidr block was defined use the default value.
	# See https://github.com/kubernetes/kubernetes/blob/6aa68d6a8b48c88348d4acd4e39f864b4634270b/cmd/kubeadm/app/apis/kubeadm/v1beta3/defaults.go#L35
	if [[ "$servicesCidr" = "null" ]]; then
		servicesCidr='["10.96.0.0/12"]'
	fi

	# Apply paused Cluster.
	kustomize_resource "$SCRIPT_DIR/manifests/cluster.yaml" \
		| yq ".spec.clusterNetwork.pods.cidrBlocks = $podsCidr" \
		| yq ".spec.clusterNetwork.services.cidrBlocks = $servicesCidr" \
		| yq ".spec.controlPlaneEndpoint.host = \"$controlPlaneEndpointHost\"" \
		| yq ".spec.controlPlaneEndpoint.port = $controlPlaneEndpointPort" \
		| kubectl apply -f -

	infra_cluster_migration

	# Unpause Cluster.
	kubectl annotate cluster capi-quickstart cluster.x-k8s.io/paused-
	clusterctl describe cluster capi-quickstart -n default --grouping=false --show-conditions=all
}

migration_phase_control_plane() {
	echo "🐢 Phase 2 - Adopting the Control Planes."

	# Get all control plane nodes from the Cluster.
	controlPlaneNodes=$(KUBECONFIG=$TMP_PATH/kubeconfig-workloadcluster kubectl get nodes -l node-role.kubernetes.io/control-plane= -oname | cut -d/ -f2)

	# Apply control plane KubeadmConfigs.
	for node in $controlPlaneNodes; do
		# Get KubeadmConfig name from backup.
		machineBackup=$(grep -l "$node" machine_*json)
		machineName=$(jq -r '.metadata.name' "$machineBackup")
		kubeadmConfigBackup=$(grep -l "$machineName" kubeadmconfig_*.json)

		# Get spec from KubeadmConfig.
		# You MUST ensure that the control plane kubeadmConfig.spec matches the running kubeadm config!
		kubeadmConfigSpec=$(jq -c '.spec' "$kubeadmConfigBackup")
		kustomize_resource "$SCRIPT_DIR/manifests/kubeadmconfig_control-plane.yaml" \
			| yq ".metadata.name = \"$node\"" \
			| yq ".spec = $kubeadmConfigSpec" \
			| kubectl apply -f -
	done

	# Get kubeadmConfigSpec from KubeadmControlPlane.
	# You MUST ensure that the control plane kubeadmConfigSpec matches the running kubeadm config!
	kcpConfigSpec=$(jq -c '.spec.kubeadmConfigSpec' kubeadmcontrolplane_*)

	kustomize_resource "$SCRIPT_DIR/manifests/kubeadmcontrolplane.yaml" \
		| yq ".spec.kubeadmConfigSpec = $kcpConfigSpec" \
		| yq ".spec.version = \"$KUBERNETES_VERSION\"" \
		| kubectl apply -f -

	# Create secret-dummy. This secret is needed during node bootstrap and includes cloud-init data.
	kubectl create secret generic secret-dummy --from-literal=value=empty || true

	# Get KubeadmControlPlane UID.
	kubeadmControlPlaneUID=$(get_uid kubeadmcontrolplane capi-quickstart-control-plane)

	# Apply paused control plane Machines.
	for node in $controlPlaneNodes; do
		kubeadmConfigUID=$(get_uid kubeadmconfig "$node")

		# Get Machine backup from node.
		machineBackup=$(grep -l "$node" machine_*.json)

		# Get provider ID from backup. If you are trying to migrate a legacy cluster you have to get this somewhere else.
		providerID=$(jq -r '.spec.providerID' "$machineBackup")

		kustomize_resource "$SCRIPT_DIR/manifests/machine_control-plane.yaml" \
			| yq ".metadata.name = \"$node\"" \
			| yq ".spec.bootstrap.configRef.name = \"$node\"" \
			| yq ".spec.bootstrap.configRef.uid = \"$kubeadmConfigUID\"" \
			| yq ".spec.infrastructureRef.name = \"$node\"" \
			| yq ".spec.providerID = \"$providerID\"" \
			| yq ".spec.version = \"$KUBERNETES_VERSION\"" \
			| kubectl apply -f -
	done

	infra_control_plane_migration

	# Unpause Machines and KubeadmControlPlane.
	for machine in $(kubectl get ma -l cluster.x-k8s.io/control-plane= -oname); do
		kubectl annotate "$machine" cluster.x-k8s.io/paused-
	done
	kubectl annotate kubeadmcontrolplane capi-quickstart-control-plane cluster.x-k8s.io/paused-

	wait_for "KubeadmControlPlane to be ready" "kubectl get kcp -ojson | kcp_or_md_ready"

	clusterctl describe cluster capi-quickstart -n default --grouping=false --show-conditions=all
}

migration_phase_worker() {
	echo "🐢 Phase 3 - Adopting the MachineDeployment."

	# Get all worker nodes from the cluster.
	workerNodes=$(KUBECONFIG=$TMP_PATH/kubeconfig-workloadcluster kubectl get nodes -l node-role.kubernetes.io/control-plane!= -oname | cut -d/ -f2)

	# Get MachineSet name by removing everything after the last dash of a random Pod.
	# Note: this must be done manually if your node names are different to these from CAPI.
	randomWorkerNodeName=$(KUBECONFIG=$TMP_PATH/kubeconfig-workloadcluster kubectl get nodes -l node-role.kubernetes.io/control-plane!= -oname | cut -d/ -f2 | head -n1)
	machineSetName=${randomWorkerNodeName%-*}
	# The same for the MachineDeployment name. Just calculate it from the MachineSet.
	machineDeploymentName=${machineSetName%-*}
	kubeadmConfigTemplateName=$machineDeploymentName

	# Apply KubeadmConfigTemplate.
	kustomize_resource "$SCRIPT_DIR/manifests/kubeadmconfigtemplate.yaml" \
		| yq ".metadata.name = \"$kubeadmConfigTemplateName\"" \
		| kubectl apply -f -

	# Apply paused MachineDeployment.
	kustomize_resource "$SCRIPT_DIR/manifests/machinedeployment.yaml" \
		| yq ".metadata.name = \"$machineDeploymentName\"" \
		| yq ".spec.template.spec.bootstrap.configRef.name = \"$kubeadmConfigTemplateName\"" \
		| yq ".spec.template.spec.version = \"$KUBERNETES_VERSION\"" \
		| yq ".spec.replicas = $WORKER_NODE_COUNT" \
		| kubectl apply -f -
	sleep 1
	machineDeploymentUID=$(get_uid machinedeployment "$machineDeploymentName")

	# Apply Machineset.
	kustomize_resource "$SCRIPT_DIR/manifests/machineset.yaml" \
		| yq ".metadata.name = \"$machineSetName\"" \
		| yq ".spec.template.spec.bootstrap.configRef.name = \"$kubeadmConfigTemplateName\"" \
		| yq ".spec.template.spec.version = \"$KUBERNETES_VERSION\"" \
		| yq ".spec.replicas = $WORKER_NODE_COUNT" \
		| kubectl apply -f -
	sleep 1
	machineSetUID=$(get_uid machineset "$machineSetName")

	# Apply worker Machines.
	for node in $workerNodes; do
		# Get Machine backup from node.
		machineBackup=$(grep -l "$node" machine_*.json)

		# Get provider ID from backup. If you are trying to migrate a legacy cluster you have to get this somewhere else.
		providerID=$(jq -r '.spec.providerID' "$machineBackup")

		kustomize_resource "$SCRIPT_DIR/manifests/machine_worker.yaml" \
			| yq ".metadata.name = \"$node\"" \
			| yq ".spec.infrastructureRef.name = \"$node\"" \
			| yq ".spec.providerID = \"$providerID\"" \
			| yq ".spec.version = \"$KUBERNETES_VERSION\"" \
			| kubectl apply -f -
	done

	infra_worker_migration

	# Unpause Machines, MachineDeployment and MachineSet.
	for machine in $(kubectl get ma -l cluster.x-k8s.io/control-plane!= -oname); do
		kubectl annotate "$machine" cluster.x-k8s.io/paused-
	done
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
pushd "$TMP_PATH/workload-backup" > /dev/null

press_enter() {
	if [[ ! "$FORCE" = "true" ]]; then
		read -r -p "🐢 Press ENTER to continue "
	fi
}

case "${COMMAND}" in
"purge_and_init_mgmt_cluster")
	purge_and_init_mgmt_cluster
	;;
"kustomize_workload_manifest")
	kustomize_workload_manifest
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
	kustomize_workload_manifest
	press_enter

	init_workload_cluster
	purge_and_init_mgmt_cluster
	press_enter

	migration_phase_cluster
	press_enter

	migration_phase_control_plane
	press_enter

	migration_phase_worker
	press_enter

	rolling_upgrade_control_plane
	press_enter

	rolling_upgrade_worker
	;;
*)
	echo "Invalid command: $1"
	echo
	usage
	exit 1
	;;
esac

popd > /dev/null
