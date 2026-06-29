# deployCilium

## 选择 Cilium 版本

本仓库按 Cilium 的 `x.y` 版本维护安装分支，每个分支只保留该 `x.y`
系列的最新 `z` 版本。例如：

- `cilium/v1.18`：保留最新的 Cilium `1.18.x`
- `cilium/v1.19`：保留最新的 Cilium `1.19.x`

如果需要安装特定的 Cilium `x.y` 系列，请直接 clone 对应分支。比如安装
最新的 Cilium `1.18.x`：

```bash
git clone -b cilium/v1.18 --single-branch https://github.com/spidernet-io/deployCilium.git deployCilium-v1.18
cd deployCilium-v1.18/cilium
```

如果需要安装 Cilium `1.19.x`，把分支名替换为 `cilium/v1.19`：

```bash
git clone -b cilium/v1.19 --single-branch https://github.com/spidernet-io/deployCilium.git deployCilium-v1.19
cd deployCilium-v1.19/cilium
```

可以通过如下命令查看当前可用的 Cilium 安装分支：

```bash
git ls-remote --heads https://github.com/spidernet-io/deployCilium.git 'cilium/v*'
```

可以通过如下命令查看当前分支实际保留的 Cilium patch 版本：

```bash
source ./version.sh
echo "${CILIUM_VERSION}"
```

安装和检查的基本流程如下。安装前请先按[部署 Cilium](#部署-cilium)中的说明设置
`POD_v4CIDR`、`CLUSTER_NAME`、`K8S_API_IP` 等环境变量。

```bash
chmod +x ./setup.sh ./showStatus.sh
./setup.sh
./showStatus.sh
```

注意：`main` 分支只维护自动升级逻辑，不作为安装分支使用。安装 Cilium 时请使用
`cilium/vX.Y` 分支。

##  工程目录

```
cilium/
  ├── binary/               目录下放置了对应版本的 CLI 二进制
  ├── chart/                目录下放置了对应版本的 chart
  ├── gateway-api/          目录下放置了 gateway api crd
  ├── tools/                目录下放置了工具脚本
  ├── version.sh            软件版本，决定了 setup.sh 的执行逻辑
  ├── setup.sh              安装脚本：安装 cilium 的脚本
  ├── setupClusterMesh.sh   功能开关脚本：设置多集群互联的脚本
  ├── setupMetrics.sh       功能开关脚本：开启指标的脚本
  ├── showClusterMesh.sh    排障脚本：用户查看多集群互联状态的脚本
  └── showStatus.sh         排障脚本：用户查看 cilium 状态的脚本
```

其它不相关的文件，请不要关注

## 部署 Cilium

如下步骤，会安装 Cilium 到 k8s 集群中。根据集群环境是否能访问公网镜像源，分为
[在线安装](#在线安装) 和 [离线安装](#离线安装) 两种方式。

两种方式安装出来的 cilium 默认都工作在 vxlan 模式隧道下，且打开了所有能够兼容的其它功能。
安装完成后通用的[环境变量说明](#环境变量说明)、[安装后检查](#安装后检查)以及
[可选后续步骤](#可选后续步骤) 放在后面统一说明。

### 公共准备

无论在线还是离线安装，都需要先完成以下公共准备：

1. 如果是通过 kubespray 安装新集群，建议配置 `kube_network_plugin=cni` 参数。对于已安装 Calico 的集群，
   请在 Cilium 安装成功后，参考[卸载 Calico](#卸载-calico) 步骤卸载 Calico。

2. 确保已经安装了 K8S 集群。如果是使用 kubespray 安装集群，指定 `kube_network_plugin=cni` 和
   `kube_proxy_remove=true` 选项。

3. 留意 cilium 官方的 [系统要求](https://docs.cilium.io/en/stable/operations/system_requirements/#admin-system-reqs)。

4. 确保机器上有如下 CLI： `helm`、`kubectl`、`jq`。
   注意：helm 版本最好高于 v3.17.3（测试过 v3.9.4 就出现和 cilium chart 的语法兼容问题）。

### 在线安装

适用于集群节点可以直接访问公网镜像源的场景。脚本默认从 DaoCloud 在线镜像仓库拉取镜像。

1. clone 对应的 `cilium/vX.Y` 分支到 master 节点

    以安装最新的 Cilium `1.18.x` 为例：

    ```bash
    git clone -b cilium/v1.18 --single-branch https://github.com/spidernet-io/deployCilium.git deployCilium-v1.18
    cd deployCilium-v1.18/cilium
    chmod +x ./setup.sh ./showStatus.sh
    ```

    如需安装其它 `x.y` 系列，把分支名替换为 `cilium/v1.19` 等。可用分支可通过如下命令查看：

    ```bash
    git ls-remote --heads https://github.com/spidernet-io/deployCilium.git 'cilium/v*'
    ```

2. 设置环境变量并安装

    安装单栈集群

    ```bash
    export POD_v4CIDR="172.16.0.0/16"
    export POD_v4Block="24"
    export CLUSTER_NAME="cluster1"
    export CLUSTER_ID="10"
    export CLUSTERMESH_APISERVER_NODEPORT="31001"
    export K8S_API_IP="10.0.1.11"
    export K8S_API_PORT="6443"
    export HUBBLE_WEBUI_NODEPORT_PORT="31000"
    export INTEGRATE_ISTIO="false"
    ./setup.sh
    ```

    安装双栈集群

    ```bash
    export POD_v4CIDR="172.16.0.0/16"
    export POD_v4Block="24"
    export ENABLE_IPV6="true"
    export POD_v6CIDR="fd00::/48"
    export POD_v6Block="64"
    export CLUSTER_NAME="cluster1"
    export CLUSTER_ID="10"
    export CLUSTERMESH_APISERVER_NODEPORT="31001"
    export K8S_API_IP="10.0.1.11"
    export K8S_API_PORT="6443"
    export HUBBLE_WEBUI_NODEPORT_PORT="31000"
    export INTEGRATE_ISTIO="false"
    ./setup.sh
    ```

    如果需要先检查 Helm 渲染结果，不实际安装到集群，可以使用 dry-run：

    ```bash
    HELM_DRY_RUN="true" ./setup.sh
    ```

    默认情况下，脚本会把 Cilium 相关镜像仓库切换到 DaoCloud 镜像源：

    - `quay.io` -> `quay.m.daocloud.io`
    - `ghcr.io` -> `ghcr.m.daocloud.io`

    如果需要使用上游原始镜像仓库，可以关闭该开关。安装、dry-run 都会使用相同配置：

    ```bash
    DAOCLOUD_IMAGE_REPO="false" ./setup.sh
    ```

3. 安装完成后，参考 [安装后检查](#安装后检查) 查看 cilium 状态。

### 离线安装

适用于集群节点无法访问公网镜像源的场景。需要先在一台可以访问公网镜像源、并且可以连接到火种镜像仓库的
**准备机** 上把镜像同步到火种镜像仓库，再在离线集群上安装。

#### 准备机要求

- 可以访问公网镜像源（quay.io / ghcr.io 或 DaoCloud 镜像源）
- 可以连接到火种镜像仓库
- 已安装 CLI： `helm`、`docker`

#### 离线集群要求

- 每个节点的容器运行时已经配置好访问火种镜像仓库
- 已安装 CLI： `helm`、`kubectl`、`jq`
- 离线集群安装时使用的 `POD_v4CIDR`、`CLUSTER_NAME`、`K8S_API_IP`、`DAOCLOUD_IMAGE_REPO`、
  `EXTRA_HELM_OPTIONS` 等参数必须与准备镜像时保持一致，否则 Helm 渲染出来的镜像列表可能不一致

#### 步骤 1：在准备机上 clone 对应分支并渲染镜像列表

在准备机上 clone 对应的 `cilium/vX.Y` 分支（与离线集群实际安装时使用的分支保持一致）：

```bash
git clone -b cilium/v1.18 --single-branch https://github.com/spidernet-io/deployCilium.git deployCilium-v1.18
cd deployCilium-v1.18/cilium
chmod +x ./setup.sh
```

使用和离线集群实际安装时相同的 Helm 参数渲染镜像列表。**关键：这里指定的环境变量必须与离线集群
安装时完全一致**，否则渲染出的镜像列表与实际安装时不匹配：

```bash
export POD_v4CIDR="172.16.0.0/16"
export POD_v4Block="24"
export CLUSTER_NAME="cluster1"
export CLUSTER_ID="10"
export CLUSTERMESH_APISERVER_NODEPORT="31001"
export K8S_API_IP="10.0.1.11"
export K8S_API_PORT="6443"
export HUBBLE_WEBUI_NODEPORT_PORT="31000"
export INTEGRATE_ISTIO="false"
# 如需使用上游原始镜像仓库，取消下面一行
# export DAOCLOUD_IMAGE_REPO="false"
PRINT_IMAGES="true" ./setup.sh > images.txt
```

如需人工检查或手动同步，可以查看 `images.txt` 中渲染出的镜像列表：

```bash
cat images.txt
```

#### 步骤 2：在准备机上拉取镜像并推送到火种镜像仓库

先登录火种镜像仓库：

```bash
docker login <火种镜像仓库地址>
```

使用脚本自动拉取镜像、重新打 tag 并推送到火种镜像仓库。把 `OFFLINE_REGISTRY` 替换为实际的
火种镜像仓库地址，并保持与步骤 1 相同的 Helm 参数环境变量：

```bash
export POD_v4CIDR="172.16.0.0/16"
export POD_v4Block="24"
export CLUSTER_NAME="cluster1"
export CLUSTER_ID="10"
export CLUSTERMESH_APISERVER_NODEPORT="31001"
export K8S_API_IP="10.0.1.11"
export K8S_API_PORT="6443"
export HUBBLE_WEBUI_NODEPORT_PORT="31000"
export INTEGRATE_ISTIO="false"
# export DAOCLOUD_IMAGE_REPO="false"

PREPULL_IMAGES="true" \
  OFFLINE_REGISTRY="<火种镜像仓库地址>" \
  ./setup.sh
```

脚本会自动完成：拉取镜像 -> 重新打 tag 为 `<火种镜像仓库地址>/<原始镜像>` -> 推送到火种镜像仓库。

如只需在准备机上提前拉取镜像、不自动推送，可单独执行：

```bash
while read -r image; do
  docker pull "${image}"
done < images.txt
```

#### 步骤 3：在离线集群上 clone 对应分支

在离线集群的 master 节点上 clone 同一个 `cilium/vX.Y` 分支：

```bash
git clone -b cilium/v1.18 --single-branch https://github.com/spidernet-io/deployCilium.git deployCilium-v1.18
cd deployCilium-v1.18/cilium
chmod +x ./setup.sh ./showStatus.sh
```

#### 步骤 4：在离线集群上设置环境变量并安装

离线集群安装时，必须保持与准备镜像时完全相同的环境变量，只需额外设置 `OFFLINE_REGISTRY` 指向火种镜像仓库地址。
脚本会自动把所有 cilium 镜像仓库前缀加上 `${OFFLINE_REGISTRY}/`，无需手动编写 `EXTRA_HELM_OPTIONS`。
脚本默认使用 DaoCloud 镜像源（`quay.m.daocloud.io`、`ghcr.m.daocloud.io`），因此最终镜像路径为
`${OFFLINE_REGISTRY}/quay.m.daocloud.io/cilium/...`，与准备机 retag 推送时的路径一致。

安装单栈集群

```bash
export POD_v4CIDR="172.16.0.0/16"
export POD_v4Block="24"
export CLUSTER_NAME="cluster1"
export CLUSTER_ID="10"
export CLUSTERMESH_APISERVER_NODEPORT="31001"
export K8S_API_IP="10.0.1.11"
export K8S_API_PORT="6443"
export HUBBLE_WEBUI_NODEPORT_PORT="31000"
export INTEGRATE_ISTIO="false"
# 与准备镜像时保持一致
# export DAOCLOUD_IMAGE_REPO="false"
export OFFLINE_REGISTRY="<火种镜像仓库地址>"
./setup.sh
```

安装双栈集群时，在上述基础上额外设置 IPv6 相关变量：

```bash
export ENABLE_IPV6="true"
export POD_v6CIDR="fd00::/48"
export POD_v6Block="64"
```

> 注意：
> - 如果准备镜像时设置了 `DAOCLOUD_IMAGE_REPO="false"`（使用上游 `quay.io` / `ghcr.io`），
>   离线集群安装时也必须设置相同的 `DAOCLOUD_IMAGE_REPO="false"`，脚本会相应把镜像路径前缀为
>   `<火种镜像仓库地址>/quay.io/...` 和 `<火种镜像仓库地址>/ghcr.io/...`。
> - `OFFLINE_REGISTRY` 仅在实际安装和 dry-run 时生效；`PRINT_IMAGES` / `PREPULL_IMAGES` 模式下
>   仍然使用公网镜像源路径，以便从公网拉取后再 retag 推送。
> - 如需在 dry-run 中验证离线渲染结果：`OFFLINE_REGISTRY="<火种镜像仓库地址>" HELM_DRY_RUN="true" ./setup.sh`

#### 步骤 5：安装完成后，参考 [安装后检查](#安装后检查) 查看 cilium 状态。

### 环境变量说明

> 说明：
> *  POD_v4CIDR 是本集群的 POD IPv4 cidr，POD_v4Block 是每个 node 分割的 pod 小子网大小。注意，如果后续步骤需要实现多集群网络互联，请确保每个集群的 POD_v4CIDR 是不重叠的
> * ENABLE_IPV6 表示是否启用 IPv6，如果集群主机网卡没有配置 IPv6 地址，K8S集群没有开启双栈，请不开打开它
> * CLUSTER_NAME 表示本集群的名称，CLUSTER_ID 表示本集群的 ID（取值大小1-255 ）. 注意，运行本步骤后，只是做了多集群配置初始化，并未实现与其他集群互联，因此，请确保每一个集群的 CLUSTER_NAME 和 CLUSTER_ID 参数都是唯一的，这样才能在未来实现多集群联通时。
> * CLUSTERMESH_APISERVER_NODEPORT 是 cilium 的多集群互联的 nodePort 号，可手动指定一个在合法的 nodePort 范围内的地址（通常在 30000-32767 ）。注意，每一个集群设置的该参数必须是唯一的，否则多集群互联时会出问题。
> * K8S_API_IP 和 K8S_API_PORT 表示本集群 Kubernetes API 服务器的地址，它用于在不需要 kube-proxy 时，cilium 也能访问 api server，为集群提供 service 能力。因此，这个地址不能是 clusterIP，而必须是单个主机的 Kubernetes API 服务器的物理地址，或者通过 keepalived 等工具实现的高可用地址。
> * HUBBLE_WEBUI_NODEPORT_PORT 是 cilium 的可观测性 GUI 的 nodePort 号，可手动指定一个在合法的 nodePort 范围内的地址（通常在 30000-32767 ）
> * cilium 遵循 K8S 集群的 clusterIP CIDR 设置。并且，cilium 在实现多集群互联时，允许不同集群的 clusterIP CIDR 是重叠的
> * INTEGRATE_ISTIO 表示是否 istio 会工作在 cilium 网络中，如果是 true ，会为调优 cilium 的工作参数
> * DAOCLOUD_IMAGE_REPO 控制是否使用 DaoCloud 镜像源。默认 `true`，把 `quay.io` / `ghcr.io` 切换为 `quay.m.daocloud.io` / `ghcr.m.daocloud.io`；设为 `false` 则使用上游原始镜像仓库。在线安装、离线镜像准备、离线集群安装三者必须保持一致
> * OFFLINE_REGISTRY 火种镜像仓库地址。设置后，脚本在实际安装和 dry-run 时会自动把所有 cilium 镜像仓库前缀加上 `${OFFLINE_REGISTRY}/`，无需手动编写 EXTRA_HELM_OPTIONS。在 PREPULL_IMAGES 模式下用于 retag 并推送（旧变量名 OFFLINE_GLOBAL_REGISTRY 仍兼容）
> * EXTRA_HELM_OPTIONS 透传额外的 Helm 参数，用于脚本未覆盖的定制需求
> * PRINT_IMAGES 仅渲染并打印镜像列表，不安装集群，常用于离线镜像准备
> * PREPULL_IMAGES 拉取渲染出的镜像；配合 OFFLINE_REGISTRY 时会重新打 tag 并推送到指定仓库
> * HELM_DRY_RUN 仅渲染 Helm manifest，不实际安装到集群

### 安装后检查

完成 cilium 安装后，可运行如下命令，查看本集群 cilium 的状态：

```bash
chmod +x ./showStatus.sh
./showStatus.sh
```

完成安装后，可通过 CLUSTERMESH_APISERVER_NODEPORT 的 nodePort 访问 cilium 的报文可观测性 GUI。

### 可选后续步骤

以下步骤在线安装和离线安装完成后均适用。

1. (可选) 卸载 Calico

    如果您的集群已经安装 Calico，参考[卸载 Calico](#卸载-calico) 步骤卸载 Calico。

2. (可选) 卸载 kube-proxy

    cilium 按照 kube-proxy replacement 方式在工作，因此，如果集群中还在运行 kube-proxy，其已经无任何作用了，可进行卸载

```bash
    # 替换 kube proxy 启动命令，使其清理各种主机规则
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

    # 等待 kube proxy 的所有pod 重启 运行退出后，即可卸载 
    kubectl delete daemonset kube-proxy -n kube-system
    
    # 或者修改 nodename，使其不运行在任何节点上
    # kubectl patch daemonset kube-proxy -n kube-system --type='json' -p='[{"op": "add", "path": "/spec/template/spec/nodeName", "value": "notexsitednode"}]'

```        

3. (可选) 开启 cilium 的指标和 grafana 面板

    （1）确保安装 grafana 和 prometheus （需要依赖集群中已经安装了 grafana 和 prometheus 的 CRD ）

    （2）进入工程的 cilium 子目录下，运行如下命令，它会完成指标的开启，以及观测面板的开启

    ```bash
    chmod +x ./setupMetrics.sh
    ./setupMetrics.sh
    ```

    完成指标和观测面板的开启后，即可以在 grafana 上看到 cilium 相关的面板

    可安装 DCE 定义的告警规则和精选指标面板

    ```bash
    kubectl apply -n <Insight 租户> -f ./cilium/yamls/ciliumPrometheusRules.yaml
    ```

    ```bash
    kubectl apply -n <Insight 租户> -f ./cilium/yamls/ciliumGrafana.yaml

    # 重启 grafana pod
    ```

4. (可选) 实现多集群互联

     注：当多个 cilium 集群之间的应用需要通过 nodePort 相互访问，会因为 nodePort 端口冲突，导致 client 集群把 service 解析到本地集群上，出现访问错误。因此，请务必使用该功能互联集群，并使用 service 来进行东西向访问，解决该问题
   
    （1）创建 /root/clustermesh 目录，把所有希望互联的集群的/root/.kube/config 拷贝到该目录下，命名为 /root/clustermesh/cluster1、 /root/clustermesh/cluster2、/root/clustermesh/cluster3 ..... 

    （2）进入本工程的 cilium 子目录，运行如下命令，完成多集群互联的配置

    ```bash
    chmod +x ./showClusterMesh.sh
    ./setupClusterMesh.sh  /root/clustermesh/cluster1  /root/clustermesh/cluster2 [/root/clustermesh/cluster3 ... ]
    ```

    （3）检查多集群互联状态

    进入工程的 cilium 子目录下，运行如下命令，它会检查多集群互联状态

    ```bash
    ./showClusterMesh.sh
    ```

## 卸载 Cilium

```bash
chmod +x ./uninstall.sh
./uninstall.sh
```

## 卸载 Calico

1. 首先在**具有 Kubectl 的 Controller 节点**执行以下命令，卸载 Calico K8s 资源：

```
kubectl get crd | grep projectcalico | awk '{print $1}' | xargs kubectl delete crd || true
kubectl delete deploy -n kube-system calico-kube-controllers || true
kubectl delete ds -n kube-system calico-node || true
kubectl delete sa -n kube-system calico-kube-controllers calico-cni-plugin calico-node || true
kubectl delete clusterrolebinding calico-cni-plugin calico-kube-controllers calico-node || true
```

2. 进入到 cilium 子目录，在**每个节点**上执行 `uninstall_calico.sh`，用于清理每个节点上残留的 Calico 网络资源。包括其 CNI 配置文件，iptables 规则等。

```bash
chmod +x ./uninstall_calico.sh
./uninstall_calico.sh
```

3. 为了快速让存量业务 Pod 快速接入到 Cilium 网络中，有以下两种方式：

* 依次重启主机，彻底清除 Calico 的残留网络规则（优先推荐）。
* 如果无法重启主机，可以在每个节点上执行 `restartAllPods.sh`，这将重启所有 Pod 的 Sandbox 容器，让 Cilium 重新设置 Pod 网络。这不会重启业务容器，不会影响到业务容器的日志等。

```bash
chmod +x ./restartAllPods.sh
./restartAllPods.sh
```
 
## cilium 和 istio 一起工作 

当 istion 和 cilium 一起工作时， [官方文档](https://docs.cilium.io/en/latest/network/servicemesh/istio/) 说明需要进行双方的参数适配

- 在 cilium 安装过程中，打开 export INTEGRATE_ISTIO="true" 参数，会调整 cilium 的工作参数

- 在使用中，不要同时使用  cilium 和 istio 的 L7 HTTP policy

- 在 istio 使用 sidecar mode with automatic sidecar injection 功能时，如果和 cilium 的 隧道模式（VXLAN or GENEVE）一起工作，需要让 istiod pods 运行在 hostNetwork=true 模式，以便能够被 API server 访问


## 运维排障

- 运行命令 `./cilium/showStatus.sh` 查看集群中 cilium 的状态

- 运行命令 `cilium sysdump` 它会导出一个压缩包，包括集群中所有 cilium 的状态信息

- 抓包

    (1)监控节点本地的实时流量，它最完整，最底层，但是没法看到流量记录  `kubectl -n kube-system exec ds/cilium -- cilium-dbg monitor -vv`

    (2)查看实时流量和历史记录，它是通过 hubble 过滤了一道 ` kubectl -n kube-system exec ds/cilium -- hubble observe -f `

    (3)主机上使用 hubble， 查看整个集群的流量事件  `cilium hubble port-forward &`
  
    看所有流量 `hubble observe -f`
    
    看被拒绝的流量 `hubble observe --verdict DROPPED --verdict ERROR  -f`
    
    看某个 pod 的流量 ` hubble observe --since 3m --pod default/tiefighter -f`
   
