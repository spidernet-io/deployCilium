# 集群带宽限制

![集群带宽限制](./bandwidth.png)

## ingress

1. 选一个节点作为 ingressNode ，实现入口流量限流。
    
    - 它上没没有运行 istio-gateway ( 发现如果部署在同节点，流量不通)，它需要一张额外的物理网卡来引导入口流量（这张网卡将不会运行 cilium 的 kubeproxy replacement ，否则 它的 nodeport ebpf 解析会体现生效）

    - 对选择的这个 ingressNode，实现入口流量限流。 节点，配置 如下 cilium 配置，去除掉 用于引到 入口流量的 网卡 

```bash
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNodeConfig
metadata:
  namespace: kube-system
  name: disable-nodeport
spec:
  nodeSelector:
    matchLabels:
      # 设置为入口流量节点的 label
      kubernetes.io/hostname: "ingressNode"
  defaults:
    # 如下设置的网卡是除了用于引到流量以外的其他所有主机的物理网卡
    devices: "eth1,eth2,....（不能有 用于引导流量的 macvlan 父网卡）"
EOF
```

2. 在 cilium 上设置 Loadbalancer ip 池，但是，不要使用 arp 或者 bgp crd 来发布它 ！

```bash
# ip 地址池 应该是 入口流量网卡的 子网，其中的ip 没人使用 
cat <<EOF | kubectl apply -f -
apiVersion: "cilium.io/v2alpha1"
kind: CiliumLoadBalancerIPPool
metadata:
  name: 13-ipv4
spec:
  blocks:
  - start: "172.16.13.90"
    stop: "172.16.13.99"
EOF
```

3. 在入口流量节点 ingressNode 上启动一个 spiderpool 的 macvlan pod，它内部具有一张 macvlan 和 veth 网卡
    在 macvlan 网卡内部 运行如下脚本 ingress.sh 

```shell
# ingress-ip 是 istio gateway 的 Loadbalancer ip
# via-ip 是 宿主机的 ip
# via-mac 是本pod 在宿主机侧的 veth 网卡的 mac
# total-bandwidth 设置集群总的入口带宽 ， 单位是 Mbit 或者 Gbit
# tc-rule 设置一个 istio gateway 的 Loadbalancer ip 入口 端口的限流规则，格式 "port[,port]...:bandwidth"

 ./ingress.sh  \
 	--ingress-ip "172.16.13.90"  \
 	--ingress-interface "eth0" \
 	--egress-interface "veth" \
 	--via-ip "172.16.13.11" \
 	--via-mac "08:00:27:bb:01:14" \
 	--total-bandwidth "300Mbit" \
 	--tc-rule "80:10Mbit"  \
 	--tc-rule "443,900:20Mbit"


# 查看生效规则
 ./ingress.sh show
```


## 集群 egress 带宽限制


1. 针对 cilium 出口网关 节点上，配置如下对象，重启节点的 cilium agent，让其关闭 Bandwidth ，这样才能避免 cilium 设置 tc 规则 
    配置完成后，冲洗 对应的 出口网关节点


``` bash
~# tc qdis show dev eth1
    qdisc fq 833a: root refcnt 2 limit 10000p flow_limit 100p buckets 32768 orphan_mask 1023 quantum 3028b initial_quantum 15140b low_rate_threshold 550Kbit refill_delay 40ms timer_slack 10us horizon 2s horizon_cap
```

```shell
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNodeConfig
metadata:
  namespace: kube-system
  name: disable-bandwidth
spec:
  nodeSelector:
    matchLabels:
      kubernetes.io/hostname: "worker4"
  defaults:
    enable-bandwidth-manager: "false"
EOF

```

2. 为不同租户的 pod 创建 出口网关策略，让它们出集群的流量都走出口网关节点的 ，使用 指定的 egressIP 源 ip 

```bash
TENATN_NAME="default"
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: tenant-${TENATN_NAME}
spec:
  selectors:
  - podSelector:
      matchLabels:
        # 如下 label 命中整个租户下的 pod 
        io.kubernetes.pod.namespace: ${TENATN_NAME}
  destinationCIDRs:
    - "0.0.0.0/0"
  egressGateway:
    nodeSelector:
      matchLabels:
        # 设置出口网关节点的 label
        kubernetes.io/hostname: worker4
    # 该 ip 必须是 出口网关节点的 默认路由网卡 的 同子网 ip （该ip未被使用）
    egressIP: 172.16.1.49
EOF

#查看节点上 agent 的生效情况
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf egress list

```

3. 在出口网关节点上，运行如下脚本 egress.sh ，实现配置 网卡上的 带宽限制 


```shell
# egress-interface 是出口网卡，它应该是默认路由的网卡
# egress-total-bandwidth 控制的是总的出口带宽
# egress-ip-bandwidth 设置了 每个 ip 的出口带宽，每个ip可以对应到一个或者多个租户来使用，每个ip后边带着针对该 ip 的出口带宽限制
 ./egress.sh \
     --egress-interface eth1 \
     --egress-total-bandwidth "1Gbit" \
     --egress-ip-bandwidth "172.16.1.49:200Mbit" \
     --egress-ip-bandwidth "172.16.1.50,172.16.1.51:300Mbit"
```

