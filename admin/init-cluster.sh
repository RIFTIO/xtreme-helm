#!/bin/bash
# Once per cluster (idempotent): the shared, cluster-scoped pieces every xtreme
# tenant depends on. Needs cluster-admin.
#   - the Strimzi CRDs from xtreme/crds/
#   - ClusterRole xtreme-tenant-readonly (admin/manifests/tenant-readonly-clusterrole.yaml)
# Per-tenant objects are created by admin/mk-tenant.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== CRDs"
kubectl apply -f xtreme/crds/

echo "== shared read-only ClusterRole"
kubectl apply -f admin/manifests/tenant-readonly-clusterrole.yaml
echo "done."