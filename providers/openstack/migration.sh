#!/bin/bash
# shellcheck disable=SC2154,SC2002

infra_cluster_migration() {
	# Apply cloud config secret.
	kubectl apply -f secret_capi-quickstart-cloud-config.json

	kubectl patch cluster capi-quickstart --type='json' -p='[{"op": "replace", "path": "/spec/infrastructureRef/kind", "value":"OpenStackCluster"}]'
	kubectl patch cluster capi-quickstart --type='json' -p='[{"op": "replace", "path": "/spec/infrastructureRef/apiVersion", "value":"infrastructure.cluster.x-k8s.io/'"$CAPO_APIVERSION"'"}]'

	# Apply OpenStackCluster
	kustomize_resource "$PROVIDER_MANIFESTS_DIR/openstackcluster.yaml" \
		| yq ".spec.controlPlaneEndpoint.host = \"$controlPlaneEndpointHost\"" \
		| yq ".spec.controlPlaneEndpoint.port = $controlPlaneEndpointPort" \
		| yq ".spec.dnsNameservers = [\"$OPENSTACK_DNS_NAMESERVERS\"]" \
		| yq ".spec.externalNetworkId = \"$OPENSTACK_EXTERNAL_NETWORK_ID\"" \
		| kubectl apply -f -
}

infra_control_plane_migration() {
	kustomize_resource "$PROVIDER_MANIFESTS_DIR/openstackmachinetemplate.yaml" \
		| kubectl apply -f -

	# Patch KubeadmControlPlane machine template kind to OpenStackMachineTemplate.
	kubectl patch kubeadmcontrolplane capi-quickstart-control-plane --type='json' -p='[{"op": "replace", "path": "/spec/machineTemplate/infrastructureRef/kind", "value":"OpenStackMachineTemplate"}]'
	kubectl patch kubeadmcontrolplane capi-quickstart-control-plane --type='json' -p='[{"op": "replace", "path": "/spec/machineTemplate/infrastructureRef/apiVersion", "value":"infrastructure.cluster.x-k8s.io/'"$CAPO_APIVERSION"'"}]'

	# Apply paused control plane OpenStackMachines and unpause Machine and OpenStackMachine.
	for node in $controlPlaneNodes; do
		# Get Machine backup from node.
		openstackMachineBackup=$(grep -l "$node" openstackmachine_*.json)

		providerID=$(kubectl get machine "$node" -ojsonpath='{.spec.providerID}')
		# Get instance ID from backup. If you are trying to migrate a legacy cluster you have to get this somewhere else.
		instanceID=$(jq -r '.spec.instanceID' "$openstackMachineBackup")

		kustomize_resource "$PROVIDER_MANIFESTS_DIR/openstackmachine.yaml" \
			| yq ".metadata.name = \"$node\"" \
			| yq ".spec.providerID = \"$providerID\"" \
			| yq ".spec.instanceID = \"$instanceID\"" \
			| kubectl apply -f -
		sleep 1
		openstackMachineUID=$(get_uid openstackmachine "$node")

		# Patch OpenStackMachine UID in Machine.
		kubectl patch machine "$node" --type='json' -p='[{"op": "replace", "path": "/spec/infrastructureRef/uid", "value":"'"$openstackMachineUID"'"}]'
		kubectl patch machine "$node" --type='json' -p='[{"op": "replace", "path": "/spec/infrastructureRef/kind", "value":"OpenStackMachine"}]'
		kubectl patch machine "$node" --type='json' -p='[{"op": "replace", "path": "/spec/infrastructureRef/apiVersion", "value":"infrastructure.cluster.x-k8s.io/'"$CAPO_APIVERSION"'"}]'
	done
}

infra_worker_migration() {
	# Apply control plane OpenStackMachineTemplate.
	kustomize_resource "$PROVIDER_MANIFESTS_DIR/openstackmachinetemplate.yaml" \
		| kubectl apply -f -

	# Patch MachineSet and MachineDeployment machine template kind to OpenStackMachineTemplate.
	kubectl patch machineset "$machineSetName" --type='json' -p='[{"op": "replace", "path": "/spec/template/spec/infrastructureRef/kind", "value":"OpenStackMachineTemplate"}]'
	kubectl patch machineset "$machineSetName" --type='json' -p='[{"op": "replace", "path": "/spec/template/spec/infrastructureRef/apiVersion", "value":"infrastructure.cluster.x-k8s.io/'"$CAPO_APIVERSION"'"}]'
	kubectl patch machinedeployment "$machineDeploymentName" --type='json' -p='[{"op": "replace", "path": "/spec/template/spec/infrastructureRef/kind", "value":"OpenStackMachineTemplate"}]'
	kubectl patch machinedeployment "$machineDeploymentName" --type='json' -p='[{"op": "replace", "path": "/spec/template/spec/infrastructureRef/apiVersion", "value":"infrastructure.cluster.x-k8s.io/'"$CAPO_APIVERSION"'"}]'

	# Apply worker OpenStackMachines.
	for node in $workerNodes; do
		# Get Machine backup from node.
		openstackMachineBackup=$(grep -l "$node" openstackmachine_*.json)

		providerID=$(kubectl get machine "$node" -ojsonpath='{.spec.providerID}')
		# Get instance ID from backup. If you are trying to migrate a legacy cluster you have to get this somewhere else.
		instanceID=$(jq -r '.spec.instanceID' "$openstackMachineBackup")

		kustomize_resource "$PROVIDER_MANIFESTS_DIR/openstackmachine.yaml" \
			| yq ".metadata.name = \"$node\"" \
			| yq ".metadata.annotations[\"cluster.x-k8s.io/deployment-name\"] = \"$machineDeploymentName\"" \
			| yq ".spec.providerID = \"$providerID\"" \
			| yq ".spec.instanceID = \"$instanceID\"" \
			| kubectl apply -f -
		sleep 1
		openstackMachineUID=$(get_uid openstackmachine "$node")

		# Patch OpenStackMachine UID in Machine.
		kubectl patch machine "$node" --type='json' -p='[{"op": "replace", "path": "/spec/infrastructureRef/uid", "value":"'"$openstackMachineUID"'"}]'
		kubectl patch machine "$node" --type='json' -p='[{"op": "replace", "path": "/spec/infrastructureRef/kind", "value":"OpenStackMachine"}]'
		kubectl patch machine "$node" --type='json' -p='[{"op": "replace", "path": "/spec/infrastructureRef/apiVersion", "value":"infrastructure.cluster.x-k8s.io/'"$CAPO_APIVERSION"'"}]'
	done
}
