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

## 部署 

如下步骤，会安装 cilium 到 k8s 集群中

1. 准备

    （1）把整个工程拷贝到 master 节点上, 确保机器上有如下 CLI： helm、kubectl、jq

    （2）确保已经安装了 K8S 集群 
        
        如果是使用 kubespray 安装集群，可带上 kube_network_plugin=cni 选项

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

3. 完成 cilium 安装后，可运行如下命令，查看本集群 cilium 的状态

    ```bash
    chmod +x ./showStatus.sh
    ./showStatus.sh
    ```

    完成安装后，可通过 CLUSTERMESH_APISERVER_NODEPORT 的 nodePort 访问cilium 的报文可观测性 GUI

4. （可选）如有必要，可以杀掉所有的 POD， 让它们快速接入 cilium 的网络

    ```bash
    chmod +x restartAllPods.sh
    ./restartAllPods.sh
    ```

5. (可选) 开启 cilium 的指标和 grafana 面板

    （1）确保安装 grafana 和 prometheus （需要依赖集群中已经安装了 grafana 和 prometheus 的 CRD ）

    （2）进入工程的 cilium 子目录下，运行如下命令，它会完成指标的开启，以及观测面板的开启

    ```bash
    chmod +x ./setupMetrics.sh
    ./setupMetrics.sh
    ```

    完成指标和观测面板的开启后，即可以在 grafana 上看到 cilium 相关的面板

6. (可选) 实现多集群互联

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

## 卸载

```bash
chmod +x ./uninstall.sh
./uninstall.sh
```
