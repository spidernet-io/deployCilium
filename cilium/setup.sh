#!/bin/bash

:<<eof

# export CHART_HTTP_PROXY="http://172.16.1.11:8080"

注意，当要使用 clustermesh 时， 每个集群的这些参数必须不能相同：  CLUSTERMESH_APISERVER_NODEPORT  CLUSTER_NAME CLUSTER_ID

CLUSTER_ID
  # clusters and in the range of 1 to 255. Only required for Cluster Mesh,
  # may be 0 if Cluster Mesh is not used.
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
    DISABLE_KUBE_PROXY="true" \
    UNINSTALL_OLD_CILIUM_CRD="true" \
    ./setup.sh

安装要求 
https://docs.cilium.io/en/latest/operations/system_requirements/#systemd-based-distributions

遗留：
1 支持使用 多 ippool
   Multi-Pool IPAM is a preview feature 
   Multi-Pool IPAM may only be used in direct routing mode. Tunnel mode is not supported

2 支持 native 模式安装 

eof

CMD_OPTION1=${1:-""}
CURRENT_FILENAME=$( basename $0 )
CURRENT_DIR_PATH=$(cd $(dirname $0); pwd)

set -o errexit
set -o nounset
set -o pipefail


if ! which wget &>/dev/null ; then
    yum install -y wget || apt install -y wget
fi


#=====================   version
INSTANCE_NAME=${INSTANCE_NAME:-"cilium"}
NAMESPACE=${NAMESPACE:-"kube-system"}

source ${CURRENT_DIR_PATH}/version.sh



DAOCLOUD_REPO=${DAOCLOUD_REPO:-"m.daocloud."}


if [ "${CMD_OPTION1}" == "image" ] ; then 
    echo -n " quay.${DAOCLOUD_REPO}io/cilium/cilium:v${CILIUM_VERSION} "
    echo -n " quay.${DAOCLOUD_REPO}io/cilium/hubble-relay:v${CILIUM_VERSION} "
    echo -n " quay.${DAOCLOUD_REPO}io/cilium/clustermesh-apiserver:v${CILIUM_VERSION} "
    exit 0
fi 

CHART_HTTP_PROXY=${CHART_HTTP_PROXY:-""}
if [ -n "$CHART_HTTP_PROXY" ] ; then
    echo "use proxy $CHART_HTTP_PROXY to pull chart " >&2
    export https_proxy=$CHART_HTTP_PROXY
else
    echo "no http proxy" >&2
fi
export CHART_HTTP_PROXY=${CHART_HTTP_PROXY}

#===================== configure
set -x

CHART_PATH="cilium/cilium"
if [ -f "${CURRENT_DIR_PATH}/chart/cilium-${CILIUM_VERSION}.tgz" ] ; then
    CHART_PATH="${CURRENT_DIR_PATH}/chart/cilium-${CILIUM_VERSION}.tgz"
    echo "use local chart ${CHART_PATH}"
else 
    CHART_REPO="https://helm.cilium.io"
    helm repo add cilium ${CHART_REPO} || true
    helm repo update cilium
fi

#注意：kube-controller-manager 默认 为每个node 分配 ipv4 block=24 ， ipv6 block=64.
#因为 kubeadm没有提供相关选项，所以，pod ipv4 cidr 的掩码要大于 24 ， pod ipv6 pod 掩码要大于64
POD_v4CIDR=${POD_v4CIDR:-"172.70.0.0/16"}
POD_v4Block=${POD_v4Block:-24}

ENABLE_IPV6=${ENABLE_IPV6:-"true"}
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

export KUBECONFIG=${KUBECONFIG:-"/root/.kube/config"}

DISABLE_KUBE_PROXY=${DISABLE_KUBE_PROXY:-"true"}

UNINSTALL_OLD_CILIUM_CRD=${UNINSTALL_OLD_CILIUM_CRD:-"false"}

echo "KUBECONFIG=${KUBECONFIG}"
echo "INSTANCE_NAME=${INSTANCE_NAME}"
echo "NAMESPACE=${NAMESPACE}"
echo "CHART_HTTP_PROXY=${CHART_HTTP_PROXY}"
echo "POD_v4CIDR=${POD_v4CIDR}"
echo "POD_v4Block=${POD_v4Block}"
echo "POD_v6CIDR=${POD_v6CIDR}"
echo "POD_v6Block=${POD_v6Block}"
echo "CLUSTER_NAME=${CLUSTER_NAME}"
echo "CLUSTER_ID=${CLUSTER_ID}"
echo "K8S_API_IP=${K8S_API_IP}"
echo "K8S_API_PORT=${K8S_API_PORT}"
echo "HUBBLE_WEBUI_NODEPORT_PORT=${HUBBLE_WEBUI_NODEPORT_PORT}"
echo "UNINSTALL_OLD_CILIUM_CRD=${UNINSTALL_OLD_CILIUM_CRD}"

#===================  uninstall 


if [ "${CMD_OPTION1}" == "uninstall" ] ; then
    echo "------uninstall operation"
    echo "KUBECONFIG=${KUBECONFIG}"
    cilium clustermesh disable || true
    helm uninstall -n ${NAMESPACE} ${INSTANCE_NAME} || true
    ( kubectl get pod -n cilium-spire | sed '1 d' | awk '{print $1}' | xargs -n 1 -i kubectl delete pod -n cilium-spire {} --force ) || true
    ( kubectl get pod -n ${NAMESPACE} | grep cilium | sed '1 d' | awk '{print $1}' | xargs -n 1 -i kubectl delete pod -n ${NAMESPACE} {} --force ) || true
    exit 0
elif [ -n "${CMD_OPTION1}" ] ; then
    echo "unknown option ${CMD_OPTION1}"
    exit 1
fi


#===================  download 



if [ -n "${HUBBLE_CLI_VERSION}" ] ; then
    if [ -f "${CURRENT_DIR_PATH}/binary/hubble-linux-amd64-${HUBBLE_CLI_VERSION}.tar.gz" ] ; then
        cp  ${CURRENT_DIR_PATH}/binary/hubble-linux-amd64-${HUBBLE_CLI_VERSION}.tar.gz /tmp/hubble-linux-amd64.tar.gz
        ( 
            cd /tmp 
            tar xzvf hubble-linux-amd64.tar.gz
            chmod +x hubble
            cp hubble /usr/sbin/
        )
    else 
        DOWNLOAD=false 
        if ! which hubble &>/dev/null ; then
            DOWNLOAD=true
        else 
            TMP=$( hubble version | grep -oE "v[0-9]+\.[0-9]+\.[0-9]+"  )
            if [ "${TMP}" != "${HUBBLE_CLI_VERSION}" ] ; then
                DOWNLOAD=true
                BIN_PATH=$( which hubble )
                rm -f ${BIN_PATH}
            fi
        fi
        if [ "${DOWNLOAD}" = "true" ] ; then
            echo "download hubble cli ${HUBBLE_CLI_VERSION}"
            ( 
                rm /tmp/* -rf && wget https://github.com/cilium/hubble/releases/download/${HUBBLE_CLI_VERSION}/hubble-linux-amd64.tar.gz
                cd /tmp 
                tar xzvf hubble-linux-amd64.tar.gz
                chmod +x hubble
                cp hubble /usr/sbin/
            )
        fi
    fi 
fi 

if [ -n "${CILIUM_CLI_VERSION}" ] ; then
    if [ -f "${CURRENT_DIR_PATH}/binary/cilium-linux-amd64-${CILIUM_CLI_VERSION}.tar.gz" ] ; then
        cp ${CURRENT_DIR_PATH}/binary/cilium-linux-amd64-${CILIUM_CLI_VERSION}.tar.gz /tmp/cilium-linux-amd64.tar.gz 
        ( 
            cd /tmp
            tar xzvf cilium-linux-amd64.tar.gz
            chmod +x cilium
            mv cilium /usr/sbin/
        )
    else 
        DOWNLOAD=false 
        if ! which cilium &>/dev/null ; then
            DOWNLOAD=true
        else 
            TMP=$( cilium version --client | sed -n '1p' | grep -oE "v[0-9]+\.[0-9]+\.[0-9]+" )
            if [ "${TMP}" != "${CILIUM_CLI_VERSION}" ] ; then
                DOWNLOAD=true
                BIN_PATH=$( which cilium )
                rm -f ${BIN_PATH}
            fi
        fi
        if [ "${DOWNLOAD}" = "true" ] ; then
            echo "download cilium cli ${CILIUM_CLI_VERSION}"
            ( 
                rm /tmp/* -rf && cd /tmp && wget https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz
                cd /tmp
                tar xzvf cilium-linux-amd64.tar.gz
                chmod +x cilium
                mv cilium /usr/sbin/
            )
        fi
    fi
fi 


#======================================= uninstall

kubectl delete deployment  -n kube-system   calico-kube-controllers &>/dev/null || true
kubectl delete daemonset  -n kube-system   calico-node &>/dev/null || true


helm uninstall -n ${NAMESPACE} ${INSTANCE_NAME}  || true
kubectl delete -n ${NAMESPACE} Secret clustermesh-apiserver-admin-cert || true
kubectl delete -n ${NAMESPACE} Secret clustermesh-apiserver-local-cert || true
kubectl delete -n ${NAMESPACE} Secret clustermesh-apiserver-remote-cert || true
kubectl delete -n ${NAMESPACE} Secret clustermesh-apiserver-server-cert || true
kubectl delete -n ${NAMESPACE} Secret hubble-relay-client-certs || true
kubectl delete -n ${NAMESPACE} Secret hubble-server-certs || true
kubectl delete -n ${NAMESPACE} Secret cilium-ca || true

if [ "${UNINSTALL_OLD_CILIUM_CRD}" = "true" ] ; then
    CRD_LIST=$( kubectl get crd | grep "cilium.io" | awk '{print $1}' ) || true
    for crd in ${CRD_LIST} ; do
        kubectl delete crd ${crd} || true
    done
fi


#============================================== set your code following


#( kubectl get pod -n cilium-spire | sed '1 d' | awk '{print $1}' | xargs -n 1 -i kubectl delete pod -n cilium-spire {} --force ) || true
#( kubectl get pod -n kube-system | grep cilium | sed '1 d' | awk '{print $1}' | xargs -n 1 -i kubectl delete pod -n cilium-spire {} --force ) || true

# resource may be terminating
# sleep 5
# echo "wait for deleting namesapce cilium-spire"
# for ((N=0;N<30;N++)) ; do
#     kubectl get ns cilium-spire || break
#     sleep 2
# done


# for loadbalancer service
# v1.13, the BGP Control Plane will only work when IPAM mode is set to “cluster-pool”, “cluster-pool-v2beta”, and “kubernetes”
# ENABLE_BGP=false

# 开启加速数据包转发  , 要求kernel>=5.10，数据包 fully bypass iptables and the upper host stack  ( BPF host routing requires kernel 5.10 or newer ).
# direct routing mode should route traffic via host stack . it will also bypass netfilter in the host namespace
EBPF_BASED_HOST_ROUTING=${EBPF_BASED_HOST_ROUTING:-"true"}

# socket loadbalancer in pod and host ns for kube-proxy replacement
# TCP and UDP requires a v4.19.57, v5.1.16, v5.2.0 or more recent Linux kernel(5.10+ ? ),The most optimal kernel with the full feature set is v5.8
ENABLE_SOCKET_LB=${ENABLE_SOCKET_LB:-"true"}


# when enable, DSR is not supported , XDP is not supported
# when native routing, auto DSR
# "" / vxlan / geneve
TUNNEL_MODE=${TUNNEL_MODE:-"vxlan"}

# Cannot use NodePort acceleration with tunneling
# Cannot use NodePort acceleration with the egress gateway
ENABLE_XDP=${ENABLE_XDP:-"false"}


# List of devices used to attach bpf_host.o (implements BPF NodePort,host-firewall and BPF masquerading)
# 如果开启了 xdp 加速，手动指定 DEVICES 要小心，xdp加载失败 而 cilium-agent 无法启动
# from version 1.11 ，如果不手动指定，cilium 会自动 添加 所有  all non-bridged, non-bonded and non-virtual interface that have global unicast routes
# 如果手动指定，该设备必须包含了 kubelet 工作的网卡，否则，没有加载ebpf ，会丢包
# HOST_DEVICE_FOR_EBPF="{eno+\,ens+}"
HOST_DEVICE_FOR_EBPF=${HOST_DEVICE_FOR_EBPF:-""}


# native routing mode 下的 device , also for xdp device (used only by NodePort BPF)
# When multiple devices are used, only one device can be used for direct routing between Cilium nodes. By default, if a single device was detected or specified via ``devices`` then Cilium will use that device for direct routing.
# Otherwise, Cilium will use a device with Kubernetes InternalIP or ExternalIP being set. InternalIP is preferred over ExternalIP if both exist
# 该接口会自动加入到 devices 中
# by default , it is the interface of k8s kubelet
# 貌似没生效 ，应该是 还没搞清楚该 设置
# 设置为 kubelet --node-ip 的网卡
# 如果不是设置为 kubelet --node-ip 的网卡 ，发现 ipv4还是 强制设置为了 kubelet --node-ip 的网卡  ， 但 ipv6 设置为了 directRoutingDevice 的网卡
# NATIVE_ROUTING_INTERFACE=eth1
NATIVE_ROUTING_INTERFACE=${NATIVE_ROUTING_INTERFACE:-""}


# 配合 CiliumL2AnnouncementPolicy ， 为 Loadbalancer 在指定主机上进行 arp 传播 , respond to ARP queries for ExternalIPs and/or LoadBalancer IPs
# https://docs.cilium.io/en/stable/network/l2-announcements/
# 它是 metallb 的 平替
ENABLE_l2announcements=${ENABLE_l2announcements:-"true"}


# install spiffe for mTLS auth of mesh
ENABLE_MESH_MTLS_AUTH=${ENABLE_MESH_MTLS_AUTH:-"false"}
# set to be empty, at the cost of re-creating all data when the SPIRE server pod is restarted
SPIFFE_storageClass=${SPIFFE_storageClass:-"local-path"}

# ipsec or wireguard
ENABLE_ENCRYPTION=${ENABLE_ENCRYPTION:-"false"}

# 如果要安装，请先安装 支持的 gatewayAPI 版本 对应的 yaml
ENABLE_gatewayAPI=${ENABLE_gatewayAPI:-"true"}

if [ "$ENABLE_gatewayAPI" == "true" ] && ( ! kubectl get gatewayclasses &>/dev/null ) ;then
    # v1.17.0 支持 gatewayAPI v1.2.0 
    # https://docs.cilium.io/en/latest/network/servicemesh/gateway-api/gateway-api/
         GATEWAY_API_VERSION="v1.2.0"
         if [ -d "${CURRENT_DIR_PATH}/gateway-api" ] ; then 
            echo "apply gateway api from local directory"
            kubectl apply -f "${CURRENT_DIR_PATH}/gateway-api/*"
         else 
            echo "apply gateway api from remote"
            kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${GATEWAY_API_VERSION}/config/crd/standard/gateway.networking.k8s.io_gatewayclasses.yaml
            kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${GATEWAY_API_VERSION}/config/crd/standard/gateway.networking.k8s.io_gateways.yaml
            kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${GATEWAY_API_VERSION}/config/crd/standard/gateway.networking.k8s.io_httproutes.yaml
            kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${GATEWAY_API_VERSION}/config/crd/standard/gateway.networking.k8s.io_referencegrants.yaml
            kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${GATEWAY_API_VERSION}/config/crd/standard/gateway.networking.k8s.io_grpcroutes.yaml
            kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${GATEWAY_API_VERSION}/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml
         fi 
fi

ENABLE_DEBUG=${ENABLE_DEBUG:-"true"} 

ENABEL_EGRESS=${ENABEL_EGRESS:-"true"}

# linux 5.19  ，支持了 IPv6 big tcp , (ubuntu 2210+)
# Linux 6.3 支持了 ipv4 big tcp , (ubuntu 2304+)
# require NICs: mlx4, mlx5 , and following settings
# https://docs.cilium.io/en/latest/operations/performance/tuning/#ipv6-big-tcp
ENABLE_BIGTCP=${ENABLE_BIGTCP:-"false"}


# netkit, replacing veth
# https://docs.cilium.io/en/latest/operations/performance/tuning/#netkit-device-mode
# Kernel >= 6.8
ENABLE_NETKIT=${ENABLE_NETKIT:-"false"}


CLUSTERMESH_APISERVER_NODEPORT=${CLUSTERMESH_APISERVER_NODEPORT:-"30100"}


#================

#accelerate image
HELM_OPTIONS=" \
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


DEFAULT_SECRET_NS="cilium-secrets"
HELM_OPTIONS+=" \
  --set envoyConfig.secretsNamespace.name=${DEFAULT_SECRET_NS} \
  --set ingressController.secretsNamespace.name=${DEFAULT_SECRET_NS} \
  --set gatewayAPI.secretsNamespace.name=${DEFAULT_SECRET_NS} \
  --set tls.secretsNamespace.name=${DEFAULT_SECRET_NS} "


cat <<EOF > /tmp/cilium.yaml

cni:
  # 如果开启， cilium 会把 /etc/cni/net.d 目录下的 其它 conflist 配置文件 改名为 *.cilium_bak ，确保自己能够被 K8S 调用
  exclusive: false

# service mesh, for ingress
# cilium 需要 L4 Loadbalancer 来分 南北向的 4层入口，cilium 自动为每一个 ingress 对象 维护一个 Loadbalancer 的 service
# 如下 loadbalancerMode= shared | dedicated ， 设置 缺省的 ingress 创建 service 的行为，是共享一个，还是分别有独立的 。 应用可通过 annotaiton 额外指定 模式
ingressController:
  enabled: true
  default: true
  loadbalancerMode: shared
  service:
    type: NodePort
  enforceHttps: false

# service mesh, for gatewayAPI
gatewayAPI:
  enabled: ${ENABLE_gatewayAPI}

cluster:
  name: ${CLUSTER_NAME}
  id: ${CLUSTER_ID}

bpf:
  # 允许集群外部 访问 cluster ip
  lbExternalClusterIP: false
  # preallocateMaps: memory usage but can reduce latency
  preallocateMaps: true
  tproxy: true
  lbBypassFIBLookup: true

  # hostLegacyRouting: 要求kernel>=5.10. Configure whether direct routing mode should route traffic via host stack (true) or bypass netfilter in the host namespace 
  hostLegacyRouting: ${EBPF_BASED_HOST_ROUTING}

  #  require
  #  --set routingMode=native \
  #  --set bpf.datapathMode=netkit \
  #  --set bpf.masquerade=true \
  #  --set kubeProxyReplacement=true
  datapathMode: $( if [ "$ENABLE_NETKIT" == "true" ] ; then echo "netkit" ; else echo "veth" ; fi )

  masquerade: true

egressGateway:
  # -- Enables egress gateway to redirect and SNAT the traffic that leaves the cluster.
  enabled: ${ENABEL_EGRESS}
ciliumEndpointSlice:
  # Egress gateway is not compatible with the CiliumEndpointSlice feature
  enabled: false

authentication:
  # mesh-auth-enabled
  enabled: ${ENABLE_MESH_MTLS_AUTH}
  mutual:
    spire:
      #  mesh-auth-mutual-enabled
      enabled: ${ENABLE_MESH_MTLS_AUTH}
      install:
        enabled: ${ENABLE_MESH_MTLS_AUTH}
        namespace: ${NAMESPACE}
        server:
          dataStorage:
            enabled: $( if [ -n "${SPIFFE_storageClass}" ] ; then echo "true" ; else echo "false" ; fi )
            storageClass: ${SPIFFE_storageClass}
          affinity:
            nodeAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                nodeSelectorTerms:
                  - matchExpressions:
                    - key: node-role.kubernetes.io/control-plane
                      operator: Exists

# List of devices used to attach bpf_host.o (implements BPF NodePort,host-firewall and BPF masquerading)
# by default , chose the interface that Kubernetes InternalIP or then ExternalIP assigned
#  supports '+' as wildcard in device name, e.g. 'eth+'
#HELM_OPTIONS+=" --set devices='ens192' "
#HELM_OPTIONS+=" --set devices='{ens192,ens224}' "
#HELM_OPTIONS+=" --set devices='{eno+,ens+}' "
devices: "${HOST_DEVICE_FOR_EBPF}"

ipv4:
  enabled: true
ipv6:
  enabled: ${ENABLE_IPV6}

# masqurade
# bpf.masquerade: Masquerade packets from endpoints leaving the host with BPF instead of iptables
# ipv4NativeRoutingCIDR , 配置哪些 CIDR 不需要做 SNAT Specify the CIDR for native routing (ie to avoid IP masquerade for) , This value corresponds to the configured cluster-cidr
# "BPF masquerade is not supported for IPv6."
# ipMasqAgent.enabled 如果开启了 ipMasqAgent， 默认的 nonMasqueradeCIDRs 扩大了 . 一般情况下，基本的 masquerade 够用,不需要 ipMasqAgent 模式
enableIPv4Masquerade: true
enableIPv6Masquerade: ${ENABLE_IPV6}

bandwidthManager:
  enabled: true

hostFirewall:
  enabled: true

localRedirectPolicy: true

wellKnownIdentities:
  enabled: true

# required
securityContext:
  privileged: true

debug:
  enabled: ${ENABLE_DEBUG}

# mounting the eBPF filesystem and updating the existing Azure CNI plugin to run in ‘transparent’ mode.
nodeinit:
  enabled: true
  securityContext:
    privileged: true

# deploy envoy as standalone daemonset, but does not run inside cilium agent pod
# This means both the Cilium agent and the Envoy proxy not only share the same lifecycle but also the same blast radius in the event of a compromise
envoy:
  enabled: true

bgpControlPlane:
  enabled: true

ipam:
  mode: cluster-pool
  operator:
    clusterPoolIPv4PodCIDRList: ${POD_v4CIDR}
    clusterPoolIPv4MaskSize: ${POD_v4Block}
    clusterPoolIPv6PodCIDRList: ${POD_v6CIDR}
    clusterPoolIPv6MaskSize: ${POD_v6Block}

routingMode: $( if [ -n "$TUNNEL_MODE" ] ;  then echo "tunnel" ; else echo "native" ; fi )
tunnelProtocol: "${TUNNEL_MODE}"
autoDirectNodeRoutes: $( if [ -n "$TUNNEL_MODE" ] ;  then echo "false" ; else echo "true" ; fi )

loadBalancer:
  mode: $( if [ -n "$TUNNEL_MODE" ] ;  then echo "snat" ; else echo "dsr" ; fi )

  # DSR currently requires Cilium to be deployed in Native-Routing(no tunnel), i.e. it will not work in either tunneling mode
  # loadBalancer.dsrDispatch: =opt  for ip , =ipip for ipip
  # loadBalancer.dsrDispatch=ipip 要求 支持部署 基于 xdp 的  独立的 L4 LoadBalancer : --set loadBalancer.standalone=true
  dsrDispatch: "opt"

  # loadBalancer.acceleration = native , for xdp nodeport
  # Cannot use NodePort acceleration with tunneling
  acceleration: $( if [ -z "$TUNNEL_MODE" ] && [ "$ENABLE_XDP" == "true" ] ; then echo "native" ; else echo "disabled" ; fi )

externalIPs:
  enabled: true

nodePort:
  enabled: true

  # 一个潜在配置
  # DirectRoutingDevice is the name of a device used to connect nodes in direct routing mode (only required by BPF NodePort)
  # signle device for XDP device and native routing device ( if not specified, automatically set to a device with k8s InternalIP/ExternalIP or with a default route )
  directRoutingDevice: "$( if [ -z "${TUNNEL_MODE}" ] && [ -n "${NATIVE_ROUTING_INTERFACE}" ] ; then echo "${NATIVE_ROUTING_INTERFACE}" ; else echo "" ; fi )"


# Cilium’s eBPF kube-proxy replacement currently cannot be used with Transparent Encryption
encryption:
  enabled: ${ENABLE_ENCRYPTION}
  type: wireguard
  nodeEncryption: true


k8sServiceHost: ${K8S_API_IP}
k8sServicePort: ${K8S_API_PORT}

sessionAffinity: true

# node 为 本地 pod 在pod 启动时发送 免费ARP， 但 pod 运行时，不会响应平时 arp请求
l2podAnnouncements:
  enabled: false

# ARP for service loadbalancerIP / externalIPs
# issue: https://docs.cilium.io/en/stable/network/l2-announcements/#sizing-client-rate-limit
# Kube Proxy replacement mode must be enabled and set to strict mode for l2announcements
l2announcements:
  enabled: ${ENABLE_l2announcements}
k8sClientRateLimit:
  qps: 50
  burst: 60

hostPort:
  enabled: true

kubeProxyReplacement: true

# Enable IPv6 BIG TCP option which increases device's maximum GRO/GSO limits
# require NICs: mlx4, mlx5 , and following settings
#  --set routingMode=native \
#  --set bpf.masquerade=true \
#  --set kubeProxyReplacement=true
enableIPv4BIGTCP: $( if [ "${ENABLE_BIGTCP}" == "true" ] ; then echo "true" ; else echo "false" ; fi )
enableIPv6BIGTCP: $( if [ "${ENABLE_BIGTCP}" == "true" ] && [ "${ENABLE_IPV6}" == "true" ] ; then echo "true" ; else echo "false" ; fi )

# sockopt-loadbalancer for kube-proxy replacement
# TCP and UDP requires a v4.19.57, v5.1.16, v5.2.0 or more recent Linux kernel(5.10+ ? ),The most optimal kernel with the full feature set is v5.8
socketLB:
  enabled: ${ENABLE_SOCKET_LB}
  hostNamespaceOnly: false

hubble:
  enabled: true
  eventBufferCapacity: 65535

  # eventQueueSize <= defaults.MonitorQueueSizePerCPUMaximum(16384), default to numCPU * 1024
  eventQueueSize: 16384

  ui:
    enabled: true
    service:
      type: NodePort
      nodePort: ${HUBBLE_WEBUI_NODEPORT_PORT}
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: Exists

  # hubble.tls :  for mTLS between Hubble server and Hubble Relay
  tls:
    enabled: true
    auto:
      enabled: true
      method: cronJob
      # in days
      certValidityDuration: 36500
  
  relay:
    enabled: true
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: Exists

  frontend:
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: Exists

  metrics:
    # for more
    # https://github.com/isovalent/grafana-dashboards/tree/main/dashboards/cilium-policy-verdicts
    # https://github.com/isovalent/cilium-grafana-observability-demo/blob/main/helm/cilium-values.yaml
    # https://docs.cilium.io/en/latest/observability/grafana/
    # 定制 flow 中的 metric
    enabled: ["dns:query;ignoreAAAA", "drop", "tcp", "flow", "port-distribution", "icmp", "httpV2:exemplars=true;labelsContext=source_ip,source_namespace,source_workload,destination_ip,destination_namespace,destination_workload,traffic_direction"]
    # enabled: ["dns:query;ignoreAAAA", "drop", "tcp", "flow", "icmp", "http"]

certgen:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
            - key: node-role.kubernetes.io/control-plane
              operator: Exists

clustermesh:
  useAPIServer: true
  enableEndpointSliceSynchronization: true
  enableMCSAPISupport: false
  apiserver:
    tls:
      auto:
        # in days
        certValidityDuration: 36500
    service:
      type: NodePort
      # WARNING: make sure to configure a different NodePort in each cluster if
      # kube-proxy replacement is enabled, as Cilium is currently affected by a known bug (#24692) when NodePorts are handled by the KPR implementation
      nodePort: ${CLUSTERMESH_APISERVER_NODEPORT}
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: Exists

tls:
  ca:
    # in days
    certValidityDuration: 36500

# operator:
#   affinity:
#     nodeAffinity:
#       requiredDuringSchedulingIgnoredDuringExecution:
#         nodeSelectorTerms:
#           - matchExpressions:
#             - key: node-role.kubernetes.io/control-plane
#               operator: Exists
EOF


helm install  cilium ${CHART_PATH} --debug  --atomic --version $CILIUM_VERSION  --timeout 20m \
  --namespace ${NAMESPACE}  \
  ${HELM_OPTIONS}  -f /tmp/cilium.yaml


echo "set default ingressClass"
kubectl  patch ingressClass cilium --patch '{"metadata": { "annotations": {"ingressclass.kubernetes.io/is-default-class": "true"} }}'




echo "目前，对于 Loadbalancer，还得依赖 metallb + kube-proxy 来完成，而 cilium 的 l2-announcements 是有问题的 "
if [ "${DISABLE_KUBE_PROXY}" == "true" ] ; then
    # disable kube-proxy
    kubectl patch daemonset kube-proxy -n kube-system --type='json' -p='[
      {
        "op": "replace",
        "path": "/spec/template/spec/containers/0/command",
        "value": [
          "/usr/local/bin/kube-proxy",
          "--cleanup"
        ]
      }
    ]'

    while true :; do
       ( iptables-save | grep "KUBE-SVC" &>/dev/null ) || break
       sleep 3
       echo "waiting for kube-proxy to be disabled"
    done

    kubectl patch daemonset kube-proxy -n kube-system --type='json' -p='[{"op": "add", "path": "/spec/template/spec/nodeName", "value": "notexsitednode"}]'
    echo "succeeded to disable kube-proxy"
fi



# #=========================

# :<<EOF
# echo "-- restart all pods after uninstall calico"
# ALL_POD=` kubectl  get pod -A -o wide | sed '1 d' | awk '{print $1,$2}' | tr ' ' ',' `
# for POD in ${ALL_POD} ; do
#     NAME=` echo ${POD} | tr ',' ' ' `
#     kubectl delete pod -n ${NAME} --force || true
# done

# sleep 180
# ALL_FAILED_POD=` kubectl  get pod -A -o wide | sed '1 d' | grep -v Running | awk '{print $1,$2}' | tr ' ' ',' ` || true
# for POD in ${ALL_FAILED_POD} ; do
#     NAME=` echo ${POD} | tr ',' ' ' `
#     kubectl delete pod -n ${NAME} --force || true
# done


# timeout 500 kubectl wait --for=condition=ready -l app.kubernetes.io/part-of=cilium \
#     --timeout=500s pod -n kube-system
# EOF
