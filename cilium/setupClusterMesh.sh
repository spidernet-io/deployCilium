#!/bin/bash

:<<EOF
# ./setupClusterMesh.sh  Cluster1ApiServerIP[:Cluster1Name] Cluster2ApiServerIP[:Cluster2Name] ... "


实现：
    1 不同集群间的 pod ip 相互访问  Pod IP  （ ipv4 和 ipv6 ）

    2 不同集群间，可以访问 对方的 service cluster ip  ， 实现跨集群访问服务
       不同集群的 pod 也可以 共享一个 service， 实现服务的跨集群 高可用
    甚至，包括 场景 split a service’s pods into e.g. two groups, with the first half scheduled to cluster1, and the second half to cluster2，If you have scattered your pods of a same service into different clusters , and you would like service discovery/load-balancing or enforce network policies on these services, you may need clustermesh.

    3 跨集群间的 服务发现 Transparent service discovery with standard Kubernetes services and coredns/kube-dns.

    4 不同集群间的网络policy（只支持部分类型的policy）

    5 跨集群间的流量加密Transparent encryption for all communication between nodes in the local cluster as well as across cluster boundaries.

    6 hubble 可观性 能跨集群 查看 （暂时没测试出来）

     7 它支持 enableEndpointSliceSynchronization ， 因此， ingress 应该可以实现 跨集群 转发 

     8 集群之间是 点对点 peer 的， 因此， 如果大于 3 个集群的情况下， 两两 集群之间 都要相互 peer 


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

#===================================  get input clusters ==========================

# Check if there are any arguments
if [ $# -eq 0 ]; then
    echo "Error: No cluster parameters provided"
    echo "Usage: $0 Cluster1ApiServerIP[:Cluster1Name] Cluster2ApiServerIP[:Cluster2Name] ..."
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
    
    # Parse IP:Port[:Name]
    if [[ "$cluster_param" =~ ^([^:]+):([^:]+)(:(.+))?$ ]]; then
        # Extract components
        ip=${BASH_REMATCH[1]}
        name=${BASH_REMATCH[4]}
        
        # If name is not provided, use a default name based on cluster number
        if [ -z "$name" ]; then
            name="cluster${cluster_count}"
        fi
        
        # Store in arrays
        cluster_ips[$cluster_count]=$ip
        cluster_names[$cluster_count]=$name
        
        # Also create individual variables for each cluster
        # Format: cluster1_ip, cluster1_port, cluster1_name, cluster2_ip, etc.
        declare "cluster${cluster_count}_ip=$ip"
        declare "cluster${cluster_count}_name=$name"
        
        # Log the parsed information
        #echo "INFO: Cluster $cluster_count parsed:"
        #echo "  - IP: $ip"
        #echo "  - Name: $name"
    else
        echo "ERROR: Invalid cluster parameter format: $cluster_param"
        echo "Expected format: IP[:Name]"
        exit 1
    fi
done

# Log summary
echo "INFO: Total clusters parsed: $cluster_count"

# Example of how to use the parsed variables
for ((i=1; i<=cluster_count; i++)); do
    echo "Cluster $i:"
    echo "  - IP: ${cluster_ips[$i]}"
    echo "  - Name: ${cluster_names[$i]}"
    
    # Alternative way to access using dynamic variable names
    # ip_var="cluster${i}_ip"
    # name_var="cluster${i}_name"
    # echo "  Using variable names:"
    # echo "  - IP: ${!ip_var}"
    # echo "  - Name: ${!name_var}"
done

# Now you can use these variables in your script
# For example: ${cluster1_ip}, ${cluster1_name}, etc.

if (( cluster_count < 2 )); then
    echo "Error: At least 2 clusters are required"
    exit 1
fi

echo "---------------------------- generate kubeconfig for all clusters -------------------------------------"

PARAMETERS=""
for ((i=1; i<=cluster_count; i++)); do
    echo "get kubecon of Cluster $i "
    scp root@${cluster_ips[$i]}:/root/.kube/config ${CONFIG_DIR}/${cluster_names[$i]}
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



echo "---------------------------- connect cilium in all clusters-------------------------------------"

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

# full mesh 拓扑
echo "--------------- connect all clusters with full mesh topology "
for ((i=1; i<=cluster_count; i++)); do
    for ((j=i+1; j<=cluster_count; j++)); do
        echo "connect ${cluster_names[$j]} to ${cluster_names[$i]} "
        cilium clustermesh connect --context ${cluster_names[$i]} --destination-context ${cluster_names[$j]}
    done
done

# 星状拓扑
# for ((i=2; i<=cluster_count; i++)); do
#     echo "--------------- connect cilium in ${cluster_names[1]} and ${cluster_names[$i]}"
#     cilium clustermesh connect --context ${cluster_names[$i]} --destination-context ${cluster_names[1]}
# done

sleep 30
echo "============== finished ==================="

#chmod +x ${CURRENT_DIR_PATH}/showClusterMesh.sh
#${CURRENT_DIR_PATH}/showClusterMesh.sh

