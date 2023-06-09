#!/bin/bash
# shellcheck disable=SC2154,SC2002

infra_cluster_migration() {
	kubectl patch cluster capi-quickstart --type='json' -p='[{"op": "replace", "path": "/spec/infrastructureRef/kind", "value":"DockerCluster"}]'

	# Apply DockerCluster
	cat "$PROVIDER_MANIFESTS_DIR/dockercluster.yaml" \
		| yq ".spec.controlPlaneEndpoint.host = \"$controlPlaneEndpointHost\"" \
		| yq ".spec.controlPlaneEndpoint.port = $controlPlaneEndpointPort" \
		| kubectl apply -f -
}

infra_control_plane_migration() {
	cat "$PROVIDER_MANIFESTS_DIR/dockermachinetemplate.yaml" \
		| kubectl apply -f -

	# Patch KubeadmControlPlane machine template kind to DockerMachineTemplate.
	kubectl patch kubeadmcontrolplane capi-quickstart-control-plane --type='json' -p='[{"op": "replace", "path": "/spec/machineTemplate/infrastructureRef/kind", "value":"DockerMachineTemplate"}]'

	# Apply paused control plane DockerMachines and unpause Machine and DockerMachine.
	for node in $controlPlaneNodes; do
		providerID=$(kubectl get machine "$node" -ojsonpath='{.spec.providerID}')

		cat "$PROVIDER_MANIFESTS_DIR/dockermachine.yaml" \
			| yq ".metadata.name = \"$node\"" \
			| yq ".spec.providerID = \"$providerID\"" \
			| yq ".spec.customImage = \"kindest/node:$KUBERNETES_VERSION\"" \
			| kubectl apply -f -
		sleep 1
		dockerMachineUID=$(get_uid dockermachine "$node")

		# Patch DockerMachine UID in Machine.
		kubectl patch machine "$node" --type='json' -p='[{"op": "replace", "path": "/spec/infrastructureRef/uid", "value":"'"$dockerMachineUID"'"}]'
		kubectl patch machine "$node" --type='json' -p='[{"op": "replace", "path": "/spec/infrastructureRef/kind", "value":"DockerMachine"}]'
	done
}

infra_worker_migration() {
	# Apply control plane DockerMachineTemplate.
	cat "$PROVIDER_MANIFESTS_DIR/dockermachinetemplate.yaml" \
		| kubectl apply -f -

	# Patch MachineSet and MachineDeployment machine template kind to DockerMachineTemplate.
	kubectl patch machineset "$machineSetName" --type='json' -p='[{"op": "replace", "path": "/spec/template/spec/infrastructureRef/kind", "value":"DockerMachineTemplate"}]'
	kubectl patch machinedeployment "$machineDeploymentName" --type='json' -p='[{"op": "replace", "path": "/spec/template/spec/infrastructureRef/kind", "value":"DockerMachineTemplate"}]'

	# Apply worker DockerMachines.
	for node in $workerNodes; do
		providerID=$(kubectl get machine "$node" -ojsonpath='{.spec.providerID}')

		cat "$PROVIDER_MANIFESTS_DIR/dockermachine.yaml" \
			| yq ".metadata.name = \"$node\"" \
			| yq ".metadata.annotations[\"cluster.x-k8s.io/deployment-name\"] = \"$machineDeploymentName\"" \
			| yq ".spec.providerID = \"$providerID\"" \
			| yq ".spec.customImage = \"kindest/node:$KUBERNETES_VERSION\"" \
			| kubectl apply -f -
		sleep 1
		dockerMachineUID=$(get_uid dockermachine "$node")

		# Patch DockerMachine UID in Machine.
		kubectl patch machine "$node" --type='json' -p='[{"op": "replace", "path": "/spec/infrastructureRef/uid", "value":"'"$dockerMachineUID"'"}]'
		kubectl patch machine "$node" --type='json' -p='[{"op": "replace", "path": "/spec/infrastructureRef/kind", "value":"DockerMachine"}]'
	done
}
