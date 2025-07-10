#!/bin/bash

# !!!!!!!!!!
# https://github.com/cilium/cilium/releases
CILIUM_VERSION=${CILIUM_VERSION:-"1.17.5"}

# v1.17.0 支持 gatewayAPI v1.2.0 
# https://docs.cilium.io/en/latest/network/servicemesh/gateway-api/gateway-api/
GATEWAY_API_VERSION=${GATEWAY_API_VERSION:-""v1.2.0""}

# https://github.com/cilium/cilium-cli/releases
CILIUM_CLI_VERSION=${CILIUM_CLI_VERSION:-"v0.18.5"}

# !!!!!!!!!!
# https://github.com/cilium/hubble/releases
HUBBLE_CLI_VERSION=${HUBBLE_CLI_VERSION:-"v1.17.5"}

# https://github.com/cilium/tetragon/releases
TETRAGON_VERSION=${TETRAGON_VERSION:-"1.4.0"}

