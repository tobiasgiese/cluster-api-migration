#!/bin/bash
# shellcheck disable=SC1091,SC2034

set -eo pipefail

PROVIDER=${1:-"docker"}
COMMAND=${2-""}
FORCE=${FORCE:-"false"}

if [[ ! -d "providers/${PROVIDER}" ]]; then
	echo "Provider not found: $PROVIDER"
	exit 1
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

source "$SCRIPT_DIR/config.env"
source "$SCRIPT_DIR/lib/prereqs.sh"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/init.sh"
source "$SCRIPT_DIR/lib/migration.sh"

TMP_PATH=$SCRIPT_DIR/output
TMP_BIN_PATH=$TMP_PATH/bin
PATH=$TMP_BIN_PATH/:$PATH

PROVIDER_MANIFESTS_DIR="$SCRIPT_DIR/providers/$PROVIDER/manifests"

# Run the prerequisites
# * download necessary tools
# * source provider specific migration phases
# * run provider specific prerequisites
prereqs

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
