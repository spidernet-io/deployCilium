#!/bin/bash

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
    echo "Stop sandbox $sandbox for pod $POD_NAMESPACE/$POD_NAME"
done

echo "✅ All pods have been restarted"
