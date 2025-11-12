#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

CLUSTER_NAME=${1:-"cilium-test"}
POD_SUBNET=${2:-"10.244.0.0/16"}
SERVICE_SUBNET=${3:-"10.96.0.0/12"}
K8S_VERSION=${K8S_VERSION}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
TEST_DIR=$(dirname "${SCRIPT_DIR}")
CONFIG_TEMPLATE="${TEST_DIR}/yamls/kind-config.yaml"
CONFIG_FILE="/tmp/kind-config-${CLUSTER_NAME}.yaml"

echo "Creating Kind cluster: ${CLUSTER_NAME}"
echo "  Pod subnet: ${POD_SUBNET}"
echo "  Service subnet: ${SERVICE_SUBNET}"

# Generate config from template
sed -e "s|__POD_SUBNET__|${POD_SUBNET}|g" \
    -e "s|__SERVICE_SUBNET__|${SERVICE_SUBNET}|g" \
    "${CONFIG_TEMPLATE}" > "${CONFIG_FILE}"

flags="--config=${CONFIG_FILE} --wait=5m"
if [ -n "${K8S_VERSION}" ]; then
    flags="${flags} --image=kindest/node:${K8S_VERSION}"
fi

# Create cluster
kind create cluster --name=${CLUSTER_NAME} ${flags}

echo "✓ Cluster ${CLUSTER_NAME} created successfully"
