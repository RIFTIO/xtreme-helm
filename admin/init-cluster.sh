#!/bin/bash
# Once per cluster (idempotent): the shared, cluster-scoped pieces every xtreme
# tenant depends on. Needs cluster-admin.
#   - the Strimzi CRDs from xtreme/crds/
#   - ClusterRole xtreme-tenant-readonly (nodes/CRDs/storageclasses, get+list)
# Per-tenant objects are created by admin/mk-tenant.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== CRDs"
kubectl apply -f xtreme/crds/

echo "== shared read-only ClusterRole"
kubectl apply -f - <<Y
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: xtreme-tenant-readonly }
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list"]
- apiGroups: ["apiextensions.k8s.io"]
  resources: ["customresourcedefinitions"]
  verbs: ["get", "list"]
- apiGroups: ["storage.k8s.io"]
  resources: ["storageclasses"]
  verbs: ["get", "list"]
Y
echo "done."