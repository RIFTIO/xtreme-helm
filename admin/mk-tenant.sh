#!/bin/bash
# Per tenant (idempotent): namespaces, the chart's cluster-scoped RBAC and
# IngressClass, an installer ServiceAccount with a namespaced Role, and a
# kubeconfig for it. Needs cluster-admin; run admin/init-cluster.sh first.
#
# Usage: admin/mk-tenant.sh [-r release] <ns>[:<release>] [<ns>[:<release>] ...]
#   -r release   default release for entries without their own. Default: xtreme.
#   <ns>:<release>  per-tenant release. The release MUST match the --release that
#                tenant passes to install_xtreme (some charts name ServiceAccounts
#                after it). Helm release names are per-namespace, so tenants may
#                share one.
#   TENANT_SERVER=https://host:6443  overrides the API endpoint written into the
#                kubeconfig (needed when the admin kubeconfig is Rancher-proxied
#                and the auto-detected control-plane address isn't reachable).
set -euo pipefail
DEFAULT_RELEASE=xtreme
while getopts 'r:' o; do case $o in r) DEFAULT_RELEASE=$OPTARG;; *) exit 2;; esac; done
shift $((OPTIND-1))
[ $# -ge 1 ] || { echo "usage: $0 [-r release] <ns>[:<release>] [<ns>[:<release>] ...]" >&2; exit 2; }
cd "$(dirname "$0")/.."
OUT=admin/generated; mkdir -p $OUT
VALUES=(-f xtreme/aeo-values.yaml -f storage.yaml)

kubectl get clusterrole xtreme-tenant-readonly >/dev/null 2>&1 \
  || { echo "xtreme-tenant-readonly not found — run admin/init-cluster.sh first" >&2; exit 1; }

ADMIN_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
SERVER=$ADMIN_SERVER
if [[ "$SERVER" == */k8s/clusters/* ]]; then
  # The Rancher proxy does not accept ServiceAccount tokens; talk to the API server directly.
  CP_IP=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  SERVER=${TENANT_SERVER:-https://$CP_IP:6443}
  echo "admin kubeconfig is Rancher-proxied; tenant kubeconfigs will use $SERVER"
fi

tenant_role() {   # $1 = namespace, $2 = clusterrole names (newline-separated)
cat <<Y
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: xtreme-installer, namespace: $1 }
rules:
- apiGroups: ["", "apps", "batch", "extensions", "networking.k8s.io", "policy",
              "autoscaling", "coordination.k8s.io", "discovery.k8s.io"]
  resources: ["*"]
  verbs: ["*"]
- apiGroups: ["kafka.strimzi.io", "core.strimzi.io"]
  resources: ["*"]
  verbs: ["*"]
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles", "rolebindings"]
  verbs: ["*"]
# The chart creates RoleBindings that reference these ClusterRoles; RBAC only
# allows that if the creator holds every permission in them, or has 'bind' on them.
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["clusterroles"]
  verbs: ["bind"]
  resourceNames:
$(echo "$2" | sed 's/^/    - /')
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: xtreme-installer, namespace: $1 }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: xtreme-installer }
subjects: [{ kind: ServiceAccount, name: xtreme-installer, namespace: $NS }]
Y
}

for arg in "$@"; do
  NS=${arg%%:*}
  RELEASE=${arg#*:}; [ "$RELEASE" = "$arg" ] && RELEASE=$DEFAULT_RELEASE
  echo "==== tenant $NS (release $RELEASE)"
  for ns in $NS aeo-$NS; do
    kubectl create ns $ns --dry-run=client -o yaml | kubectl apply -f -
    kubectl label ns $ns app.kubernetes.io/managed-by=Helm --overwrite
    kubectl annotate ns $ns meta.helm.sh/release-name=xtreme meta.helm.sh/release-namespace=default --overwrite
  done

  # Cluster-scoped half of the chart, rendered exactly as the tenant will install it
  # (same release, per-namespace IngressClass) but with tenantMode off.
  helm template "$RELEASE" xtreme "${VALUES[@]}" --skip-crds \
      --set global.namespace.name=$NS --set global.ingress.class.namespaced=true \
    | yq ea 'select(.kind == "ClusterRole" or .kind == "ClusterRoleBinding" or .kind == "IngressClass")' - \
    > $OUT/$NS-cluster.yaml
  kubectl apply -f $OUT/$NS-cluster.yaml
  CR_NAMES=$(yq ea 'select(.kind=="ClusterRole") | .metadata.name' $OUT/$NS-cluster.yaml)

  {
  cat <<Y
apiVersion: v1
kind: ServiceAccount
metadata: { name: xtreme-installer, namespace: $NS }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: xtreme-tenant-readonly-$NS }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: xtreme-tenant-readonly }
subjects: [{ kind: ServiceAccount, name: xtreme-installer, namespace: $NS }]
Y
  tenant_role $NS "$CR_NAMES"
  tenant_role aeo-$NS "$CR_NAMES"
  } > $OUT/$NS-tenant.yaml
  kubectl apply -f $OUT/$NS-tenant.yaml

  TOKEN=$(kubectl -n $NS create token xtreme-installer --duration=8760h)
  CA=$(kubectl -n $NS get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}' | base64 -w0)
  cat > $OUT/$NS.kubeconfig <<Y
apiVersion: v1
kind: Config
clusters: [{name: xtreme, cluster: {server: $SERVER, certificate-authority-data: $CA}}]
users: [{name: $NS-installer, user: {token: $TOKEN}}]
contexts: [{name: $NS, context: {cluster: xtreme, user: $NS-installer, namespace: $NS}}]
current-context: $NS
Y
  chmod 600 $OUT/$NS.kubeconfig
  echo "$ADMIN_SERVER" > $OUT/$NS.server
  echo "$RELEASE"      > $OUT/$NS.release
  echo "tenant $NS ready: $OUT/$NS.kubeconfig  (install with: --ns $NS --release $RELEASE --tenant)"
done