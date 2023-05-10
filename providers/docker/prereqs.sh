#!/bin/bash
# shellcheck disable=SC2034

init_workload_cluster_prereqs() {
	# Delete workload cluster if it exists.
	kind delete cluster --name capi-quickstart
}

customize_workload_cluster() {
	# Use the clusterctl default to create the docker cluster.
	return 1
}

infra_prereqs() {
	PROVIDER_FLAVOR="development"
	return
}
