#!/bin/bash

<<EOF
# https://docs.cilium.io/en/latest/operations/troubleshooting/#cluster-mesh-troubleshooting

注意：
(1) 不同集群的 clustermesh 的 nodePort 不能使用相同端口
  apiserver:
    service:
      type: NodePort
      # WARNING: make sure to configure a different NodePort in each cluster if
      # kube-proxy replacement is enabled, as Cilium is currently affected by a known bug (#24692) when NodePorts are handled by the KPR implementation
      nodePort: ${CLUSTERMESH_APISERVER_NODEPORT}

EOF


 

CILIUM_NS=${CILIUM_NS:-"kube-system"}
CONFIG_DIR=${CONFIG_DIR:-"/root/clustermesh"}


export KUBECONFIG="${CONFIG_DIR}/config"
[ -f "${CONFIG_DIR}/config" ] || { echo "kubeconfig ${KUBECONFIG} is not found"; exit 1; }

echo "clusters: "
kubectl  config get-contexts -o name
echo ""

# Get all available clusters from the kubeconfig
CLUSTERS=($(kubectl --kubeconfig=${KUBECONFIG} config get-contexts -o name))
if [ ${#CLUSTERS[@]} -eq 0 ]; then
    echo "No clusters found in kubeconfig ${KUBECONFIG}"
    exit 1
fi

echo "Found ${#CLUSTERS[@]} clusters in kubeconfig: ${CLUSTERS[*]}"
echo ""


echo "===================================== hubble Status  ==================================="

if ! hubble status &>/dev/null ; then
    cilium hubble port-forward &
    sleep 3
fi 

echo ""
echo "hubble status"
hubble status

echo ""
echo "hubble list  nodes"
hubble list  nodes



# Show clustermesh status for each cluster
echo ""
echo "===================================== ClusterMesh Status Per Cluster ==================================="
for CLUSTER in "${CLUSTERS[@]}"; do
    echo ""
    echo "--------- check clusterMesh status in ${CLUSTER} "
    cilium clustermesh status --context ${CLUSTER} || true
    echo ""
done





echo ""
echo "===================================== clusterMesh export address ==================================="
echo ""


echo "注意！每个集群的 nodePort 号不能相同，否则会冲突，多集群连接会失败"
echo ""

# Show clustermesh export addresses for each cluster
for CLUSTER in "${CLUSTERS[@]}"; do
    echo ""
    echo "${CLUSTER} export address:"
    kubectl get service --context ${CLUSTER} -n ${CILIUM_NS}  clustermesh-apiserver
    echo ""
done



echo ""
echo "===================================== show status of each agent in all clusters ==================================="
echo ""

# Show status of each agent in each cluster
for CLUSTER in "${CLUSTERS[@]}"; do
    echo ""
    echo "------------------- Agents in ${CLUSTER} -------------------"
    echo ""
    
    kubectl config use-context ${CLUSTER}
    AGENT_PODS=$( kubectl get pods -n ${CILIUM_NS} -l app.kubernetes.io/name=cilium-agent | sed '1d' | awk '{ print $1}' )

    if [ -z "$AGENT_PODS" ]; then
        echo "No Cilium agent pods found in ${CLUSTER}"
        continue
    fi
    
    for POD in ${AGENT_PODS} ; do
        echo ""
        if kubectl get pod -n ${CILIUM_NS} ${POD} | grep Running &>/dev/null ; then
            echo "-------------- agent pod ${POD} in ${CLUSTER}: Running "
            kubectl exec -it -n ${CILIUM_NS}  ${POD} -c cilium-agent -- cilium-dbg troubleshoot clustermesh
        else 
            echo "-------------- agent pod ${POD} in ${CLUSTER}: Not Running "
        fi
        echo ""
    done
done


echo ""
echo "===================================== show status of clustermesh in all clusters ==================================="
echo ""

# Show status of clustermesh in each cluster
for CLUSTER in "${CLUSTERS[@]}"; do
    echo ""
    
    kubectl config use-context ${CLUSTER}
    CLUSTERMESH_PODS=$( kubectl get -n ${CILIUM_NS} pod -l app.kubernetes.io/name=clustermesh-apiserver | sed '1d' | awk '{ print $1}' )
    
    if [ -z "$CLUSTERMESH_PODS" ]; then
        echo "No ClusterMesh API server pods found in ${CLUSTER}"
        continue
    fi
    
    for POD in ${CLUSTERMESH_PODS} ; do
        echo ""
        if kubectl get pod -n ${CILIUM_NS} ${POD} | grep Running &>/dev/null ; then
            echo "-------------- clustermesh pod ${POD} in ${CLUSTER}: Running "
            kubectl exec -it -n ${CILIUM_NS}  ${POD}  -c kvstoremesh -- /usr/bin/clustermesh-apiserver kvstoremesh-dbg troubleshoot
        else 
            echo "-------------- clustermesh pod ${POD} in ${CLUSTER}: Not Running "
        fi
        echo ""
    done
done
