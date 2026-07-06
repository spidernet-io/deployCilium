#!/bin/bash

if [ -n "${BASH_SOURCE:-}" ]; then
    cilium_env_file="${BASH_SOURCE[0]}"
else
    cilium_env_file="${(%):-%N}"
fi

CILIUM_ROOT=${CILIUM_ROOT:-$(cd "$(dirname "${cilium_env_file}")" && pwd)}
CILIUM_MINOR=${CILIUM_MINOR:-"${CILIUM_TARGET_MINOR:-v1.19}"}

case "${CILIUM_MINOR}" in
    v[0-9]*.[0-9]*)
        ;;
    [0-9]*.[0-9]*)
        CILIUM_MINOR="v${CILIUM_MINOR}"
        ;;
    *)
        echo "CILIUM_MINOR must be a Cilium minor such as v1.19 or 1.19; got ${CILIUM_MINOR}" >&2
        return 1 2>/dev/null || exit 1
        ;;
esac

CILIUM_VERSION_DIR="${CILIUM_ROOT}/versions/${CILIUM_MINOR}"
CILIUM_CHART_DIR="${CILIUM_VERSION_DIR}/chart"
CILIUM_BINARY_DIR="${CILIUM_VERSION_DIR}/binary"
CILIUM_GATEWAY_API_DIR="${CILIUM_VERSION_DIR}/gateway-api"
CILIUM_VALUES_FILE="${CILIUM_VERSION_DIR}/values.yaml"
CILIUM_VERSION_FILE="${CILIUM_VERSION_DIR}/version.sh"

if [ ! -f "${CILIUM_VERSION_FILE}" ]; then
    echo "Unsupported Cilium minor ${CILIUM_MINOR}: missing ${CILIUM_VERSION_FILE}" >&2
    return 1 2>/dev/null || exit 1
fi

source "${CILIUM_VERSION_FILE}"

export CILIUM_ROOT
export CILIUM_MINOR
export CILIUM_TARGET_MINOR="${CILIUM_MINOR#v}"
export CILIUM_VERSION_DIR
export CILIUM_CHART_DIR
export CILIUM_BINARY_DIR
export CILIUM_GATEWAY_API_DIR
export CILIUM_VALUES_FILE
export CILIUM_VERSION_FILE

unset cilium_env_file
