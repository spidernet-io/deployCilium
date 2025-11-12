#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

CLUSTER_NAME=${1:-"cilium-test"}
CLUSTER_ID=${2:-"1"}
POD_CIDR=${3:-"10.244.0.0/16"}
HUBBLE_PORT=${4:-"30000"}
CLUSTERMESH_PORT=${5:-"31000"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
TEST_DIR=$(dirname "${SCRIPT_DIR}")
ROOT_DIR=$(dirname "${TEST_DIR}")
CILIUM_DIR="${ROOT_DIR}/cilium"

echo "Installing Cilium on cluster: ${CLUSTER_NAME}"
echo "  Cluster ID: ${CLUSTER_ID}"
echo "  Pod CIDR: ${POD_CIDR}"

# Switch to cluster context
kubectl config use-context "kind-${CLUSTER_NAME}"

# Get API server IP
K8S_API_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Install Cilium
cd "${CILIUM_DIR}"
POD_v4CIDR="${POD_CIDR}" \
POD_v4Block="24" \
ENABLE_IPV6="false" \
CLUSTER_NAME="${CLUSTER_NAME}" \
CLUSTER_ID="${CLUSTER_ID}" \
K8S_API_IP="${K8S_API_IP}" \
K8S_API_PORT="6443" \
HUBBLE_WEBUI_NODEPORT_PORT="${HUBBLE_PORT}" \
CLUSTERMESH_APISERVER_NODEPORT="${CLUSTERMESH_PORT}" \
ENABLE_gatewayAPI="false" \
ENABLE_INTEGRATE_ISTIO="false" \
DAOCLOUD_REPO="" \
./setup.sh

echo "✓ Cilium installed on ${CLUSTER_NAME}"
