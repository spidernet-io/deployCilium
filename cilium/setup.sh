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
    ENABLE_INTEGRATE_ISTIO="false" \
    ./setup.sh

# 渲染 Helm manifests，但不修改集群
HELM_DRY_RUN="true" ./setup.sh

# 打印使用同一组 Helm values/options 渲染出的镜像列表
PRINT_IMAGES="true" ./setup.sh

# 将 Helm 渲染出的镜像拉取到本地容器运行时
PREPULL_IMAGES="true" ./setup.sh

# 拉取镜像，重新标记到离线镜像仓库名下，然后推送
PREPULL_IMAGES="true" OFFLINE_REGISTRY="registry.example.com" ./setup.sh

# 安装到离线集群，并从离线镜像仓库拉取镜像。
# 脚本会自动为每个 cilium 镜像仓库添加 OFFLINE_REGISTRY 前缀，
# 因此不需要手动传入 EXTRA_HELM_OPTIONS。
OFFLINE_REGISTRY="registry.example.com" ./setup.sh

# 使用上游镜像仓库，而不是 DaoCloud 镜像
DAOCLOUD_IMAGE_REPO="false" ./setup.sh

eof

CURRENT_FILENAME=$( basename $0 )
CURRENT_DIR_PATH=$(cd $(dirname $0); pwd)

set -x
set -o errexit
set -o nounset
set -o pipefail

if ! which helm &>/dev/null ; then
    echo "请安装 CLI：helm"
    exit 1
fi

#=====================   版本
INSTANCE_NAME=${INSTANCE_NAME:-"cilium"}
NAMESPACE=${NAMESPACE:-"kube-system"}
HELM_DRY_RUN=${HELM_DRY_RUN:-"false"}
PRINT_IMAGES=${PRINT_IMAGES:-"false"}
PREPULL_IMAGES=${PREPULL_IMAGES:-"false"}
DAOCLOUD_IMAGE_REPO=${DAOCLOUD_IMAGE_REPO:-"true"}
# OFFLINE_REGISTRY 是 fire-source/离线镜像仓库。设置后，脚本会在实际
# Helm 安装（以及 dry-run）时自动为每个 cilium 镜像仓库添加此前缀，
# 因此用户不需要手动传入很长的 EXTRA_HELM_OPTIONS。OFFLINE_GLOBAL_REGISTRY
# 保留为废弃别名，用于向后兼容。
OFFLINE_REGISTRY=${OFFLINE_REGISTRY:-"${OFFLINE_GLOBAL_REGISTRY:-""}"}

source ${CURRENT_DIR_PATH}/version.sh

if [ "${DAOCLOUD_IMAGE_REPO}" == "true" ]; then
    QUAY_IMAGE_REPO="quay.m.daocloud.io"
    GHCR_IMAGE_REPO="ghcr.m.daocloud.io"
else
    QUAY_IMAGE_REPO="quay.io"
    GHCR_IMAGE_REPO="ghcr.io"
fi

# 仅在真实安装 / dry-run 时添加离线仓库前缀。PRINT_IMAGES 和 PREPULL_IMAGES
# 必须保留公共仓库路径，这样才能先从公共仓库拉取，再重新标记为
# ${OFFLINE_REGISTRY}/<original-image>，与安装时这里使用的前缀路径一致。
if [ -n "${OFFLINE_REGISTRY}" ] \
    && [ "${PRINT_IMAGES}" != "true" ] \
    && [ "${PREPULL_IMAGES}" != "true" ]; then
    QUAY_IMAGE_REPO="${OFFLINE_REGISTRY}/${QUAY_IMAGE_REPO}"
    GHCR_IMAGE_REPO="${OFFLINE_REGISTRY}/${GHCR_IMAGE_REPO}"
fi


#===================== 配置


CHART_PATH="${CURRENT_DIR_PATH}/chart/cilium-${CILIUM_VERSION}.tgz"
[ -f "${CHART_PATH}" ] || { echo "错误，未找到 ${CHART_PATH}" ; exit 1 ; }
echo "使用本地 chart ${CHART_PATH}" >&2



POD_v4CIDR=${POD_v4CIDR:-"172.70.0.0/16"}
POD_v4Block=${POD_v4Block:-24}

ENABLE_IPV6=${ENABLE_IPV6:-"false"}
POD_v6CIDR=${POD_v6CIDR:-"fc07:1::/48"}
POD_v6Block=${POD_v6Block:-64}

CLUSTER_NAME=${CLUSTER_NAME:-"cluster1"}
#1-255
CLUSTER_ID=${CLUSTER_ID:-"10"}

# kube proxy replacement 需要此配置
# api server的地址，务必是 devices中覆盖到的 网卡！！
K8S_API_IP=${K8S_API_IP:-"172.16.1.11"}
K8S_API_PORT=${K8S_API_PORT:-"6443"}

HUBBLE_WEBUI_NODEPORT_PORT=${HUBBLE_WEBUI_NODEPORT_PORT:-"30446"}
CLUSTERMESH_APISERVER_NODEPORT=${CLUSTERMESH_APISERVER_NODEPORT:-"30100"}

ENABLE_gatewayAPI=${ENABLE_gatewayAPI:-"true"}

# https://docs.cilium.io/en/latest/network/servicemesh/istio/
ENABLE_INTEGRATE_ISTIO=${ENABLE_INTEGRATE_ISTIO:-"false"}


echo "INSTANCE_NAME=${INSTANCE_NAME}" >&2
echo "NAMESPACE=${NAMESPACE}" >&2
echo "POD_v4CIDR=${POD_v4CIDR}" >&2
echo "POD_v4Block=${POD_v4Block}" >&2
echo "POD_v6CIDR=${POD_v6CIDR}" >&2
echo "POD_v6Block=${POD_v6Block}" >&2
echo "CLUSTER_NAME=${CLUSTER_NAME}" >&2
echo "CLUSTER_ID=${CLUSTER_ID}" >&2
echo "K8S_API_IP=${K8S_API_IP}" >&2
echo "K8S_API_PORT=${K8S_API_PORT}" >&2
echo "HUBBLE_WEBUI_NODEPORT_PORT=${HUBBLE_WEBUI_NODEPORT_PORT}" >&2
echo "ENABLE_INTEGRATE_ISTIO=${ENABLE_INTEGRATE_ISTIO}" >&2
echo "HELM_DRY_RUN=${HELM_DRY_RUN}" >&2
echo "PRINT_IMAGES=${PRINT_IMAGES}" >&2
echo "PREPULL_IMAGES=${PREPULL_IMAGES}" >&2
echo "OFFLINE_REGISTRY=${OFFLINE_REGISTRY}" >&2
echo "DAOCLOUD_IMAGE_REPO=${DAOCLOUD_IMAGE_REPO}" >&2
echo "QUAY_IMAGE_REPO=${QUAY_IMAGE_REPO}" >&2
echo "GHCR_IMAGE_REPO=${GHCR_IMAGE_REPO}" >&2

if [ "${PREPULL_IMAGES}" == "true" ]; then
    if ! which docker &>/dev/null ; then
        echo "请安装 CLI：docker"
        exit 1
    fi
fi

if [ "${HELM_DRY_RUN}" != "true" ] && [ "${PRINT_IMAGES}" != "true" ] && [ "${PREPULL_IMAGES}" != "true" ]; then
    if ! which kubectl &>/dev/null ; then
        echo "请安装 CLI：kubectl"
        exit 1
    fi
fi

#===================  安装 CLI

if [ "${HELM_DRY_RUN}" != "true" ] && [ "${PRINT_IMAGES}" != "true" ] && [ "${PREPULL_IMAGES}" != "true" ]; then
    cp  ${CURRENT_DIR_PATH}/binary/hubble-cli-${HUBBLE_CLI_VERSION}-linux-amd64.tar.gz /tmp/hubble-cli-linux-amd64.tar.gz
    (
        cd /tmp
        tar xzvf hubble-cli-linux-amd64.tar.gz
        chmod +x hubble
        sudo cp hubble /usr/sbin/
    )

    cp ${CURRENT_DIR_PATH}/binary/cilium-cli-${CILIUM_CLI_VERSION}-linux-amd64.tar.gz /tmp/cilium-cli-linux-amd64.tar.gz
    (
        cd /tmp
        tar xzvf cilium-cli-linux-amd64.tar.gz
        chmod +x cilium
        sudo mv cilium /usr/sbin/
    )
fi


#============================================== 

if [ "${HELM_DRY_RUN}" != "true" ] && [ "${PRINT_IMAGES}" != "true" ] && [ "${PREPULL_IMAGES}" != "true" ] && \
    [ "$ENABLE_gatewayAPI" == "true" ] && ( ! kubectl get gatewayclasses &>/dev/null ) ;then
    echo "从远端应用 Gateway API"
    kubectl apply -f "${CURRENT_DIR_PATH}/gateway-api/*"
fi


# 镜像加速
HELM_OPTIONS=""
HELM_OPTIONS+="\
  --set image.repository=${QUAY_IMAGE_REPO}/cilium/cilium \
  --set image.useDigest=false \
  --set certgen.image.repository=${QUAY_IMAGE_REPO}/cilium/certgen \
  --set hubble.relay.image.repository=${QUAY_IMAGE_REPO}/cilium/hubble-relay \
  --set hubble.relay.image.useDigest=false \
  --set hubble.ui.backend.image.repository=${QUAY_IMAGE_REPO}/cilium/hubble-ui-backend \
  --set hubble.ui.frontend.image.repository=${QUAY_IMAGE_REPO}/cilium/hubble-ui \
  --set envoy.image.repository=${QUAY_IMAGE_REPO}/cilium/cilium-envoy  \
  --set envoy.image.useDigest=false  \
  --set operator.image.repository=${QUAY_IMAGE_REPO}/cilium/operator  \
  --set operator.image.useDigest=false  \
  --set nodeinit.image.repository=${QUAY_IMAGE_REPO}/cilium/startup-script \
  --set preflight.image.repository=${QUAY_IMAGE_REPO}/cilium/cilium \
  --set preflight.image.useDigest=false \
  --set clustermesh.apiserver.image.repository=${QUAY_IMAGE_REPO}/cilium/clustermesh-apiserver \
  --set clustermesh.apiserver.image.useDigest=false \
  --set authentication.mutual.spire.install.agent.repository=${GHCR_IMAGE_REPO}/spiffe/spire-agent \
  --set authentication.mutual.spire.install.agent.useDigest=false \
  --set authentication.mutual.spire.install.server.repository=${GHCR_IMAGE_REPO}/spiffe/spire-server \
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

if [ "${ENABLE_INTEGRATE_ISTIO}" == "true" ] ; then
    HELM_OPTIONS+="\
      --set socketLB.hostNamespaceOnly=true \
      --set cni.exclusive=false \
    "
fi

# --atomic 会在失败时自动回滚（删除）release，这会清理掉需要排查的 pod。
# CI 中设置 DISABLE_HELM_ATOMIC=true 以保留这些 pod。
HELM_ATOMIC=""
if [ "${DISABLE_HELM_ATOMIC:-"false"}" != "true" ]; then
    HELM_ATOMIC="--atomic"
fi

HELM_COMMON_OPTIONS="\
  --version ${CILIUM_VERSION} \
  --namespace ${NAMESPACE} \
  -f ${CURRENT_DIR_PATH}/values.yaml \
  ${HELM_OPTIONS} \
  ${EXTRA_HELM_OPTIONS:-}"

print_images() {
    helm template ${INSTANCE_NAME} ${CHART_PATH} ${HELM_COMMON_OPTIONS} |
        sed -n 's/^[[:space:]]*image:[[:space:]]*//p' |
        sed 's/^"//;s/"$//;s/^'\''//;s/'\''$//' |
        sort -u
}

normalize_registry() {
    echo "${1}" | sed 's#/*$##'
}

image_without_digest() {
    echo "${1}" | sed 's#@sha256:.*$##'
}

pull_images() {
    local offline_registry
    offline_registry="$(normalize_registry "${OFFLINE_REGISTRY}")"

    print_images | while IFS= read -r image; do
        [ -n "${image}" ] || continue

        docker pull "${image}"

        if [ -n "${offline_registry}" ]; then
            local offline_image="${offline_registry}/$(image_without_digest "${image}")"
            docker tag "${image}" "${offline_image}"
            docker push "${offline_image}"
        fi
    done
}

if [ "${PRINT_IMAGES}" == "true" ]; then
    print_images
    exit 0
fi

if [ "${PREPULL_IMAGES}" == "true" ]; then
    pull_images
    exit 0
fi

if [ "${HELM_DRY_RUN}" == "true" ]; then
    helm template ${INSTANCE_NAME} ${CHART_PATH} --debug \
      ${HELM_COMMON_OPTIONS}
    exit 0
fi

helm upgrade --install ${INSTANCE_NAME} ${CHART_PATH} --debug ${HELM_ATOMIC} --timeout 10m \
  ${HELM_COMMON_OPTIONS}
