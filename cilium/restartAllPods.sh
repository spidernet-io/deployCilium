#!/bin/bash

RESTART_MIN=${1:-""}
if [ -n "$RESTART_MIN" ] && ! expr $RESTART_MIN + 1 &>/dev/null ; then
    echo "input number"
    exit 1
fi

if [ -z "$RESTART_MIN" ] ; then
    ALL_PODS=`kubectl get pod -o wide -A | sed '1 d' | awk '{printf "%s,%s=%s\n",$1,$2,$5}' `
    echo "-------- restart all pods"
else
    ALL_PODS=`kubectl get pod -o wide -A | sed '1 d' | grep -v Running | awk '{printf "%s,%s=%s\n",$1,$2,$5}' `
    echo "-------- restart not-running pods who restarted $RESTART_MIN time at least"
fi
[ -n "$ALL_PODS" ]  || exit 1

FAILED_FILE=/tmp/failed
rm -f $FAILED_FILE || true

for LINE in $ALL_PODS ; do
    NS_NAME=${LINE%=*}
    NS_NAME=${NS_NAME//,/ }
    RESTART_NUM=${LINE#*=}
    if [ -n "$RESTART_MIN" ] && (( RESTART_NUM >= RESTART_MIN )) ; then
        echo "delete pod $NS_NAME , restart $RESTART_NUM "
    elif [ -z "$RESTART_MIN" ] ; then
        echo "delete pod $NS_NAME , restart $RESTART_NUM "
    else
        echo "ingore pod $NS_NAME , restart $RESTART_NUM "
        continue
    fi
    # api server may be down
    ( kubectl delete pod -n ${NS_NAME} --force --grace-period=0  --wait=false || touch $FAILED_FILE )&
done
wait

if [ -f "$FAILED_FILE" ] ; then
  echo "-------- failed"
	exit 1
else
  echo "-------- succeed"
	exit 0
fi
