#!/bin/bash
# shellcheck disable=SC1090,SC2002,SC2034

migration_phase_cluster() {
	echo "🐢 We have an orphaned workload cluster now. Let's try to adopt it 🥳️"
	echo "🐢 Phase 1 - Adopting the Cluster Infrastructure."

	# Apply necessary secrets.
	for secret in ca etcd sa; do
		cert=$(jq -r '.data["tls.crt"]' < "$TMP_PATH/workload-backup/secret_capi-quickstart-${secret}.json")
		key=$(jq -r '.data["tls.key"]' < "$TMP_PATH/workload-backup/secret_capi-quickstart-${secret}.json")

		kustomize_resource "$SCRIPT_DIR/manifests/secret_cert.yaml" \
			| yq ".metadata.name = \"capi-quickstart-$secret\"" \
			| yq ".data[\"tls.crt\"] = \"$cert\"" \
			| yq ".data[\"tls.key\"] = \"$key\"" \
			| kubectl apply -f -
	done

	kubeconfig=$(jq -r '.data.value' < "$TMP_PATH/workload-backup/secret_capi-quickstart-kubeconfig.json")
	kustomize_resource "$SCRIPT_DIR/manifests/secret_kubeconfig.yaml" \
		| yq ".data.value = \"$kubeconfig\"" \
		| kubectl apply -f -

	# Get Cluster info from backup.
	controlPlaneEndpointHost=$(jq -r ".spec.controlPlaneEndpoint.host" < "$TMP_PATH/workload-backup/cluster_capi-quickstart.json")
	controlPlaneEndpointPort=$(jq -r ".spec.controlPlaneEndpoint.port" < "$TMP_PATH/workload-backup/cluster_capi-quickstart.json")
	podsCidr=$(jq -cr ".spec.clusterNetwork.pods.cidrBlocks" < "$TMP_PATH/workload-backup/cluster_capi-quickstart.json")
	servicesCidr=$(jq -cr ".spec.clusterNetwork.services.cidrBlocks" < "$TMP_PATH/workload-backup/cluster_capi-quickstart.json")

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

	# Run the provider specific Cluster migration.
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
		machineBackup=$(grep -l "$node" "$TMP_PATH/workload-backup/machine_"*json)
		machineName=$(jq -r '.metadata.name' "$machineBackup")
		kubeadmConfigBackup=$(grep -l "$machineName" "$TMP_PATH/workload-backup/kubeadmconfig_"*.json)

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
	kcpConfigSpec=$(jq -c '.spec.kubeadmConfigSpec' "$TMP_PATH/workload-backup/kubeadmcontrolplane_"*)

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
		machineBackup=$(grep -l "$node" "$TMP_PATH/workload-backup/machine_"*.json)

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

	# Run the provider specific Control Plane migration.
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
		machineBackup=$(grep -l "$node" "$TMP_PATH/workload-backup/machine_"*.json)

		# Get provider ID from backup. If you are trying to migrate a legacy cluster you have to get this somewhere else.
		providerID=$(jq -r '.spec.providerID' "$machineBackup")

		kustomize_resource "$SCRIPT_DIR/manifests/machine_worker.yaml" \
			| yq ".metadata.name = \"$node\"" \
			| yq ".spec.infrastructureRef.name = \"$node\"" \
			| yq ".spec.providerID = \"$providerID\"" \
			| yq ".spec.version = \"$KUBERNETES_VERSION\"" \
			| kubectl apply -f -
	done

	# Run the provider specific Worker migration.
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
