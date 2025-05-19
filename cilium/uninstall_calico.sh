#!/bin/bash

# clean calico k8s resources
# Running this on controller node
# Check if jq is installed

# clean calico files
# Runing this on each node
rm -f /etc/cni/net.d/10-calico.conflist || true
rm -f /etc/cni/net.d/calico.kubeconfig || true
rm -f /opt/cni/bin/calico || true
iptables-save | grep -iv cali | iptables-restore

# 正常来说当 pause 停止后，其 net namespace 也会被删除，节点上的 calico 虚拟网卡也会被回收。但有一些极端条件下，ns 删除并不会导致其内网卡被
# 为了避免这种情况，再次执行手动删除
ip -br a | grep cali | awk -F '@' '{print $1}' | xargs -I {} ip l d {} >/dev/null 2>&1
