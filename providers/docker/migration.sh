#!/bin/bash

infra_cluster_migration() {
	# Apply DockerCluster
	add_cluster_owner_reference < dockercluster_* \
		| remove_unneccessary_fields \
		| tee "${SCRIPT_DIR}/providers/docker/output/dockercluster.json" \
		| kubectl apply -f -
}

infra_control_plane_migration() {
	# Apply control plane DockerMachineTemplate.
	add_cluster_owner_reference < dockermachinetemplate_capi-quickstart-control-plane-* \
		| remove_unneccessary_fields \
		| tee "${SCRIPT_DIR}/providers/${PROVIDER}/output/dockermachinetemplate_capi-quickstart-control-plane.json" \
		| kubectl apply -f -

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
			| tee "${SCRIPT_DIR}/providers/${PROVIDER}/output/$(basename "${dockerMachine}")" \
			| kubectl apply -f -
		sleep 1
		dockerMachineName=$(jq -r '.metadata.name' "$dockerMachine")
		dockerMachineUID=$(get_uid dockermachine "$dockerMachineName")

		# Patch DockerMachine UID in Machine.
		kubectl patch machine "$machineName" --type='json' -p='[{"op": "replace", "path": "/spec/infrastructureRef/uid", "value":"'"$dockerMachineUID"'"}]'
		kubectl annotate machine "$machineName" cluster.x-k8s.io/paused-
		kubectl annotate dockermachine "$dockerMachineName" cluster.x-k8s.io/paused-
	done

}

infra_worker_migration() {
	# Apply control plane DockerMachineTemplate.
	add_cluster_owner_reference < dockermachinetemplate_capi-quickstart-md-0-infra-* \
		| remove_unneccessary_fields \
		| tee "${SCRIPT_DIR}/providers/${PROVIDER}/output/dockermachinetemplate_capi-quickstart-md-0-infra.json" \
		| kubectl apply -f -

	# Apply paused worker DockerMachines.
	for dockerMachine in dockermachine_*-md-*; do
		machineName=$(jq -r '.metadata.ownerReferences[].name' "$dockerMachine")
		machineUID=$(get_uid machine "$machineName")
		# Apply DockerMachine.
		jq ".metadata.ownerReferences[].uid = \"$machineUID\"" "$dockerMachine" \
			| remove_unneccessary_fields \
			| tee "${SCRIPT_DIR}/providers/${PROVIDER}/output/$(basename "${dockerMachine}")" \
			| kubectl apply -f -
		sleep 1
		dockerMachineName=$(jq -r '.metadata.name' "$dockerMachine")
		dockerMachineUID=$(get_uid dockermachine "$dockerMachineName")

		# Patch DockerMachine UID in Machine.
		kubectl patch machine "$machineName" --type='json' -p='[{"op": "replace", "path": "/spec/infrastructureRef/uid", "value":"'"$dockerMachineUID"'"}]'
	done
}
