#!/bin/bash

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
	kind get kubeconfig --name="capi-test" > "$TMP_PATH/kubeconfig-capi-mgmt"

	# Enable the experimental Cluster topology feature.
	export CLUSTER_TOPOLOGY=true

	clusterctl init --infrastructure "$PROVIDER" --wait-providers
}

kustomize_workload_manifest() {
	export KUBECONFIG=$TMP_PATH/kubeconfig-capi-mgmt

	# Start with the prereqs for this stage.
	init_workload_cluster_prereqs

	# And create a new workload cluster.
	clusterctl generate cluster capi-quickstart --flavor "$PROVIDER_FLAVOR" \
		--kubernetes-version "$KUBERNETES_VERSION" \
		--infrastructure="$PROVIDER" \
		--control-plane-machine-count="$CONTROL_PLANE_NODE_COUNT" \
		--worker-machine-count="$WORKER_NODE_COUNT" \
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
	kubectl get secret capi-quickstart-kubeconfig -ojsonpath='{.data.value}' | base64 -d > "$TMP_PATH/kubeconfig-workloadcluster"
	wait_for "kube-apiserver to be reachable to deploy CNI" "timeout 1 kubectl --kubeconfig=$TMP_PATH/kubeconfig-workloadcluster get nodes"
	kubectl --kubeconfig=$TMP_PATH/kubeconfig-workloadcluster apply -f "https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/calico.yaml"

	wait_for "KubeadmControlPlane to be ready" "kubectl get kcp -ojson | kcp_or_md_ready"
	wait_for "MachineDeployment to be ready" "kubectl get md -ojson | kcp_or_md_ready"

	rm -f "$TMP_PATH/workload-backup/"*
	echo "🐢 Creating backup for..."
	kubectl get "secret,$(kubectl api-resources -oname | grep cluster.x-k8s.io | cut -d. -f1 | xargs | sed 's/ /,/g')" -oname \
		| while IFS=/ read -r kind name; do
			echo "  $kind/$name"
			# ${kind/.*} removes everything after the first dot.
			kubectl get "$kind" "$name" -ojson > "$TMP_PATH/workload-backup/${kind/.*/}_${name}.json"
		done
}
