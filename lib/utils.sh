#!/bin/bash

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

kustomize_resource() {
	manifest_path=$1
	manifest_filename=${manifest_path##*/}
	mkdir -p "$TMP_PATH/kustomize"
	rm -f "$TMP_PATH/kustomize/"*

	cp "$manifest_path" "$TMP_PATH/kustomize/base_$manifest_filename"
	cp "${SCRIPT_DIR}/providers/${PROVIDER}/kustomize/"* "$TMP_PATH/kustomize/"
	cat <<- EOF > "$TMP_PATH/kustomize/kustomization.yaml"
		resources:
		- base_$manifest_filename
	EOF

	cat "${SCRIPT_DIR}/providers/${PROVIDER}/kustomize/kustomization.yaml" >> "$TMP_PATH/kustomize/kustomization.yaml"

	kustomize build "$TMP_PATH/kustomize"
}

wait_for() {
	echo -n "🐢 Waiting for $1"
	until eval "$2" &> /dev/null; do
		printf .
		sleep 1
	done
	echo
}

press_enter() {
	if [[ ! "$FORCE" = "true" ]]; then
		read -r -p "🐢 Press ENTER to continue "
	fi
}

get_uid() {
	kubectl get "$1" "$2" -ojsonpath='{.metadata.uid}'
}

kcp_or_md_ready() {
	jq -e '.items[].status | select(.replicas == .readyReplicas and .readyReplicas == .updatedReplicas and (.unavailableReplicas == 0 or .unavailableReplicas == null)) | true'
}
