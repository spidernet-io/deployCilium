#!/bin/bash

# clean calico k8s resources
# Running this on controller node
# Check if jq is installed
if ! command -v jq &>/dev/null; then
    echo "jq is not installed. Please install it first."
    exit 1
fi

# clean calico files
# Runing this on each node
rm -f /etc/cni/net.d/10-calico.conflist || true
rm -f /etc/cni/net.d/calico.kubeconfig || true
rm -f /opt/cni/bin/calico || true
iptables-save | grep -iv cali | iptables-restore

sandbox_list=$(nerdctl ps | grep pause | awk '{print $1}')
[ -n "$sandbox_list" ] || {
    echo "No any sandbox found"
    exit 0
}

echo "-----------------------------------------------------------"

for sandbox in $sandbox_list; do
    if [ -z "$sandbox" ]; then
        continue
    fi

    ip_address=$(nerdctl inspect $sandbox | jq -r '.[0].NetworkSettings.IPAddress')

    if [ -z "$ip_address" ] || [ "$ip_address" = "null" ]; then
        continue
    fi

    if ip addr show | grep "$ip_address" &>/dev/null; then
        continue
    fi

    POD_NAME=$(nerdctl inspect $sandbox | jq -r '.[0].Config.Labels."io.kubernetes.pod.name"')
    POD_NAMESPACE=$(nerdctl inspect $sandbox | jq -r '.[0].Config.Labels."io.kubernetes.pod.namespace"')

    if [ -z "$POD_NAME" ] || [ "$POD_NAME" = "null" ] || [ -z "$POD_NAMESPACE" ] || [ "$POD_NAMESPACE" = "null" ]; then
        continue
    fi

    nerdctl stop $sandbox >/dev/null 2>&1
    echo "✅ Stop sandbox $sandbox for pod $POD_NAMESPACE/$POD_NAME"
done

# 正常来说当 pause 停止后，其 net namespace 也会被删除，节点上的 calico 虚拟网卡也会被回收。但有一些极端条件下，ns 删除并不会导致其内网卡被
# 为了避免这种情况，再次执行手动删除
ip -br a | grep cali | awk -F '@' '{print $1}' | xargs -I {} ip l d {} >/dev/null 2>&1
