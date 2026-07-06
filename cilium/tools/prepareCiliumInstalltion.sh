#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# Get the script's directory and project root
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
PROJECT_ROOT=$(dirname "$(dirname "${SCRIPT_DIR}")")

# Source versions
source "${PROJECT_ROOT}/cilium/version.sh"

# Define output directories
CILIUM_ROOT="${PROJECT_ROOT}/cilium"
GATEWAY_API_DIR="${CILIUM_ROOT}/gateway-api"
CILIUM_CHART_DIR="${CILIUM_ROOT}/chart"
CILIUM_CLI_DIR="${CILIUM_ROOT}/binary"

# Clean old files
echo "Cleaning old files..."
rm -f "${GATEWAY_API_DIR}"/*
rm -f "${CILIUM_CHART_DIR}"/*
rm -f "${CILIUM_CLI_DIR}"/*

# Create directories if they don't exist
echo "Creating output directories..."
mkdir -p "${GATEWAY_API_DIR}" "${CILIUM_CHART_DIR}" "${CILIUM_CLI_DIR}"

# --- Gateway API CRDs ---
echo "Downloading Gateway API CRDs version ${GATEWAY_API_VERSION}..."

GATEWAY_API_BASE_URL="https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${GATEWAY_API_VERSION}/config/crd"

# Function to download with retries
download_with_retry() {
  local url="$1"
  local output_path="$2"
  local retries=3
  local delay=5

  for ((i=1; i<=retries; i++)); do
    echo "Downloading ${url} (attempt ${i})..."
    curl --fail --silent --show-error --location "${url}" -o "${output_path}"
    if [ $? -eq 0 ]; then
      return 0
    fi
    if [ ${i} -lt ${retries} ]; then
      echo "Download failed. Retrying in ${delay} seconds..."
      sleep ${delay}
    fi
  done

  echo "Error downloading ${url} after ${retries} attempts."
  return 1
}

# Standard CRDs
STANDARD_CRDS=(
  "standard/gateway.networking.k8s.io_gatewayclasses.yaml"
  "standard/gateway.networking.k8s.io_gateways.yaml"
  "standard/gateway.networking.k8s.io_httproutes.yaml"
  "standard/gateway.networking.k8s.io_grpcroutes.yaml"
  "standard/gateway.networking.k8s.io_referencegrants.yaml"
)

for crd in "${STANDARD_CRDS[@]}"; do
  download_with_retry "${GATEWAY_API_BASE_URL}/${crd}" "${GATEWAY_API_DIR}/$(basename "${crd}")" || exit 1
done

# Experimental CRDs
EXPERIMENTAL_CRDS=(
    "experimental/gateway.networking.k8s.io_tlsroutes.yaml"
)

for crd in "${EXPERIMENTAL_CRDS[@]}"; do
  download_with_retry "${GATEWAY_API_BASE_URL}/${crd}" "${GATEWAY_API_DIR}/$(basename "${crd}")" || exit 1
done

echo "Gateway API CRDs downloaded successfully."

# --- Cilium CLI ---
echo "Downloading Cilium CLI version ${CILIUM_CLI_VERSION}..."
# OS=$(uname -s | tr '[:upper:]' '[:lower:]')
OS="linux"
ARCH=$(uname -m)
if [ "${ARCH}" = "x86_64" ]; then
    ARCH="amd64"
fi

CILIUM_CLI_URL="https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-${OS}-${ARCH}.tar.gz"

download_with_retry "${CILIUM_CLI_URL}" "${CILIUM_CLI_DIR}/cilium-cli-${CILIUM_CLI_VERSION}-${OS}-${ARCH}.tar.gz" || exit 1

echo "Cilium CLI downloaded successfully."

# --- Hubble CLI ---
echo "Downloading Hubble CLI version ${HUBBLE_CLI_VERSION}..."
HUBBLE_CLI_URL="https://github.com/cilium/hubble/releases/download/${HUBBLE_CLI_VERSION}/hubble-${OS}-${ARCH}.tar.gz"

download_with_retry "${HUBBLE_CLI_URL}" "${CILIUM_CLI_DIR}/hubble-cli-${HUBBLE_CLI_VERSION}-${OS}-${ARCH}.tar.gz" || exit 1

echo "Hubble CLI downloaded successfully."

# --- Cilium Helm Chart ---
echo "Downloading Cilium Helm chart version ${CILIUM_VERSION}..."

helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo update cilium

helm pull cilium/cilium --version "${CILIUM_VERSION}" --destination "${CILIUM_CHART_DIR}"
if [ $? -ne 0 ]; then
  echo "Error downloading Cilium Helm chart"
  exit 1
fi

echo "Cilium Helm chart downloaded successfully."

# --- Tetragon Helm Chart ---
echo "Downloading Tetragon Helm chart version ${TETRAGON_VERSION}..."

helm pull cilium/tetragon --version "${TETRAGON_VERSION}" --destination "${CILIUM_CHART_DIR}"
if [ $? -ne 0 ]; then
  echo "Error downloading Tetragon Helm chart"
  exit 1
fi

echo "Tetragon Helm chart downloaded successfully."

echo "All Cilium resources prepared successfully."
