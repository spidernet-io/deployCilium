#!/bin/bash

:<<EOF
在运行机器上，有两种方式运行本脚本：

方式：通过本地配置文件路径方式
    如果已经在本地有各个集群的 kubeconfig 文件，可以直接指定这些文件的路径
    运行如下命令，它会使用这些本地配置文件，然后在本地生成一份聚合的 /root/.kube/config，对这些集群实现互联
    其中， Cluster1ConfigPath 是 集群1 的 kubeconfig 文件路径 。 Cluster1Name 是自定义的一个集群唯一名字

    ./setupClusterMesh.sh  Cluster1ConfigPath[:Cluster1Name] Cluster2ConfigPath[:Cluster2Name] [Cluster3ConfigPath[:Cluster3Name]] ... "
    # example: ./setupClusterMesh.sh  /path/to/cluster1/config:/cluster1  /path/to/cluster2/config:/cluster2


https://docs.cilium.io/en/latest/network/clustermesh/clustermesh/
要求：
    （1）集群运行在 Encapsulation 后者 Native-Routing mode ( native routing 模式的集群，需要在路由器上 安装好 pod 路由 ) 
    (2) PodCIDR   and all nodes 的 子网不冲突 , clusterIP 可以重叠
    (3) 多集群间的所有 node 都要能直接互通
    (4) 集群互联 默认 最多 255 ，  通过牺牲  cluster-local identities 也可扩展到 511 个 
    (5) 不同集群的 clustermesh 的 nodePort 不能使用相同端口
        apiserver:
            service:
            type: NodePort
            # WARNING: make sure to configure a different NodePort in each cluster if
            # kube-proxy replacement is enabled, as Cilium is currently affected by a known bug (#24692) when NodePorts are handled by the KPR implementation
            nodePort: ${CLUSTERMESH_APISERVER_NODEPORT}

EOF

#set -x
set -o errexit
set -o nounset
set -o pipefail

CURRENT_FILENAME=$( basename $0 )
CURRENT_DIR_PATH=$(cd $(dirname $0); pwd)

CONFIG_DIR=${CONFIG_DIR:-"/root/clustermesh"}
CONFIG_PATH=${CONFIG_PATH:-"${CONFIG_DIR}/config"}

mkdir -p ${CONFIG_DIR} || true

#===================================  分析命令行参数 ==========================

# Check if there are any arguments
if [ $# -eq 0 ]; then
    echo "Error: No cluster parameters provided"
    echo "Usage: $0 Cluster1ApiServerIP[:Cluster1Name] Cluster2ApiServerIP[:Cluster2Name] ..."
    echo "   or: $0 Cluster1ConfigPath[:Cluster1Name] Cluster2ConfigPath[:Cluster2Name] ..."
    exit 1
fi

# Initialize cluster counter
cluster_count=0

# Loop through all arguments
for cluster_param in "$@"; do
    # Increment cluster counter
    (( cluster_count = cluster_count + 1 ))
    
    # Debug log
    # echo "DEBUG: Processing cluster parameter: $cluster_param"
    
    # Parse parameter: could be either IP[:Name] or ConfigPath[:Name]
    if [[ "$cluster_param" =~ ^([^:]+)(:(.+))?$ ]]; then
        # Extract components
        param=${BASH_REMATCH[1]}
        name=${BASH_REMATCH[3]}
        
        # If name is not provided, use a default name based on cluster number
        if [ -z "$name" ]; then
            name="cluster${cluster_count}"
        fi
        
        # Store in arrays
        cluster_params[$cluster_count]=$param
        cluster_names[$cluster_count]=$name
        
        # Also create individual variables for each cluster
        declare "cluster${cluster_count}_param=$param"
        declare "cluster${cluster_count}_name=$name"
        
        # Check if the parameter is a file path or an IP address
        if [ -f "$param" ]; then
            # It's a file path
            cluster_types[$cluster_count]="file"
            echo "INFO: Parameter '$param' detected as a config file path"
        else
            # It's an IP address
            cluster_types[$cluster_count]="ip"
            echo "INFO: Parameter '$param' detected as an IP address"
        fi
        
    else
        echo "ERROR: Invalid cluster parameter format: $cluster_param"
        echo "Expected format: IP[:Name] or ConfigPath[:Name]"
        exit 1
    fi
done

# Log summary
echo "INFO: Total clusters parsed: $cluster_count"

# Example of how to use the parsed variables
for ((i=1; i<=cluster_count; i++)); do
    echo "Cluster $i:"
    echo "  - Parameter: ${cluster_params[$i]}"
    echo "  - Type: ${cluster_types[$i]}"
    echo "  - Name: ${cluster_names[$i]}"
    
done

# Now you can use these variables in your script
# For example: ${cluster1_ip}, ${cluster1_name}, etc.

if (( cluster_count < 2 )); then
    echo "Error: At least 2 clusters are required"
    exit 1
fi


echo "---------------------------- 生成一个聚合的 kubeconfig 文件 -------------------------------------"

PARAMETERS=""
for ((i=1; i<=cluster_count; i++)); do
    echo "get kubecon of Cluster $i "
    if [ "${cluster_types[$i]}" == "ip" ]; then
        # If it's an IP address, use SSH to copy the kubeconfig
        scp root@${cluster_params[$i]}:/root/.kube/config ${CONFIG_DIR}/${cluster_names[$i]}
    else
        # If it's a file path, copy the file directly
        # Check if source and destination are the same file
        if [ "$(realpath ${cluster_params[$i]})" != "$(realpath ${CONFIG_DIR}/${cluster_names[$i]})" ]; then
            cp ${cluster_params[$i]} ${CONFIG_DIR}/${cluster_names[$i]}
        else
            echo "INFO: Source and destination are the same file for ${cluster_names[$i]}, skipping copy"
        fi
    fi
    PARAMETERS="${PARAMETERS} ${CONFIG_DIR}/${cluster_names[$i]}:${cluster_names[$i]}"
done

chmod +x ${CURRENT_DIR_PATH}/tools/generateKubeConfig.sh
${CURRENT_DIR_PATH}/tools/generateKubeConfig.sh  ${PARAMETERS} -o ${CONFIG_PATH}

export KUBECONFIG=${CONFIG_PATH}

# test
kubectl --kubeconfig=${CONFIG_PATH} config get-contexts
for ((i=1; i<=cluster_count; i++)); do
    echo "check ${cluster_names[$i]}"
    kubectl config use-context ${cluster_names[$i]}
    kubectl get pod 
done



echo "---------------------------- 把所有集群的 cilium 互联一起 -------------------------------------"

echo "--------------- enable clustermesh in all clusters "
for ((i=1; i<=cluster_count; i++)); do
    echo "enable clustermesh in ${cluster_names[$i]}"
    cilium clustermesh enable  --service-type NodePort  --context ${cluster_names[$i]} 
    cilium clustermesh status --context ${cluster_names[$i]} --wait
done

echo "--------------- sync a same secret in all clusters "
for ((i=2; i<=cluster_count; i++)); do
        echo "copy CA tls from ${cluster_names[1]} to ${cluster_names[$i]}"
        kubectl --context ${cluster_names[$i]} delete secret -n kube-system cilium-ca || true
        kubectl --context=${cluster_names[1]} get secret -n kube-system cilium-ca -o yaml | kubectl --context=${cluster_names[$i]} apply -f -
done

echo "--------------- connect all clusters with full mesh topology "
for ((i=1; i<=cluster_count; i++)); do
    for ((j=i+1; j<=cluster_count; j++)); do
        echo "connect ${cluster_names[$j]} to ${cluster_names[$i]} "
        cilium clustermesh connect --context ${cluster_names[$i]} --destination-context ${cluster_names[$j]}
    done
done



