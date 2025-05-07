#!/bin/bash

# generateKubeConfig.sh - A script to merge multiple kubeconfig files into a single one
# 
# Usage: ./generateKubeConfig.sh -o output_kubeconfig input_kubeconfig1:cluster_name1 input_kubeconfig2:cluster_name2 [input_kubeconfig3:cluster_name3 ...]
#
# This script merges multiple kubeconfig files into a single one, preserving all clusters, 
# contexts, and users from the input files. It uses kubectl to handle the merging process.
# You can specify a custom cluster name for each input file using the format:
# input_file:cluster_name (this is recommended to avoid conflicts)

set -e
CURRENT_FILENAME=$( basename $0 )
CURRENT_DIR_PATH=$(cd $(dirname $0); pwd)

# Function to display usage information
usage() {
    echo "Usage: $0 [-o output_kubeconfig] input_kubeconfig1:cluster_name1 input_kubeconfig2:cluster_name2 [input_kubeconfig3:cluster_name3 ...]"
    echo ""
    echo "Options:"
    echo "  -o, --output    Output kubeconfig file path [merged_kubeconfig.yaml]"
    echo "  -h, --help      Display this help message"
    echo ""
    echo "Example:"
    echo "  $0 -o merged_kubeconfig.yaml kubeconfig1.yaml:cluster1 kubeconfig2.yaml:cluster2"
    echo ""
    echo "Note:"
    echo "  You should specify a custom cluster name for each input file using the format: input_file:cluster_name"
    echo "  This is required when merging configs from different clusters that have the same cluster name"
    exit 1
}

# Function to check if kubectl is installed
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        echo "Error: kubectl is required but not found in PATH"
        echo "Please install kubectl before running this script"
        exit 1
    fi
}

# Function to log messages
log() {
    local level=$1
    local message=$2
    
    # Get current timestamp
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    
    case $level in
        "INFO")
            echo -e "[$timestamp] [INFO] $message"
            ;;
        "WARNING")
            echo -e "[$timestamp] [WARNING] $message" >&2
            ;;
        "ERROR")
            echo -e "[$timestamp] [ERROR] $message" >&2
            ;;
        "DEBUG")
            if [[ -n "$DEBUG" ]]; then
                echo -e "[$timestamp] [DEBUG] $message" >&2
            fi
            ;;
    esac
}

if ! which jq &>/dev/null ; then
    log "ERROR" "jq is required but not found in PATH"
    exit 1
fi

if ! which kubectl &>/dev/null ; then
    log "ERROR" "kubectl is required but not found in PATH"
    exit 1
fi

if ! which base64 &>/dev/null ; then
    log "ERROR" "base64 is required but not found in PATH"
    exit 1
fi


# Parse command line arguments
output_file="${CURRENT_DIR_PATH}/merged_kubeconfig.yaml"
input_files=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--output)
            output_file="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            # Add to input files
            input_files+=("$1")
            shift
            ;;
    esac
done

# Validate arguments
if [[ -z "$output_file" ]]; then
    log "ERROR" "Output file must be specified with -o option"
    usage
fi

if [[ ${#input_files[@]} -lt 1 ]]; then
    log "ERROR" "At least one input kubeconfig file must be provided"
    usage
fi

# Check for kubectl
check_kubectl

# Create a temporary directory for processing
temp_dir=$(mktemp -d)
log "DEBUG" "Created temporary directory: $temp_dir"

# Clean up temporary directory on exit
trap 'log "DEBUG" "Removing temporary directory: $temp_dir"; rm -rf "$temp_dir"' EXIT

# Create an empty merged kubeconfig file
cat > "$output_file" << EOF
apiVersion: v1
kind: Config
preferences: {}
current-context: ""
clusters: []
contexts: []
users: []
EOF

# Function to process a kubeconfig file
process_kubeconfig() {
    local input_spec="$1"
    local output_file="$2"
    
    # Parse input spec (file:cluster_name)
    local input_file
    local cluster_name
    
    if [[ "$input_spec" == *":"* ]]; then
        input_file="${input_spec%%:*}"
        cluster_name="${input_spec#*:}"
    else
        input_file="$input_spec"
        # Generate a random cluster name to avoid conflicts
        cluster_name="cluster-$(date +%s)-$RANDOM"
        log "WARNING" "No cluster name specified for $input_file, using auto-generated name: $cluster_name"
    fi
    
    # Check if input file exists
    if [[ ! -f "$input_file" ]]; then
        log "ERROR" "Input file does not exist: $input_file"
        exit 1
    fi
    
    log "INFO" "Processing kubeconfig: $input_file (cluster name: $cluster_name)"
    
    # Create a temporary file for this cluster's config
    local temp_config="$temp_dir/config_${cluster_name}.yaml"
    
    # Copy the original kubeconfig to the temporary file
    cp "$input_file" "$temp_config"
    
    # Get original cluster and user names
    local orig_cluster_name=$(kubectl --kubeconfig="$temp_config" config view -o jsonpath='{.clusters[0].name}')
    local orig_user_name=$(kubectl --kubeconfig="$temp_config" config view -o jsonpath='{.users[0].name}')
    local orig_context_name=$(kubectl --kubeconfig="$temp_config" config current-context 2>/dev/null || echo "")
    
    if [[ -z "$orig_cluster_name" ]]; then
        log "ERROR" "Failed to get cluster name from $input_file"
        exit 1
    fi
    
    if [[ -z "$orig_user_name" ]]; then
        log "ERROR" "Failed to get user name from $input_file"
        exit 1
    fi
    
    # Create a new user name based on the cluster name
    local new_user_name="${orig_user_name}-${cluster_name}"
    
    # Extract cluster information
    local server=$(kubectl --kubeconfig="$temp_config" config view -o jsonpath="{.clusters[0].cluster.server}")
    local ca_file="$temp_dir/ca_${cluster_name}.crt"
    kubectl --kubeconfig="$temp_config" config view --raw -o jsonpath="{.clusters[0].cluster.certificate-authority-data}" | base64 -d > "$ca_file"
    
    # Extract user information
    local client_cert_file="$temp_dir/client_${cluster_name}.crt"
    local client_key_file="$temp_dir/client_${cluster_name}.key"
    kubectl --kubeconfig="$temp_config" config view --raw -o jsonpath="{.users[0].user.client-certificate-data}" | base64 -d > "$client_cert_file"
    kubectl --kubeconfig="$temp_config" config view --raw -o jsonpath="{.users[0].user.client-key-data}" | base64 -d > "$client_key_file"
    
    # Add the cluster to the merged config
    kubectl --kubeconfig="$output_file" config set-cluster "$cluster_name" --server="$server" --certificate-authority="$ca_file" --embed-certs=true
    
    # Add the user to the merged config
    kubectl --kubeconfig="$output_file" config set-credentials "$new_user_name" --client-certificate="$client_cert_file" --client-key="$client_key_file" --embed-certs=true
    
    # Add the context to the merged config
    kubectl --kubeconfig="$output_file" config set-context "$cluster_name" --cluster="$cluster_name" --user="$new_user_name"
    
    # Set the current context if this is the first file
    if [[ $(kubectl --kubeconfig="$output_file" config current-context 2>/dev/null || echo "") == "" ]]; then
        kubectl --kubeconfig="$output_file" config use-context "$cluster_name"
    fi
    
    log "INFO" "Added cluster $cluster_name with user $new_user_name from $input_file to merged config"
}

# Process each input file
log "INFO" "Starting kubeconfig merge process"
log "INFO" "Output file: $output_file"
log "DEBUG" "Input files: ${input_files[*]}"

# Process each input file
for input_spec in "${input_files[@]}"; do
    process_kubeconfig "$input_spec" "$output_file"
done

log "INFO" "Successfully merged ${#input_files[@]} kubeconfig files into: $output_file"

# Display summary of the merged kubeconfig
log "INFO" "Merged kubeconfig summary:"
kubectl --kubeconfig="$output_file" config get-contexts

exit 0
