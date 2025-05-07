#!/bin/bash

# 安装 Prometheus 和 grafana 后， 此脚本开启所有的 metrics， 下发 grafana 面板
#可先安装crd ： kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml

set -x
set -o errexit
set -o nounset
set -o pipefail


CURRENT_FILENAME=$( basename $0 )
CURRENT_DIR_PATH=$(cd $(dirname $0); pwd)


INSTANCE_NAME=${INSTANCE_NAME:-"cilium"}
NAMESPACE=${NAMESPACE:-"kube-system"}
# grafana 默认只导入 其租户下的 面板， 否则，会看不到 grafana 中的面板
GRAFANA_NAMESPACE=${GRAFANA_NAMESPACE:-"prometheus"}

source ${CURRENT_DIR_PATH}/version.sh

CHART_HTTP_PROXY=${CHART_HTTP_PROXY:-""}
if [ -n "$CHART_HTTP_PROXY" ] ; then
    echo "use proxy $CHART_HTTP_PROXY to pull chart " >&2
    export https_proxy=$CHART_HTTP_PROXY
else
    echo "no http proxy" >&2
fi
export CHART_HTTP_PROXY=${CHART_HTTP_PROXY}


CHART_PATH="cilium/cilium"
if [ -f "${CURRENT_DIR_PATH}/chart/cilium-${CILIUM_VERSION}.tgz" ] ; then
    CHART_PATH="${CURRENT_DIR_PATH}/chart/cilium-${CILIUM_VERSION}.tgz"
    echo "use local chart ${CHART_PATH}"
else 
    CHART_REPO="https://helm.cilium.io"
    helm repo add cilium ${CHART_REPO} || true
    helm repo update cilium
fi


#==========================

cat <<EOF > /tmp/cilium-metrics.yaml
# for DCE insight
commonLabels:
  operator.insight.io/managed-by: insight

hubble:
  metrics:
    serviceMonitor:
      enabled: true

    # for more
    # https://github.com/isovalent/grafana-dashboards/tree/main/dashboards/cilium-policy-verdicts
    # https://github.com/isovalent/cilium-grafana-observability-demo/blob/main/helm/cilium-values.yaml
    # https://docs.cilium.io/en/latest/observability/grafana/
    # 定制 flow 中的 metric
    enabled: ["dns:query;ignoreAAAA", "drop", "tcp", "flow", "port-distribution", "icmp", "httpV2:exemplars=true;labelsContext=source_ip,source_namespace,source_workload,destination_ip,destination_namespace,destination_workload,traffic_direction"]
    # enabled: ["dns:query;ignoreAAAA", "drop", "tcp", "flow", "icmp", "http"]

    dashboards:
      enabled: true
      namespace: ${GRAFANA_NAMESPACE}

    enableOpenMetrics: true
    dynamic:
      # Cannot configure both static and dynamic Hubble metrics
      enabled: false
  
  relay:
    prometheus:
      enabled: true
      serviceMonitor:
        enabled: true

prometheus:
  enabled: true
  metricsService: true
  serviceMonitor:
    enabled: true

operator:
  prometheus:
    enabled: true
    metricsService: true
    serviceMonitor:
      enabled: true
  dashboards:
    enabled: true
    namespace: ${GRAFANA_NAMESPACE}

dashboards:
  enabled: true
  namespace: ${GRAFANA_NAMESPACE}

envoy:
  prometheus:
    enabled: true
    serviceMonitor:
      enabled: true

EOF

# --reuse-values 只能用于版本不变情况下的功能变更
# 在版本升级时，应该在导出老 helm 配置基础上，来编辑 values  ， helm get values cilium --namespace=kube-system -o yaml > old-values.yaml 
#  在版本升级时，不能使用 --reuse-values ， 它会导致新版本的 新values 不会生效
# When upgrading from one minor release to another minor release using helm upgrade, do not use Helm’s --reuse-values flag. The --reuse-values flag ignores any newly introduced values present in the new release and thus may cause the Helm template to render incorrectly

helm upgrade ${INSTANCE_NAME} ${CHART_PATH} \
  --debug  --atomic --version $CILIUM_VERSION  \
  -n ${NAMESPACE} \
  --reuse-values \
  -f /tmp/cilium-metrics.yaml


