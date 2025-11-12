#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# Get the script's directory and project root
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
PROJECT_ROOT=$(dirname "$(dirname "${SCRIPT_DIR}")")
CILIUM_ROOT="${PROJECT_ROOT}/cilium"

# Source versions
source "${CILIUM_ROOT}/version.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "======================================"
echo "Cilium Values Validation Script"
echo "======================================"
echo ""

# Check for required tools
if ! command -v yq &> /dev/null; then
    echo -e "${RED}Error: yq is not installed${NC}"
    echo "Please install yq: https://github.com/mikefarah/yq"
    echo "  macOS: brew install yq"
    echo "  Linux: wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq && chmod +x /usr/bin/yq"
    exit 1
fi

if ! command -v helm &> /dev/null; then
    echo -e "${RED}Error: helm is not installed${NC}"
    exit 1
fi

# Define paths
CHART_PATH="${CILIUM_ROOT}/chart/cilium-${CILIUM_VERSION}.tgz"
PROJECT_VALUES="${CILIUM_ROOT}/values.yaml"
TEMP_DIR=$(mktemp -d)

trap "rm -rf ${TEMP_DIR}" EXIT

# Check if chart exists
if [ ! -f "${CHART_PATH}" ]; then
    echo -e "${RED}Error: Chart not found at ${CHART_PATH}${NC}"
    echo "Please run prepareCiliumInstalltion.sh first."
    exit 1
fi

if [ ! -f "${PROJECT_VALUES}" ]; then
    echo -e "${RED}Error: Project values.yaml not found at ${PROJECT_VALUES}${NC}"
    exit 1
fi

echo "[1/5] Extracting Cilium Chart..."
tar -xzf "${CHART_PATH}" -C "${TEMP_DIR}"
CHART_VALUES="${TEMP_DIR}/cilium/values.yaml"

if [ ! -f "${CHART_VALUES}" ]; then
    echo -e "${RED}Error: Could not extract chart values.yaml${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Chart extracted successfully${NC}"
echo "  Chart version: ${CILIUM_VERSION}"
echo ""

# Function to extract keys from YAML file (only non-commented keys)
extract_active_yaml_keys() {
    local file="$1"
    local output="$2"
    
    # Extract only active (non-commented) keys from YAML
    # Match patterns like "key:" but NOT "# key:"
    grep -E '^[[:space:]]*[a-zA-Z0-9_-]+:' "${file}" | \
        sed -E 's/:[[:space:]]*.*$//g' | \
        sed -E 's/^[[:space:]]*//g' | \
        sort -u > "${output}"
}

# Function to extract all keys from YAML file (including commented keys)
extract_all_yaml_keys() {
    local file="$1"
    local output="$2"
    
    # Extract keys from YAML, including commented lines
    # Match patterns like "key:" or "# key:" with proper indentation
    grep -E '^[[:space:]]*(#[[:space:]]*)?[a-zA-Z0-9_-]+:' "${file}" | \
        sed -E 's/^[[:space:]]*#[[:space:]]*//g' | \
        sed -E 's/:[[:space:]]*.*$//g' | \
        sed -E 's/^[[:space:]]*//g' | \
        sort -u > "${output}"
}

# Extract active keys from project values (ignore commented keys)
echo "[2/5] Extracting active keys from project values.yaml..."
extract_active_yaml_keys "${PROJECT_VALUES}" "${TEMP_DIR}/project_keys.txt"

PROJECT_KEY_COUNT=$(wc -l < "${TEMP_DIR}/project_keys.txt" | tr -d ' ')
echo -e "${GREEN}✓ Extracted ${PROJECT_KEY_COUNT} keys from project values${NC}"
echo ""

# Extract all keys from chart values (including commented keys)
echo "[3/5] Extracting all keys from chart values.yaml (including commented)..."
extract_all_yaml_keys "${CHART_VALUES}" "${TEMP_DIR}/chart_keys.txt"

CHART_KEY_COUNT=$(wc -l < "${TEMP_DIR}/chart_keys.txt" | tr -d ' ')
echo -e "${GREEN}✓ Extracted ${CHART_KEY_COUNT} keys from chart values${NC}"
echo ""

# Check for unknown or deprecated keys
echo "[4/5] Checking for unknown or deprecated configuration keys..."
echo ""

UNKNOWN_KEYS_FOUND=false
UNKNOWN_KEYS_FILE="${TEMP_DIR}/unknown_keys.txt"

while IFS= read -r key; do
    # Check if the active key from project exists in chart (including commented keys in chart)
    if ! grep -Fxq "${key}" "${TEMP_DIR}/chart_keys.txt"; then
        echo "${key}" >> "${UNKNOWN_KEYS_FILE}"
        echo -e "${YELLOW}⚠ Unknown key: ${key}${NC}"
        UNKNOWN_KEYS_FOUND=true
    fi
done < "${TEMP_DIR}/project_keys.txt"

if [ "$UNKNOWN_KEYS_FOUND" = false ]; then
    echo -e "${GREEN}✓ All configuration keys are valid${NC}"
else
    UNKNOWN_COUNT=$(wc -l < "${UNKNOWN_KEYS_FILE}" | tr -d ' ')
    echo ""
    echo -e "${YELLOW}Found ${UNKNOWN_COUNT} unknown key(s) in project values.yaml${NC}"
    echo -e "${YELLOW}These keys may be deprecated or invalid for Cilium ${CILIUM_VERSION}${NC}"
fi
echo ""

# Validate with helm template
echo "[5/5] Validating with 'helm template' (dry-run)..."
echo ""

VALIDATION_OUTPUT="${TEMP_DIR}/validation_output.txt"
VALIDATION_ERROR="${TEMP_DIR}/validation_error.txt"

# Run helm template with project values
if helm template test-cilium "${TEMP_DIR}/cilium" \
    -f "${PROJECT_VALUES}" \
    --namespace kube-system \
    --set cluster.name=test-cluster \
    --set cluster.id=100 \
    --set k8sServiceHost=127.0.0.1 \
    --set k8sServicePort=6443 \
    --set ipam.mode=cluster-pool \
    --set ipam.operator.clusterPoolIPv4PodCIDRList=10.0.0.0/8 \
    --set ipam.operator.clusterPoolIPv4MaskSize=24 \
    > "${VALIDATION_OUTPUT}" 2> "${VALIDATION_ERROR}"; then
    
    echo -e "${GREEN}✓ Helm template validation PASSED${NC}"
    HELM_VALIDATION_SUCCESS=true
else
    echo -e "${RED}✗ Helm template validation FAILED${NC}"
    echo ""
    echo "Errors:"
    cat "${VALIDATION_ERROR}"
    HELM_VALIDATION_SUCCESS=false
fi

echo ""
echo "======================================"
echo "Validation Summary"
echo "======================================"
echo "Cilium Version: ${CILIUM_VERSION}"
echo "Project Values: ${PROJECT_VALUES}"
echo "Chart Path: ${CHART_PATH}"
echo ""
echo "Statistics:"
echo "  - Project active keys: ${PROJECT_KEY_COUNT}"
echo "  - Chart keys (including commented): ${CHART_KEY_COUNT}"

if [ "$UNKNOWN_KEYS_FOUND" = true ]; then
    echo -e "  - Unknown keys: ${RED}${UNKNOWN_COUNT}${NC}"
else
    echo -e "  - Unknown keys: ${GREEN}0${NC}"
fi
echo ""

if [ "$HELM_VALIDATION_SUCCESS" = true ] && [ "$UNKNOWN_KEYS_FOUND" = false ]; then
    echo -e "${GREEN}Status: PASSED ✓${NC}"
    echo ""
    echo "Your configuration is fully compatible with Cilium ${CILIUM_VERSION}."
    echo "You can proceed with installation using setup.sh"
    echo ""
    echo -e "${BLUE}To install Cilium, run:${NC}"
    echo "  cd ${CILIUM_ROOT}"
    echo "  ./setup.sh"
    exit 0
elif [ "$HELM_VALIDATION_SUCCESS" = true ] && [ "$UNKNOWN_KEYS_FOUND" = true ]; then
    echo -e "${YELLOW}Status: WARNING ⚠${NC}"
    echo ""
    echo "Helm validation passed, but some keys in your values.yaml are not in the chart defaults."
    echo "This may indicate:"
    echo "  1. Deprecated keys that should be removed"
    echo "  2. Custom keys that are still functional but not documented"
    echo ""
    echo "Review the unknown keys listed above and consider removing them."
    echo "You can still proceed with installation, but monitor for warnings."
    exit 0
else
    echo -e "${RED}Status: FAILED ✗${NC}"
    echo ""
    echo "Please review the errors above and update your values.yaml accordingly."
    echo "You may need to:"
    echo "  1. Remove deprecated configuration keys"
    echo "  2. Update key names that have changed"
    echo "  3. Check the Cilium ${CILIUM_VERSION} release notes for breaking changes"
    echo ""
    echo "Reference: https://docs.cilium.io/en/v${CILIUM_VERSION}/operations/upgrade/"
    exit 1
fi
