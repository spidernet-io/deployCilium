# deployCilium

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

如下步骤，会安装 Cilium 到 k8s 集群中。

1. 准备

    （1）如果是通过 kubespray 安装新集群，建议配置 `kube_network_plugin=cni` 参数。对于已安装 Calico 的集群，请在 Cilium 安装成功后，参考[卸载 Calico](#卸载-calico) 步骤卸载 Calico。

    （2）把整个工程拷贝到 master 节点上, 确保机器上有如下 CLI： helm、kubectl、jq
        注意: helm 版本最好高于 v3.17.3 ( 测试过 v3.9.4 就出现和 cilium chart 的语法兼容问题)

    （3）确保已经安装了 K8S 集群 
        
        如果是使用 kubespray 安装集群，指定 kube_network_plugin=cni 和 kube_proxy_remove=true 选项

     （4）留意 cilium 官方的 [系统要求](https://docs.cilium.io/en/stable/operations/system_requirements/#admin-system-reqs)   

2. 安装 cilium

    进入工程的 cilium 子目录下，运行如下命令，它会完成 CLI 的安装，以及 chart 的安装。 
    
    使用该方式安装的 cilium，默认工作在 vxlan 模式隧道下，且打开了所有能够兼容的所有其它功能

    它默认从 daocloud 在线仓库拉取镜像

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

> 说明：
> *  POD_v4CIDR 是本集群的 POD IPv4 cidr，POD_v4Block 是每个 node 分割的 pod 小子网大小。注意，如果后续步骤需要实现多集群网络互联，请确保每个集群的 POD_v4CIDR 是不重叠的
> * ENABLE_IPV6 表示是否启用 IPv6，如果集群主机网卡没有配置 IPv6 地址，K8S集群没有开启双栈，请不开打开它
> * CLUSTER_NAME 表示本集群的名称，CLUSTER_ID 表示本集群的 ID（取值大小1-255 ）. 注意，运行本步骤后，只是做了多集群配置初始化，并未实现与其他集群互联，因此，请确保每一个集群的 CLUSTER_NAME 和 CLUSTER_ID 参数都是唯一的，这样才能在未来实现多集群联通时。
> * CLUSTERMESH_APISERVER_NODEPORT 是 cilium 的多集群互联的 nodePort 号，可手动指定一个在合法的 nodePort 范围内的地址（通常在 30000-32767 ）。注意，每一个集群设置的该参数必须是唯一的，否则多集群互联时会出问题。
> * K8S_API_IP 和 K8S_API_PORT 表示本集群 Kubernetes API 服务器的地址，它用于在不需要 kube-proxy 时，cilium 也能访问 api server，为集群提供 service 能力。因此，这个地址不能是 clusterIP，而必须是单个主机的 Kubernetes API 服务器的物理地址，或者通过 keepalived 等工具实现的高可用地址。
> * HUBBLE_WEBUI_NODEPORT_PORT 是 cilium 的可观测性 GUI 的 nodePort 号，可手动指定一个在合法的 nodePort 范围内的地址（通常在 30000-32767 ）
> * cilium 遵循 K8S 集群的 clusterIP CIDR 设置。并且，cilium 在实现多集群互联时，允许不同集群的 clusterIP CIDR 是重叠的
> * INTEGRATE_ISTIO 表示是否 istio 会工作在 cilium 网络中，如果是 true ，会为调优 cilium 的工作参数

3. 完成 cilium 安装后，可运行如下命令，查看本集群 cilium 的状态

    ```bash
    chmod +x ./showStatus.sh
    ./showStatus.sh
    ```

    完成安装后，可通过 CLUSTERMESH_APISERVER_NODEPORT 的 nodePort 访问cilium 的报文可观测性 GUI

4. (可选) 卸载 Calico

    如果您的集群已经安装 Calico，参考[卸载 Calico](#卸载-calico) 步骤卸载 Calico。

5. (可选) 卸载 kube-proxy

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

6. (可选) 开启 cilium 的指标和 grafana 面板

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

7. (可选) 实现多集群互联

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
   
