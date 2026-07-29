#!/bin/bash
set -euo pipefail


log_info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*" >&2; }
log_warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" >&2; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

while [[ $# -gt 0 && "$1" =~ ^-- ]]; do
    case $1 in
        --ns)     NS=$2; shift;;
        *) help;;
    esac
    shift
done


namespace=$NS

log_info "deleting old crds"
( kubectl get crd  | awk '/kafka|strimzi/ { print $1 }' | xargs --no-run-if-empty kubectl delete crd )&
sleep 10
./bin/clear-stuck-crd-finalizers.sh
wait
log_info "deleting pvc data"
#kubectl get pvc  -A  | awk '/data-rw-grafan|data-dzs-sdnc-influxdb-0/ { print $1 }' | xargs -n 1 --no-run-if-empty kubectl delete pvc -n namespace
kubectl get pvc -n $namespace | awk '/data-0-zhone-strimzi-kafka-broker-0/ { print $1 }' | xargs --no-run-if-empty kubectl delete pvc -n $namespace 
kubectl get pvc -n $namespace | awk '/data-0-zhone-strimzi-kafka-controller-1/ { print $1 }' | xargs --no-run-if-empty kubectl delete pvc -n $namespace
log_info " deleting clusterrolebinding..."
kubectl delete clusterrolebinding $namespace-strimzi-cluster-operator || true
log_info "applying new CRDs"
kubectl apply -f ./xtreme/crds
