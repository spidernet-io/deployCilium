#!/bin/bash

set -x

INSTANCE_NAME=${INSTANCE_NAME:-"cilium"}
NAMESPACE=${NAMESPACE:-"kube-system"}
UNINSTALL_OLD_CILIUM_CRD=${UNINSTALL_OLD_CILIUM_CRD:-"true"}

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
