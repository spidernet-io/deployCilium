#!/bin/bash

:<<eof
安装要求 
https://docs.cilium.io/en/latest/operations/system_requirements/#systemd-based-distributions

注意，当要使用 clustermesh 时， 每个集群的这些参数必须不能相同：  CLUSTERMESH_APISERVER_NODEPORT  CLUSTER_NAME CLUSTER_ID

注意：kube-controller-manager 默认 为每个node 分配 ipv4 block=24 ， ipv6 block=64.
因为 kubeadm没有提供相关选项，所以，pod ipv4 cidr 的掩码要大于 24 ， pod ipv6 pod 掩码要大于64

POD_v4CIDR="172.70.0.0/16" \
    POD_v4Block="24" \
    ENABLE_IPV6="true" \
    POD_v6CIDR="fc07:1::/48" \
    POD_v6Block="64" \
    CLUSTER_NAME="cluster1" \
    CLUSTER_ID="10" \
    K8S_API_IP="172.16.1.11" \
    K8S_API_PORT="6443" \
    HUBBLE_WEBUI_NODEPORT_PORT="30000" \
    CLUSTERMESH_APISERVER_NODEPORT="31000" \
    ./setup.sh

eof

CURRENT_FILENAME=$( basename $0 )
CURRENT_DIR_PATH=$(cd $(dirname $0); pwd)

set -x
set -o errexit
set -o nounset
set -o pipefail

#=====================   version
INSTANCE_NAME=${INSTANCE_NAME:-"cilium"}
NAMESPACE=${NAMESPACE:-"kube-system"}

source ${CURRENT_DIR_PATH}/version.sh

DAOCLOUD_REPO=${DAOCLOUD_REPO:-"m.daocloud."}


#===================== configure


CHART_PATH="${CURRENT_DIR_PATH}/chart/cilium-${CILIUM_VERSION}.tgz"
[ -f "${CHART_PATH}" ] || { echo "error, does not find ${CHART_PATH}" ; exit 1 ; }
echo "use local chart ${CHART_PATH}"



POD_v4CIDR=${POD_v4CIDR:-"172.70.0.0/16"}
POD_v4Block=${POD_v4Block:-24}

ENABLE_IPV6=${ENABLE_IPV6:-"false"}
POD_v6CIDR=${POD_v6CIDR:-"fc07:1::/48"}
POD_v6Block=${POD_v6Block:-64}

CLUSTER_NAME=${CLUSTER_NAME:-"cluster1"}
#1-255
CLUSTER_ID=${CLUSTER_ID:-"10"}

# need when kube proxy replacement
# api server的地址，务必是 devices中覆盖到的 网卡！！
K8S_API_IP=${K8S_API_IP:-"172.16.1.11"}
K8S_API_PORT=${K8S_API_PORT:-"6443"}

HUBBLE_WEBUI_NODEPORT_PORT=${HUBBLE_WEBUI_NODEPORT_PORT:-"30446"}
CLUSTERMESH_APISERVER_NODEPORT=${CLUSTERMESH_APISERVER_NODEPORT:-"30100"}

ENABLE_gatewayAPI=${ENABLE_gatewayAPI:-"true"}


echo "INSTANCE_NAME=${INSTANCE_NAME}"
echo "NAMESPACE=${NAMESPACE}"
echo "POD_v4CIDR=${POD_v4CIDR}"
echo "POD_v4Block=${POD_v4Block}"
echo "POD_v6CIDR=${POD_v6CIDR}"
echo "POD_v6Block=${POD_v6Block}"
echo "CLUSTER_NAME=${CLUSTER_NAME}"
echo "CLUSTER_ID=${CLUSTER_ID}"
echo "K8S_API_IP=${K8S_API_IP}"
echo "K8S_API_PORT=${K8S_API_PORT}"
echo "HUBBLE_WEBUI_NODEPORT_PORT=${HUBBLE_WEBUI_NODEPORT_PORT}"

#===================  install CLI 

cp  ${CURRENT_DIR_PATH}/binary/hubble-linux-amd64-${HUBBLE_CLI_VERSION}.tar.gz /tmp/hubble-linux-amd64.tar.gz
( 
    cd /tmp 
    tar xzvf hubble-linux-amd64.tar.gz
    chmod +x hubble
    cp hubble /usr/sbin/
)

cp ${CURRENT_DIR_PATH}/binary/cilium-linux-amd64-${CILIUM_CLI_VERSION}.tar.gz /tmp/cilium-linux-amd64.tar.gz 
( 
    cd /tmp
    tar xzvf cilium-linux-amd64.tar.gz
    chmod +x cilium
    mv cilium /usr/sbin/
)


#============================================== 

if [ "$ENABLE_gatewayAPI" == "true" ] && ( ! kubectl get gatewayclasses &>/dev/null ) ;then
    echo "apply gateway api from remote"
    kubectl apply -f "${CURRENT_DIR_PATH}/gateway-api/*"
fi


#accelerate image
HELM_OPTIONS=""
HELM_OPTIONS+="\
  --set image.repository=quay.${DAOCLOUD_REPO}io/cilium/cilium \
  --set image.useDigest=false \
  --set certgen.image.repository=quay.${DAOCLOUD_REPO}io/cilium/certgen \
  --set hubble.relay.image.repository=quay.${DAOCLOUD_REPO}io/cilium/hubble-relay \
  --set hubble.relay.image.useDigest=false \
  --set hubble.ui.backend.image.repository=quay.${DAOCLOUD_REPO}io/cilium/hubble-ui-backend \
  --set hubble.ui.frontend.image.repository=quay.${DAOCLOUD_REPO}io/cilium/hubble-ui \
  --set envoy.image.repository=quay.${DAOCLOUD_REPO}io/cilium/cilium-envoy  \
  --set envoy.image.useDigest=false  \
  --set operator.image.repository=quay.${DAOCLOUD_REPO}io/cilium/operator  \
  --set operator.image.useDigest=false  \
  --set nodeinit.image.repository=quay.${DAOCLOUD_REPO}io/cilium/startup-script \
  --set preflight.image.repository=quay.${DAOCLOUD_REPO}io/cilium/cilium \
  --set preflight.image.useDigest=false \
  --set clustermesh.apiserver.image.repository=quay.${DAOCLOUD_REPO}io/cilium/clustermesh-apiserver \
  --set clustermesh.apiserver.image.useDigest=false \
  --set authentication.mutual.spire.install.agent.repository=ghcr.${DAOCLOUD_REPO}io/spiffe/spire-agent \
  --set authentication.mutual.spire.install.agent.useDigest=false \
  --set authentication.mutual.spire.install.server.repository=ghcr.${DAOCLOUD_REPO}io/spiffe/spire-server \
  --set authentication.mutual.spire.install.server.useDigest=false  "

HELM_OPTIONS+="\
  --set clustermesh.apiserver.service.nodePort=${CLUSTERMESH_APISERVER_NODEPORT}  \
  --set hubble.ui.service.nodePort=${HUBBLE_WEBUI_NODEPORT_PORT} \
  --set gatewayAPI.enabled=${ENABLE_gatewayAPI} \
  --set cluster.name=${CLUSTER_NAME}  \
  --set cluster.id=${CLUSTER_ID}  \
"

HELM_OPTIONS+="\
  --set ipv6.enabled=${ENABLE_IPV6}  \
  --set enableIPv6Masquerade=${ENABLE_IPV6} \
"

HELM_OPTIONS+="\
  --set ipam.mode=cluster-pool \
  --set ipam.operator.clusterPoolIPv4PodCIDRList=${POD_v4CIDR} \
  --set ipam.operator.clusterPoolIPv4MaskSize=${POD_v4Block} \
  --set ipam.operator.clusterPoolIPv6PodCIDRList=${POD_v6CIDR} \
  --set ipam.operator.clusterPoolIPv6MaskSize=${POD_v6Block} \
"

HELM_OPTIONS+="\
  --set k8sServiceHost=${K8S_API_IP} \
  --set k8sServicePort=${K8S_API_PORT} \
"


helm install  cilium ${CHART_PATH} --debug  --atomic --version $CILIUM_VERSION  --timeout 20m \
  --namespace ${NAMESPACE}  \
  -f ${CURRENT_DIR_PATH}/values.yaml \
  ${HELM_OPTIONS}
