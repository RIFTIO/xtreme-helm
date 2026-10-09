#!/bin/bash
# Removes everything mk-tenant.sh created for each <ns>. Leaves the shared pieces
# from init-cluster.sh (CRDs, xtreme-tenant-readonly) in place.
# Usage: admin/rm-tenant.sh <ns>[:<release>] [<ns>[:<release>] ...]  (release part is ignored)
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: $0 <ns>[:<release>] [<ns>[:<release>] ...]" >&2; exit 2; }
cd "$(dirname "$0")/.."
OUT=admin/generated
CUR=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
for arg in "$@"; do
  NS=${arg%%:*}
  if [ -f $OUT/$NS.server ] && [ "$CUR" != "$(cat $OUT/$NS.server)" ]; then
    echo "current context is $CUR but tenant $NS was created on $(cat $OUT/$NS.server) — skipping" >&2
    continue
  fi
  echo "==== removing tenant $NS"
  [ -f $OUT/$NS-cluster.yaml ] && kubectl delete -f $OUT/$NS-cluster.yaml --ignore-not-found
  kubectl delete clusterrolebinding xtreme-tenant-readonly-$NS --ignore-not-found
  kubectl delete ns $NS aeo-$NS --ignore-not-found
  rm -f $OUT/$NS-cluster.yaml $OUT/$NS-tenant.yaml $OUT/$NS.kubeconfig $OUT/$NS.server $OUT/$NS.release
done