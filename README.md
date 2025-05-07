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

* 步骤1，准备

    （1）把整个工程拷贝到 master 节点上

    （2）确保已经安装了 K8S 集群（例如已经安装了 calico，或者没有安装任何网络插件）

* 步骤2，安装 cilium

    进入工程的 cilium 子目录下，运行如下命令，它会完成 CLI 的安装，以及 chart 的安装，并且，该脚本执行过程中，也会尝试卸载 calico

    ```bash
    POD_v4CIDR="172.16.0.0/16" POD_v4Block="24" \
    ENABLE_IPV6="false" POD_v6CIDR="fd00::/48" POD_v6Block="64" \
    CLUSTER_NAME="cluster1" CLUSTER_ID="10" \
    CLUSTERMESH_APISERVER_NODEPORT="31001" \
    K8S_API_IP="10.0.1.11" K8S_API_PORT="6443" \
    HUBBLE_WEBUI_NODEPORT_PORT="31000" \
    DISABLE_KUBE_PROXY="true" \
    UNINSTALL_OLD_CILIUM_CRD="true" \
    ./setup.sh
    ```

> 说明：
> *  POD_v4CIDR 是本集群的 POD IPv4 cidr，POD_v4Block 是每个 node 分割的 pod 小子网大小。注意，如果后续步骤需要实现多集群网络互联，请确保每个集群的 POD_v4CIDR 是不重叠的
> * ENABLE_IPV6 表示是否启用 IPv6，如果集群主机网卡没有配置 IPv6 地址，K8S集群没有开启双栈，请不开打开它
> * CLUSTER_NAME 表示本集群的名称，CLUSTER_ID 表示本集群的 ID（取值大小1-255 ）. 注意，运行本步骤后，只是做了多集群配置初始化，并未实现与其他集群互联，因此，请确保每一个集群的 CLUSTER_NAME 和 CLUSTER_ID 参数都是唯一的，这样才能在未来实现多集群联通时。
> * CLUSTERMESH_APISERVER_NODEPORT 是 cilium 的多集群互联的 nodePort 号，可手动指定一个在合法的 nodePort 范围内的地址（通常在 30000-32767 ）。注意，每一个集群设置的该参数必须是唯一的，否则多集群互联时会出问题。
> * K8S_API_IP 和 K8S_API_PORT 表示本集群 Kubernetes API 服务器的地址，它用于在不需要 kube-proxy 时，cilium 也能访问 api server，为集群提供 service 能力。因此，这个地址不能是 clusterIP，而必须是单个主机的 Kubernetes API 服务器的物理地址，或者通过 keepalived 等工具实现的高可用地址。
> * HUBBLE_WEBUI_NODEPORT_PORT 是 cilium 的可观测性 GUI 的 nodePort 号，可手动指定一个在合法的 nodePort 范围内的地址（通常在 30000-32767 ）
> * DISABLE_KUBE_PROXY 指示了是否要禁用 kube-proxy
> * UNINSTALL_OLD_CILIUM_CRD 指示了是否要卸载旧版本的 cilium CRD .  本脚本在运行时，会尝试 helm uninstall 集群中的存在的老 cilium 安装，因为 helm uninstall 不会卸载 CRD，因此，提供本变量来进行单独处理。老 CRD 的残留会出现的问题，例如，老的 POD cidr 会继续生效，不会遵循新安装中指定的 CIDR
> * cilium 遵循 K8S 集群的 clusterIP CIDR 设置。并且，cilium 在实现多集群互联时，允许不同集群的 clusterIP CIDR 是重叠的

* 步骤3，如果之前安装过 calico 等 CNI ，为了实现清除它们的 iptables 规则， 可以考虑把所有主机重启，确保 ciium 在一个干净的环境中工作 。
    并且，重启主机可以让所有的 POD 重启，接入 cilium 的网络 。

* 步骤4，完成 cilium 安装后，可运行如下命令，查看本集群 cilium 的状态

    ```bash
    ./showStatus.sh
    ```

    完成安装后，可通过 CLUSTERMESH_APISERVER_NODEPORT 的 nodePort 访问cilium 的报文可观测性 GUI

* 步骤5，可选，开启 cilium 的指标和 grafana 面板

    （1）确保安装 grafana 和 prometheus （需要依赖集群中已经安装了 grafana 和 prometheus 的 CRD ）

    （2）进入工程的 cilium 子目录下，运行如下命令，它会完成指标的开启，以及观测面板的开启

    ```bash
    ./setupMetrics.sh
    ```

    完成指标和观测面板的开启后，即可以在 grafana 上看到 cilium 相关的面板

* 步骤6，可选，实现多集群互联

    （1）创建 /root/clustermesh 目录，把本集群的 /root/.kube/config 拷贝到该目录下，命名为 /root/clustermesh/cluster1 ； 把本集群互联的目标集群的  /root/.kube/config 拷贝到该目录下，命名为 /root/clustermesh/cluster2

    （2）进入本工程的 cilium 子目录，运行如下命令，它会自动寻 /root/clustermesh 中的两个集群的配置，完成多集群互联的配置

    ```bash
    ./setupClusterMesh.sh
    ```

    （3）检查多集群互联状态

    进入工程的 cilium 子目录下，运行如下命令，它会检查多集群互联状态

    ```bash
    ./showClusterMesh.sh
    ```
