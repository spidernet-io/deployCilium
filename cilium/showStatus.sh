#!/bin/bash


CILIUM_NS="kube-system"
AGENT_PODS=$( kubectl get pods -n ${CILIUM_NS} -l app.kubernetes.io/name=cilium-agent | sed '1d' | awk '{ print $1}' )


echo "===================================== cilium pod ==================================="
kubectl get pods -n ${CILIUM_NS} -l app.kubernetes.io/part-of=cilium

echo ""
echo "===================================== cilium summary ==================================="
cilium status


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


echo ""
echo "hubble WEBUI address:"
kubectl get service -n ${CILIUM_NS} hubble-ui


echo ""
echo "clusterMesh export address:"
kubectl get service -n ${CILIUM_NS}  clustermesh-apiserver

echo ""
echo "===================================== show policy enforcement mode ==================================="
kubectl exec -it -n kube-system daemonset/cilium -c cilium-agent --     cilium config | grep PolicyEnforcement
echo ""
echo "              default: 缺省放行"
echo "              always:  缺省拒绝"
echo "              never:   无论如何，都是拒绝"


echo ""
echo "===================================== show policy ==================================="
kubectl get ciliumnetworkpolicies -A
kubectl get CiliumClusterwideNetworkPolicy
kubectl get networkpolicy -A



echo ""
echo "===================================== show connectivity status of each agent ==================================="
echo ""
for POD in ${AGENT_PODS} ; do
    echo ""
    if kubectl get pod -n ${CILIUM_NS} ${POD} | grep Running &>/dev/null ; then
        echo "-------------- agent pod ${POD} : Running "
        kubectl -n ${CILIUM_NS} exec -ti ${POD}  -- cilium-health status --verbose
    else 
        echo "-------------- agent pod ${POD} : Not Running "
    fi
    echo ""
done


echo ""
echo "===================================== show status of each agent ==================================="
echo ""
for POD in ${AGENT_PODS} ; do
    echo ""
    if kubectl get pod -n ${CILIUM_NS} ${POD} | grep Running &>/dev/null ; then
        echo "-------------- agent pod ${POD} : Running "
        kubectl -n ${CILIUM_NS} exec -ti ${POD}  -- cilium-dbg status
    else 
        echo "-------------- agent pod ${POD} : Not Running "
    fi
    echo ""
done




echo ""
echo "===================================== show error log of each agent ==================================="
echo ""
for POD in ${AGENT_PODS} ; do
    echo ""
    if kubectl get pod -n ${CILIUM_NS} ${POD} | grep Running &>/dev/null ; then
        echo "-------------- agent pod ${POD} : Running "
        kubectl logs -n ${CILIUM_NS} ${POD} | grep -i "error="
    else 
        echo "-------------- agent pod ${POD} : Not Running "
    fi
    echo ""
done



