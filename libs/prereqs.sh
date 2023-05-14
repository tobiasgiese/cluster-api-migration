#!/bin/bash
# shellcheck disable=1090

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
	mkdir -p "$TMP_PATH/workload-backup"

	clusterctl_location="$TMP_BIN_PATH/clusterctl"
	if [[ ! -f "${clusterctl_location}" ]]; then
		wget -qO "${clusterctl_location}" "https://github.com/kubernetes-sigs/cluster-api/releases/download/$CAPI_VERSION/clusterctl-linux-amd64"
		chmod +x "${clusterctl_location}"
	fi

	kind_location="$TMP_BIN_PATH/kind"
	if [[ ! -f "${kind_location}" ]]; then
		wget -qO "${kind_location}" "https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-linux-amd64"
		chmod +x "${kind_location}"
	fi

	if ! command -v yq > /dev/null || file "$(command -v yq)" | grep -qi python; then
		yq_location="$TMP_BIN_PATH/yq"
		if [[ ! -f "$yq_location" ]]; then
			wget -qO "${yq_location}" "https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/yq_linux_amd64"
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
		wget -qO "/tmp/kustomize.tgz" "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz"
		tar xfz /tmp/kustomize.tgz -C "$TMP_BIN_PATH"
		chmod +x "$TMP_BIN_PATH/kustomize"
	fi

	# Source the infra specific prereqs and migration functions.
	source "${SCRIPT_DIR}/providers/${PROVIDER}/prereqs.sh"
	source "${SCRIPT_DIR}/providers/${PROVIDER}/migration.sh"
	infra_prereqs
}
