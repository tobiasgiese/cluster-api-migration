#!/bin/bash
# shellcheck disable=SC2034

init_workload_cluster_prereqs() {
	INFRA_API_VERSION=$(kubectl api-resources | awk '/openstackmachines/{print $3}')
	return
}

customize_workload_cluster() {
	# Use the clusterctl default to create the docker cluster.
	return 1
}

infra_prereqs() {
	# Manifest flavor.
	PROVIDER_FLAVOR="external-cloud-provider"
	# API version of the CAPO provider.
	CAPO_APIVERSION="v1alpha6"
	# Override worker count. Necessary to not have OOM killed VMs on a local DevStack.
	export WORKER_NODE_COUNT=1
	# DevStack clouds.yaml, you maybe might to set this.
	export OPENSTACK_CLOUD_YAML_B64=Y2xvdWRzOgogIGNhcG8tZTJlOgogICAgYXV0aDoKICAgICAgdXNlcm5hbWU6IGRlbW8KICAgICAgcGFzc3dvcmQ6IHNlY3JldGFkbWluCiAgICAgIHVzZXJfZG9tYWluX2lkOiBkZWZhdWx0CiAgICAgIGF1dGhfdXJsOiBodHRwOi8vMTAuMC4zLjE1L2lkZW50aXR5CiAgICAgIGRvbWFpbl9pZDogZGVmYXVsdAogICAgICBwcm9qZWN0X25hbWU6IGRlbW8KICAgIHZlcmlmeTogZmFsc2UKICAgIHJlZ2lvbl9uYW1lOiBSZWdpb25PbmUK
	# DevStack has only a single network. If you want to use your own OpenStack you might have to set this.
	export OPENSTACK_EXTERNAL_NETWORK_ID=public
	# OpenStack image name.
	export OPENSTACK_IMAGE_NAME="focal-server-cloudimg-amd64"
	# OpenStack cloud name.
	export OPENSTACK_CLOUD="capo-e2e"
	# Empty CA.
	export OPENSTACK_CLOUD_CACERT_B64=Cg==
	# The list of nameservers for OpenStack Subnet being created.
	# Set this value when you need create a new network/subnet while the access through DNS is required.
	export OPENSTACK_DNS_NAMESERVERS="8.8.8.8"
	# FailureDomain is the failure domain the machine will be created in.
	export OPENSTACK_FAILURE_DOMAIN=testaz1
	# The flavor reference for the flavor for your server instance.
	export OPENSTACK_CONTROL_PLANE_MACHINE_FLAVOR=m1.medium
	# The flavor reference for the flavor for your server instance.
	export OPENSTACK_NODE_MACHINE_FLAVOR=m1.small
	# The SSH key pair name
	export OPENSTACK_SSH_KEY_NAME=cluster-api-provider-openstack-sigs-k8s-io
}
