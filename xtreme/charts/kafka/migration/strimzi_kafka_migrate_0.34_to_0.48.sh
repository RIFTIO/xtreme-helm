#!/usr/bin/env bash
# strimzi_migrate_0.34_to_0.48.sh
#
# Migrate single-node Strimzi Kafka cluster from 0.34.x -> 0.48.0 (stepwise).
# - Backups (CRs exported )
# - Upgrade CRDs & Operator to 0.38.0 (compat step)
# - Upgrade Operator to 0.45.0 and prepare KRaft migration
# - Annotate Kafka CR to perform KRaft migration
# - Remove zookeeper section once migration completed
# - Upgrade CRDs & Operator to 0.48.0
#
# Read the script thoroughly before running. Run on the kubectl context for your cluster.
set -euo pipefail
IFS=$'\n\t'

########################
# Defaults (editable)
########################
DEFAULT_NAMESPACE="default"
DEFAULT_KAFKA_CR_NAME="dzs-strimzi"
NEW_KAFKA_CR_NAME="zhone-strimzi"
OPERATOR_DEPLOYMENT="dzs-strimzi-operator"
NEW_OPERATOR_DEPLOYMENT="zhone-strimzi-operator"
KAFKA_VERSION="3.4.0"
WORKDIR="/tmp/strimzi-upgrade-$$"
ORG_VER="0.34.0"
STEP1_VER="0.38.0"
STEP2_VER="0.45.0"
TARGET_VER="0.48.0"

HELM_RELEASE_NAME="xtreme"
HELM_NAMESPACE="default"


# keep other env vars (can still be overridden externally)
OPERATOR_DEPLOYMENT="${OPERATOR_DEPLOYMENT}"
KAFKA_VERSION="${KAFKA_VERSION}"
WORKDIR="${WORKDIR}"

########################
# Helpers
########################

die(){ echo "ERROR: $*" >&2; exit 1; }
info(){ echo -e "\n\033[1;34mINFO:\033[0m $*\n"; }
warn(){ echo -e "\n\033[1;33mWARN:\033[0m $*\n"; }
confirm(){ read -r -p "$* [y/N]: " _resp; [[ "$_resp" =~ ^[Yy] ]] ; }

kubectl_ns() { kubectl -n "$NAMESPACE" "$@"; }


wait_for_deploy_ready() {
local deploy="$1"
local timeout="${2:-600}"
info "Waiting up to ${timeout}s for Deployment/$deploy to have available replicas..."
local start=$SECONDS
while true; do
local ready
ready="$(kubectl_ns get deploy "$deploy" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
if [[ "$ready" != "" && "$ready" != "0" ]]; then
info "Deployment/$deploy is available"
break
fi
if (( SECONDS - start > timeout )); then
die "Timeout waiting for Deployment/$deploy to be ready"
fi
sleep 5
done
}


wait_for_kafka_ready() {
local timeout="${1:-900}"
info "Waiting for Kafka CR/$KAFKA_CR_NAME to show Ready condition..."
local start=$SECONDS
while true; do
local ready
ready="$(kubectl_ns get kafka "$KAFKA_CR_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
if [[ "$ready" == "True" ]]; then
info "Kafka/$KAFKA_CR_NAME Ready"
break
fi
if (( SECONDS - start > timeout )); then
kubectl_ns get kafka "$KAFKA_CR_NAME" -o yaml || true
die "Timeout waiting for Kafka/$KAFKA_CR_NAME to become Ready"
fi
sleep 8
done
}

wait_for_new_kafka_ready() {
local timeout="${1:-900}"
info "Waiting for Kafka CR/$NEW_KAFKA_CR_NAME to show Ready condition..."
local start=$SECONDS
while true; do
local ready
ready="$(kubectl_ns get kafka "$NEW_KAFKA_CR_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
if [[ "$ready" == "True" ]]; then
info "Kafka/$NEW_KAFKA_CR_NAME Ready"
break
fi
if (( SECONDS - start > timeout )); then
kubectl_ns get kafka "$NEW_KAFKA_CR_NAME" -o yaml || true
die "Timeout waiting for Kafka/$NEW_KAFKA_CR_NAME to become Ready"
fi
sleep 8
done
}


wait_for_kafka_metadata_migration_status() {
local timeout="${1:-600}"
info "Waiting for Kafka CR/$KAFKA_CR_NAME  metadataState to be KRaftPostMigration or KRaft condition..."
local start=$SECONDS
while true; do
local state
state="$(kubectl_ns get kafka "$KAFKA_CR_NAME" -o jsonpath='{.status.kafkaMetadataState}' 2>/dev/null || true)"
info "Kafka/$KAFKA_CR_NAME $state"
if [[ "$state" == "KRaftPostMigration" || "$state" == "KRaft" ]]; then
info "Kafka/$KAFKA_CR_NAME $state"
break
fi
if (( SECONDS - start > timeout )); then
kubectl_ns get kafka "$KAFKA_CR_NAME" -o yaml || true
die "Timeout waiting for Kafka/$KAFKA_CR_NAME MetadataState to become KRaftPostMigration or KRaft "
fi
sleep 8
done
}


apply_crds_from_release() {
local ver="$1"
local tmp="$WORKDIR/$ver"
info "Downloading Strimzi $ver artifacts..."
mkdir -p "$tmp"
pushd "$tmp" >/dev/null
if ! curl -sSfL -o "strimzi-${ver}.zip" "https://github.com/strimzi/strimzi-kafka-operator/releases/download/${ver}/strimzi-${ver}.zip"; then
die "Failed to download Strimzi release zip for version ${ver}. Please verify URL and connectivity."
fi
unzip -q "strimzi-${ver}.zip"
# Try the common install paths
if [[ -d "strimzi-kafka-operator-${ver}/install/cluster-operator" ]]; then
kubectl apply -f "strimzi-kafka-operator-${ver}/install/cluster-operator"
elif [[ -d "strimzi-${ver}/install/cluster-operator" ]]; then
kubectl apply -f "strimzi-${ver}/install/cluster-operator"
else
die "CRDs directory not found in downloaded release for ${ver}"
fi
popd >/dev/null
info "Applied ${ver} CRDs"
}


upgrade_operator_image() {
  local ver="$1"
  local image="quay.io/strimzi/operator:${ver}"
  info "Patching Deployment/$OPERATOR_DEPLOYMENT to image ${image} in namespace ${NAMESPACE}..."

  # Define version-specific Kafka image mappings
  local kafka_images=""
  local kafka_bridge_image=""
  local default_kafka_version=""
  local default_kafka_image=""
  local connect_images=""
  local mm_images=""
  local mm2_images=""
  local jmx_trans_image=""
  local kaniko_executor_image=""
  local maven_builder_image=""

  case "$ver" in
    "0.38.0")
      kafka_images=3.5.0=quay.io/strimzi/kafka:0.38.0-kafka-3.5.0,3.5.1=quay.io/strimzi/kafka:0.38.0-kafka-3.5.1,3.6.0=quay.io/strimzi/kafka:0.38.0-kafka-3.6.0
      kafka_bridge_image=quay.io/strimzi/kafka-bridge:0.27.0
      default_kafka_version=3.6.0
      KAFKA_VERSION=3.6.0
      default_kafka_image=quay.io/strimzi/kafka:0.38.0-kafka-3.6.0
      connect_images=$kafka_images
      mm_images=$kafka_images
      mm2_images=$kafka_images
      jmx_trans_image=quay.io/strimzi/jmxtrans:0.38.0
      kaniko_executor_image=quay.io/strimzi/kaniko-executor:0.38.0
      maven_builder_image=quay.io/strimzi/maven-builder:0.38.0
      ;;

    "0.45.0")
    kafka_images=3.8.0=quay.io/strimzi/kafka:0.45.0-kafka-3.8.0,3.8.1=quay.io/strimzi/kafka:0.45.0-kafka-3.8.1,3.9.0=quay.io/strimzi/kafka:0.45.0-kafka-3.9.0
    kafka_bridge_image=quay.io/strimzi/kafka-bridge:0.31.1
    default_kafka_version=3.9.0
    KAFKA_VERSION=3.9.0
    default_kafka_image=quay.io/strimzi/kafka:0.45.0-kafka-3.9.0
    connect_images=$kafka_images
    mm_images=$kafka_images
    mm2_images=$kafka_images
    jmx_trans_image=quay.io/strimzi/jmxtrans:0.45.0
    kaniko_executor_image=quay.io/strimzi/kaniko-executor:0.45.0
    maven_builder_image=quay.io/strimzi/maven-builder:0.45.0
      ;;
  "0.48.0")
      kafka_images=4.0.0=quay.io/strimzi/kafka:0.48.0-kafka-4.0.0,4.1.0=quay.io/strimzi/kafka:0.48.0-kafka-4.1.0
      kafka_bridge_image=quay.io/strimzi/kafka-bridge:0.33.1
      default_kafka_version=4.1.0
      KAFKA_VERSION=4.1.0
      default_kafka_image=quay.io/strimzi/kafka:0.48.0-kafka-4.1.0
      connect_images=$kafka_images
      mm_images=$kafka_images
      mm2_images=$kafka_images
      jmx_trans_image=quay.io/strimzi/jmxtrans:0.48.0
      kaniko_executor_image=quay.io/strimzi/kaniko-executor:0.48.0
      maven_builder_image=quay.io/strimzi/maven-builder:0.48.0
      ;;
    *)
      warn "No specific image mappings defined for Strimzi ${ver}. Keeping existing env vars."
      ;;
  esac

  echo "Updating STRIMZI_KAFKA_IMAGES and related env vars for Strimzi ${ver}..."

  kubectl -n "${NAMESPACE}" set env deployment/"${OPERATOR_DEPLOYMENT}" \
    STRIMZI_KAFKA_IMAGES="${kafka_images}" \
    STRIMZI_DEFAULT_KAFKA_VERSION="${default_kafka_version}" \
    STRIMZI_KAFKA_CONNECT_IMAGES="${kafka_images}" \
    STRIMZI_KAFKA_MIRROR_MAKER_IMAGES="${kafka_images}" \
    STRIMZI_KAFKA_MIRROR_MAKER_2_IMAGES="${kafka_images}" \
    STRIMZI_KAFKA_MIRROR_MAKER_2_IMAGES="${kafka_images}" \
    STRIMZI_DEFAULT_TLS_SIDECAR_ENTITY_OPERATOR_IMAGE="${default_kafka_image}" \
    STRIMZI_DEFAULT_KAFKA_EXPORTER_IMAGE="${default_kafka_image}" \
    STRIMZI_DEFAULT_CRUISE_CONTROL_IMAGE="${default_kafka_image}" \
    STRIMZI_DEFAULT_TOPIC_OPERATOR_IMAGE="${image}" \
    STRIMZI_DEFAULT_USER_OPERATOR_IMAGE="${image}" \
    STRIMZI_DEFAULT_KAFKA_INIT_IMAGE="${image}" \
    STRIMZI_DEFAULT_KAFKA_BRIDGE_IMAGE="${kafka_bridge_image}" \
    STRIMZI_DEFAULT_JMXTRANS_IMAGE="${jmx_trans_image}" \
    STRIMZI_DEFAULT_KANIKO_EXECUTOR_IMAGE="${kaniko_executor_image}" \
    STRIMZI_DEFAULT_MAVEN_BUILDER="${maven_builder_image}"


  echo "✅ Environment variables updated successfully."

  # Patch operator image
  kubectl_ns patch deploy "$OPERATOR_DEPLOYMENT" \
    --type='json' \
    -p="[{\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/image\", \"value\": \"${image}\"}]"
# Helper function: safely update or add an environment variable
  update_env_var() {
    local var_name="$1"
    local var_value="$2"
    local req_param=""
    local cmd="$OPERATOR_DEPLOYMENT"+"-o jsonpath="+"{.spec.template.spec.containers[0].env[?(@.name=='${var_name}')].name}"
    info " cmd : ${cmd} "
    if kubectl_ns get deploy "$OPERATOR_DEPLOYMENT" -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name=='${var_name}')].name}" | grep -q "$var_name"; then
      info "Updating ${var_name}"
      req_param="[{'op': 'replace', 'path': \"/spec/template/spec/containers/0/env/'${var_name}'\", 'value': '${var_value}'}]"

      info " request comand : kubectl_ns patch deploy ${$OPERATOR_DEPLOYMENT} type=json -p=${req_param}"
      kubectl_ns patch deploy "$OPERATOR_DEPLOYMENT" \
        --type='json' \
        -p="[{'op': 'replace', 'path': \"/spec/template/spec/containers/0/env/$(kubectl_ns get deploy $OPERATOR_DEPLOYMENT -o jsonpath=\"{.spec.template.spec.containers[0].env[*].name}\" | tr ' ' '\n' | nl | grep \"$var_name\" | awk '{print $1-1}')/value\", 'value': '${var_value}'}]"
    else
      info "Adding ${var_name}"
      kubectl_ns patch deploy "$OPERATOR_DEPLOYMENT" \
        --type='json' \
        -p="[{'op': 'add', 'path': '/spec/template/spec/containers/0/env/-', 'value': {'name': '${var_name}', 'value': '${var_value}'}}]"
    fi
  }


  wait_for_deploy_ready "$OPERATOR_DEPLOYMENT"
  info "Operator upgraded to ${image} with updated Kafka image environment variables."
}



backup_crs_and_pvcs() {
local outdir="${WORKDIR}/backups-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$outdir"
info "Backing up Kafka CR and related CRs to ${outdir}"
kubectl_ns get kafka "$KAFKA_CR_NAME" -o yaml > "${outdir}/kafka-${KAFKA_CR_NAME}.yaml" || warn "Failed to export Kafka CR"
kubectl_ns get kafkatopic -o yaml > "${outdir}/kafkatopics.yaml" || warn "Failed to export KafkaTopics"
kubectl_ns get kafkauser -o yaml > "${outdir}/kafkausers.yaml" || warn "Failed to export KafkaUsers"
kubectl_ns get kafkaconnect -o yaml > "${outdir}/kafkaconnects.yaml" || true
info "Backups recorded in ${outdir}"
}


ensure_operator_running() {
  info "Ensure the Strimzi operator deployment exists in namespace ${NAMESPACE}"
  if ! kubectl_ns get deploy "$OPERATOR_DEPLOYMENT" >/dev/null 2>&1; then
    die "Deployment/$OPERATOR_DEPLOYMENT not found in namespace ${NAMESPACE}. Install or correct the deployment name before proceeding."
  fi
  wait_for_deploy_ready "$OPERATOR_DEPLOYMENT"
}


display_current_date_time(){
current_date_time="`date +%Y%m%d%H%M%S`";
echo $current_date_time;
}


########################
# Consolidated RBAC function
# - Applies a single ClusterRole containing all required rules
# - Binds it to the operator's ServiceAccount
# - Ensures a namespaced RoleBinding is present
########################
apply_consolidated_rbac() {
local phase_name="${1:-general}"
info "Applying consolidated RBAC for phase: ${phase_name}"


# Detect operator ServiceAccount
local sa_name
sa_name="$(kubectl_ns get deploy "$OPERATOR_DEPLOYMENT" -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || true)"
if [[ -z "$sa_name" ]]; then
warn "Could not detect serviceAccountName on deployment/${OPERATOR_DEPLOYMENT}. Defaulting to 'strimzi-cluster-operator'."
sa_name="strimzi-cluster-operator"
fi


info " operator ServiceAccount found.."

# Ensure ServiceAccount exists
if ! kubectl_ns get sa "$sa_name" >/dev/null 2>&1; then
info "Creating ServiceAccount/${sa_name} in ${NAMESPACE}"
kubectl_ns create sa "$sa_name" || die "Failed to create serviceaccount ${sa_name}"
fi


info " creating cluster role resource started "

# Consolidated ClusterRole name (unique per phase to avoid collisions)
local cr_name="strimzi-migration-${phase_name}-cr"
local crb_name="strimzi-migration-${phase_name}-crb-${NAMESPACE}-${sa_name}"
local ns_rb_name="strimzi-migration-${phase_name}-nsrb-${NAMESPACE}"


# Create a single ClusterRole that includes all needed permissions (idempotent via kubectl apply)
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${cr_name}
rules:
- apiGroups: ["kafka.strimzi.io"]
  resources: ["kafkanodepools","kafkanodepools/status","kafkanodepools/finalizers"]
  verbs: ["get","list","watch","create","update","patch","delete"]
- apiGroups: ["apps"]
  resources: ["statefulsets","deployments"]
  verbs: ["get","list","watch","create","update","patch","delete"]
- apiGroups: ["networking.k8s.io"]
  resources: ["networkpolicies","ingresses"]
  verbs: ["get","list","watch","create","update","patch","delete"]
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  verbs: ["get","list","watch","create","update","patch","delete"]
- apiGroups: ["policy"]
  resources: ["poddisruptionbudgets"]
  verbs: ["get","list","watch","create","update","patch","delete"]
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles","rolebindings"]
  verbs: ["get","list","watch","create","update","patch","delete"]
- apiGroups: ["events.k8s.io"]
  resources: ["events"]
  verbs: ["get","list","watch","create","update","patch"]
- apiGroups: [""]
  resources: ["secrets","configmaps","pods","persistentvolumeclaims","serviceaccounts","services","endpoints"]
  verbs: ["get","list","watch","create","update","patch","delete"]
EOF

info " creating cluster role resource  completed "

# Bind the ClusterRole to the operator ServiceAccount (ClusterRoleBinding)
if ! kubectl get clusterrolebinding "$crb_name" >/dev/null 2>&1; then
info "Creating ClusterRoleBinding ${crb_name} -> ${cr_name} -> ${NAMESPACE}/${sa_name}"
kubectl create clusterrolebinding "$crb_name" \
--clusterrole="$cr_name" \
--serviceaccount="$NAMESPACE:$sa_name" || die "Failed to create clusterrolebinding ${crb_name}"
else
info "ClusterRoleBinding ${crb_name} already exists"
fi


# Ensure a namespaced RoleBinding exists so cluster-level ClusterRole can be referenced in-namespace
cat <<RB | kubectl apply -n "$NAMESPACE" -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
     name: ${ns_rb_name}
subjects:
     - kind: ServiceAccount
       name: ${sa_name}
       namespace: ${NAMESPACE}
roleRef:
       apiGroup: rbac.authorization.k8s.io
       kind: ClusterRole
       name: ${cr_name}
RB


# Quick verification
if kubectl auth can-i list kafkas --as="system:serviceaccount:${NAMESPACE}:${sa_name}" -n "${NAMESPACE}" | grep -q yes; then
info "ServiceAccount ${NAMESPACE}/${sa_name} can list kafkas (OK)"
else
warn "ServiceAccount ${NAMESPACE}/${sa_name} cannot list kafkas. RBAC may still be insufficient; check ClusterRole rules and bindings."
fi


# Restart the operator to pick up any permission changes
kubectl rollout restart deploy -n "${NAMESPACE}" "$OPERATOR_DEPLOYMENT" || warn "Failed to restart operator deployment"
wait_for_deploy_ready "$OPERATOR_DEPLOYMENT"


info "Consolidated RBAC applied for phase: ${phase_name}"
}

get_helm_release_details(){
HELM_RELEASE_NAME=$(kubectl_ns  get kafka $KAFKA_CR_NAME  -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}')

#info "Helm Release Name : $HELM_RELEASE_NAME"

HELM_NAMESPACE=$(kubectl_ns  get kafka $KAFKA_CR_NAME  -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-namespace}')

#info "Helm Release Namespace : $HELM_NAMESPACE"


}

create_kafka_broker_nodepools(){

info "Creating KafkaNodePools for  broker roles (Phase 2)..."

cat <<EOF > "${WORKDIR}/kafkanodepools-${KAFKA_CR_NAME}-broker.yaml"
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: kafka-broker
  namespace: ${NAMESPACE}
  labels:
    strimzi.io/cluster: ${KAFKA_CR_NAME}
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: ${HELM_RELEASE_NAME}
    meta.helm.sh/release-namespace: ${HELM_NAMESPACE}
spec:
  replicas: 1
  roles:
    - broker
  resources:
      requests:
        memory: 2Gi
        cpu: "2"
      limits:
        memory: 4Gi
        cpu: "4"
  storage:
          type: persistent-claim
          size: 5Gi
          kraftMetadata: shared
          deleteClaim: false
EOF

info "Applying KafkaNodePools manifest..."
kubectl_ns apply -f "${WORKDIR}/kafkanodepools-${KAFKA_CR_NAME}-broker.yaml"

info "Waiting for KafkaNodePool resources to appear..."
kubectl_ns get kafkanodepools

info "KafkaNodePools for  broker created successfully."
sleep 30

}

create_kafka_controller_nodepools(){

info "Creating KafkaNodePools for controller roles (Phase 2)..."

cat <<EOF > "${WORKDIR}/kafkanodepools-${KAFKA_CR_NAME}-controller.yaml"
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: kafka-controller
  namespace: ${NAMESPACE}
  labels:
    strimzi.io/cluster: ${KAFKA_CR_NAME}
    app.kubernetes.io/managed-by: Helm
  annotations: 
    meta.helm.sh/release-name: ${HELM_RELEASE_NAME}
    meta.helm.sh/release-namespace: ${HELM_NAMESPACE}
spec:
  replicas: 1
  roles:
    - controller
  resources:
      requests:
        memory: 2Gi
        cpu: "2"
      limits:
        memory: 4Gi
        cpu: "4"
  storage:
    type: persistent-claim
    size: 5Gi
    deleteClaim: false
EOF

info "Applying KafkaNodePools manifest..."
kubectl_ns apply -f "${WORKDIR}/kafkanodepools-${KAFKA_CR_NAME}-controller.yaml"

info "Waiting for KafkaNodePool resources to appear..."
kubectl_ns get kafkanodepools

info "KafkaNodePools for  controller  created successfully."
sleep 30

}

add_nodepools_annotations(){

# Annotating Kafka CR with strimzi.io/node-pools: enabled to start using kafkanodepools
info "adding strimzi.io/node-pools: enabled annotation to start using kafkaNodepools"
cat <<EOF > "${WORKDIR}/annotate-node-pools.yaml"
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: ${KAFKA_CR_NAME}
  namespace: ${NAMESPACE}
  annotations:
    strimzi.io/node-pools: enabled
    strimzi.io/kraft: disabled
EOF

info "Applying nodepool  annotation..."
# We will patch to add annotation (maintain other fields)
kubectl_ns annotate kafka "$KAFKA_CR_NAME" strimzi.io/node-pools=enabled --overwrite

}

add_migration_annotations(){
# Annotating Kafka CR with strimzi.io/kraft: migration to start migrating from zookeeper mode to KRAFT mode
info "adding strimzi.io/kraft: migration  annotation to start migrating from zookeeper mode to KRAFT mode"
cat <<EOF > "${WORKDIR}/annotate-migration.yaml"
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: ${KAFKA_CR_NAME}
  namespace: ${NAMESPACE}
  annotations:
    strimzi.io/kraft: migration
EOF

info "Applying migration  annotation..."
# We will patch to add annotation (maintain other fields)
kubectl_ns annotate kafka "$KAFKA_CR_NAME" strimzi.io/kraft=migration --overwrite

}

add_kraft_annotations(){
# Annotating Kafka CR with strimzi.io/kraft: migration to start migrating from zookeeper mode to KRAFT mode
info "adding strimzi.io/kraft: enabled  annotation to move state to  KRAFT mode"
cat <<EOF > "${WORKDIR}/annotate-kraft.yaml"
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: ${KAFKA_CR_NAME}
  namespace: ${NAMESPACE}
  annotations:
    strimzi.io/kraft: enabled
EOF

info "Applying kraft  annotation..."
# We will patch to add annotation (maintain other fields)
kubectl_ns annotate kafka "$KAFKA_CR_NAME" strimzi.io/kraft=enabled --overwrite
#kubectl_ns apply -f ${WORKDIR}/annotate-kraft.yaml

}


apply_kafka_configuration(){
info "updating kafka resource configuration "
cat <<EOF > "${WORKDIR}/patch-kafka-configuration.yaml"
spec:
  kafka:
    config:
      inter.broker.protocol.version: $1
      log.message.format.version: $1
      metadata.version: $1
EOF

info "Applying kafka configuration..."
kubectl patch kafka "${KAFKA_CR_NAME}" -n "${NAMESPACE}" \
  --type merge \
  --patch-file "${WORKDIR}/patch-kafka-configuration.yaml"
info "wait for kafka pods to be ready (1 min) "
sleep 60

}


function create_copy_pod() {
  local pod_name=$1
  local old_pvc=$2
  local new_pvc=$3
  echo "Creating pod $pod_name to copy $old_pvc → $new_pvc..."

  # Delete old pod if exists
  kubectl delete pod "$pod_name" -n "$NAMESPACE" --ignore-not-found

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $pod_name
  namespace: $NAMESPACE
spec:
  restartPolicy: Never
  containers:
  - name: pv-copy
    image: alpine:3.19
    command:
      - sh
      - -c
      - |
        set -e
        echo "Installing rsync..."
        apk add --no-cache rsync
        echo "Starting rsync copy..."
        rsync -avh --progress /mnt/old/. /mnt/new/
        echo "Copy completed."
    volumeMounts:
      - name: old
        mountPath: /mnt/old
      - name: new
        mountPath: /mnt/new
  volumes:
    - name: old
      persistentVolumeClaim:
        claimName: $old_pvc
    - name: new
      persistentVolumeClaim:
        claimName: $new_pvc
EOF
}


function wait_for_pod_completion() {
  local pod_name=$1
  echo "Waiting for pod $pod_name to complete..."
  echo "Waiting for pod $pod_name to finish..."
  kubectl wait --for=condition=Initialized pod/$pod_name -n "$NAMESPACE" --timeout=5m

  while true; do
    phase=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
    if [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ]; then
        echo "Pod finished with phase: $phase"
        break
    fi
    sleep 2
  done
  echo "Pod $pod_name finished."
}

function delete_pod() {
  local pod_name=$1
  echo "Deleting pod $pod_name..."
  kubectl delete pod "$pod_name" -n "$NAMESPACE"
}


rename_kafka_resources(){

	 info " Patching KafkaNodePool : kafka-broker "
        kubectl_ns patch kafkanodepool kafka-broker --type=json \
        -p="[
        {\"op\": \"replace\", \"path\": \"/metadata/labels/strimzi.io~1cluster\", \"value\": \"$NEW_KAFKA_CR_NAME\"}

        ]"

        info " Patching KafkaNodePool: kafka-controller"
        kubectl_ns patch kafkanodepool  kafka-controller  --type=json \
        -p="[
        {\"op\": \"replace\", \"path\": \"/metadata/labels/strimzi.io~1cluster\", \"value\": \"$NEW_KAFKA_CR_NAME\"}

        ]"

        info "Patching strimzi-operator operator "
        kubectl_ns get deploy "$OPERATOR_DEPLOYMENT" -o yaml > "${WORKDIR}/kafka-$NEW_OPERATOR_DEPLOYMENT.yaml"
        sed "s/name: $OPERATOR_DEPLOYMENT/name: $NEW_OPERATOR_DEPLOYMENT/"   "${WORKDIR}/kafka-$NEW_OPERATOR_DEPLOYMENT.yaml"

        info "creating $NEW_OPERATOR_DEPLOYMENT operator "
        kubectl_ns  apply -f "${WORKDIR}/kafka-$NEW_OPERATOR_DEPLOYMENT.yaml"

        wait_for_deploy_ready "$OPERATOR_DEPLOYMENT"

        info " Exporting existing Kafka CR to new file"
        kubectl_ns get kafka $KAFKA_CR_NAME -o yaml > "${WORKDIR}/kafka-$NEW_KAFKA_CR_NAME.yaml"

        # Update metadata.name + spec.kafka.metadata.clusterName if needed
        sed -i "s/name: $KAFKA_CR_NAME/name: $NEW_KAFKA_CR_NAME/" "${WORKDIR}/kafka-$NEW_KAFKA_CR_NAME.yaml"


        info "Applying new Kafka CR with updated name"
        kubectl_ns apply -f "${WORKDIR}/kafka-$NEW_KAFKA_CR_NAME.yaml"
        wait_for_new_kafka_ready

	info "Restarting strimzi operator "
        echo "=== Restarting Strimzi Operator ==="

        kubectl rollout restart deploy -n "${NAMESPACE}" "$OPERATOR_DEPLOYMENT" || warn "Failed to restart operator deployment"
        wait_for_deploy_ready "$OPERATOR_DEPLOYMENT"

        echo "✓ Strimzi Operator restarted. Reconciliation will now apply the new names."
        wait_for_new_kafka_ready

}


backup_pvc_data(){
	PVC=$2;
	OUTPUT="${WORKDIR}/pvc-$PVC-backup.tar.gz"
	TMP_POD="backup-$PVC"
	echo "======================================================"
	echo " SINGLE PVC BACKUP"
	echo " Namespace : $NAMESPACE"
	echo " PVC       : $PVC"
	echo " Backup    : $OUTPUT"
	echo "======================================================"
        #############################################
	# Create temporary pod mounting the PVC
	#############################################
	echo "Creating temporary backup pod: $TMP_POD"

	cat <<EOF | kubectl apply -n $NAMESPACE -f -
	apiVersion: v1
	kind: Pod
	metadata:
  		name: $TMP_POD
	spec:
  		containers:
  		- name: backup
    		  image: alpine
    		  command: ["/bin/sh"]
    		  args: ["-c", "sleep 3600"]
    		  volumeMounts:
    		  - name: data
      		    mountPath: /data
  		volumes:
  		- name: data
    		  persistentVolumeClaim:
      		  claimName: $PVC
EOF
        #############################################
	# Wait pod ready
	#############################################
	kubectl -n $NAMESPACE wait pod/$TMP_POD --for=condition=Ready --timeout=120s
	#############################################
	# Create TAR inside pod
	#############################################
	echo "Creating TAR archive inside the pod..."
	kubectl -n $NAMESPACE exec $TMP_POD -- sh -c \
  	"tar -czvf /tmp/backup.tar.gz -C /data ."
	#############################################
	# Copy TAR to local machine
	#############################################
	echo "Copying backup archive to: $OUTPUT"
	kubectl -n $NAMESPACE cp $TMP_POD:/tmp/backup.tar.gz "$OUTPUT"
        #############################################
	# Clean up
	#############################################
	echo "Deleting temporary pod..."
	kubectl -n $NAMESPACE delete pod $TMP_POD --force --grace-period=0

	echo "=============================================="
	echo " PVC BACKUP COMPLETE"
	echo " File saved: $OUTPUT"
	echo "=============================================="

}

restore_pvc_data(){
        PVC=$2
        BACKUP_FILE=$3

	echo "======================================================"
	echo " SINGLE PVC RESTORE"
	echo " Namespace : $NAMESPACE"
	echo " PVC       : $PVC"
	echo " Backup    : $BACKUP_FILE"
	echo "======================================================"

	TMP_POD="restore-$PVC"
	#############################################
	# Create temporary restore pod
	#############################################
	echo "Creating temporary pod: $TMP_POD"

	cat <<EOF | kubectl apply -n $NAMESPACE -f -
	apiVersion: v1
	kind: Pod
	metadata:
  		name: $TMP_POD
	spec:
  		containers:
  		- name: restore
    		  image: alpine
    		  command: ["/bin/sh"]
    		  args: ["-c", "sleep 3600"]
    		  volumeMounts:
    		  - name: data
      		    mountPath: /restore
  		volumes:
  		- name: data
    		  persistentVolumeClaim:
                  claimName: $PVC
EOF
	kubectl -n $NAMESPACE wait pod/$TMP_POD --for=condition=Ready --timeout=120s
	#############################################
	# Upload backup archive to pod
	#############################################
	echo "Copying backup file into pod..."
	kubectl -n $NAMESPACE cp "$BACKUP_FILE" $TMP_POD:/tmp/restore.tar.gz

	#############################################
	# Restore files inside PVC
	#############################################
	echo "Restoring files inside PVC..."
	kubectl -n $NAMESPACE exec $TMP_POD -- sh -c \
  	"tar -xzvf /tmp/restore.tar.gz -C /restore"
	#############################################
	# Cleanup
	#############################################
	echo "Deleting temporary pod..."
	kubectl -n $NAMESPACE delete pod $TMP_POD --force --grace-period=0

	echo "=============================================="
	echo " PVC RESTORE COMPLETE"
	echo " Restored into PVC: $PVC"
	echo "=============================================="


}


########################
# Start
########################

info "Strimzi upgrade script: 0.34.x -> 0.48.0 (single-node cluster)"

start_time=$SECONDS

#######################
# Interactive input
########################
read -r -p "Enter namespace [${DEFAULT_NAMESPACE}]: " NAMESPACE_INPUT
NAMESPACE="${NAMESPACE_INPUT:-$DEFAULT_NAMESPACE}"
read -r -p "Enter Kafka CR name [${DEFAULT_KAFKA_CR_NAME}]: " KAFKA_INPUT
KAFKA_CR_NAME="${KAFKA_INPUT:-$DEFAULT_KAFKA_CR_NAME}"

ensure_operator_running

get_helm_release_details



info "Working dir: $WORKDIR"
mkdir -p "$WORKDIR"

info "Current kubectl context:"
kubectl config current-context || warn "No kubectl context found"

info "Namespace: $NAMESPACE"
info "Kafka CR name: $KAFKA_CR_NAME"
info "Helm Release Name : $HELM_RELEASE_NAME"
info "Helm Release Namespace : $HELM_NAMESPACE"

# Show current Strimzi operator image
current_image="$(kubectl_ns get deploy "$OPERATOR_DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
info "Current operator image: ${current_image:-(unknown)}"

if ! confirm "Proceed with backup and staged upgrade of Strimzi to ${TARGET_VER}?"; then
  die "User aborted"
fi


backup_crs_and_pvcs

# PHASE 1
info "=== PHASE 1: Upgrade CRDs to ${STEP1_VER} and operator image to ${STEP1_VER} ==="
apply_crds_from_release "$STEP1_VER"
upgrade_operator_image "$STEP1_VER"


info "Waiting for Kafka CR to reconcile after operator upgrade..."
sleep 120
wait_for_deploy_ready "${OPERATOR_DEPLOYMENT}"
wait_for_kafka_ready
phase1_end_time=$SECONDS
phase1_duration=$((phase1_end_time - start_time))
phase1_minutes=$((phase1_duration / 60))
info " PHASE 1 KAFKA UPGRADE FROM $ORG_VER TO $STEP1_VER  COMPLETED SUCCESSFULLY in $phase1_duration seconds ( $phase1_minutes minutes). "

# --- Phase 2: Upgrade to STEP2_VER (prepares for KRaft migration) ---
info "=== PHASE 2: Upgrade CRDs to ${STEP2_VER} and operator image to ${STEP2_VER} ==="
phase2_start_time=$SECONDS
apply_crds_from_release "$STEP2_VER"
apply_consolidated_rbac "$STEP2_VER"
add_nodepools_annotations
create_kafka_broker_nodepools
apply_kafka_configuration "3.9"
upgrade_operator_image "$STEP2_VER"

info "Waiting for Kafka CR to reconcile after operator upgrade..."
sleep 120
wait_for_deploy_ready "${OPERATOR_DEPLOYMENT}"
wait_for_kafka_ready

# KRAFT Migration from zookeeper mode
info " KRAFT Migration from Zookeeper mode started "
create_kafka_controller_nodepools
add_migration_annotations

info "Waiting for Kafka CR to reconcile after migration..."
wait_for_deploy_ready "${OPERATOR_DEPLOYMENT}"
wait_for_kafka_ready
wait_for_kafka_metadata_migration_status

info " kafka resource status "
kubectl_ns get kafka

info " KRAFT migration completed successfuly "

info "KRaft migration completed or Kafka is Ready. Next: remove zookeeper section from Kafka CR if present."

info "Taking copy/backup of the Kafka resource after post migration.."

# Take a copy before editing
kubectl_ns get kafka "$KAFKA_CR_NAME" -o yaml > "${WORKDIR}/${KAFKA_CR_NAME}.post-migration.yaml"

# Remove zookeeper section: use kubectl patch to remove .spec.zookeeper if exists
if kubectl_ns get kafka "$KAFKA_CR_NAME" -o jsonpath='{.spec.zookeeper}' >/dev/null 2>&1; then
  info "Removing .spec.zookeeper from Kafka CR to finalize KRaft mode."
  kubectl_ns patch kafka "$KAFKA_CR_NAME" --type='json' -p='[{"op":"remove","path":"/spec/zookeeper"}]'
  info "Removed .spec.zookeeper; waiting for reconciliation..."
  wait_for_kafka_ready 
else
  info "No .spec.zookeeper section present; likely already removed."
fi

add_kraft_annotations
sleep 60
wait_for_kafka_ready

phase2_end_time=$SECONDS
phase2_duration=$((phase2_end_time - phase2_start_time))
phase2_minutes=$((phase2_duration / 60))
info " PHASE 2 KAFKA UPGRADE FROM $STEP1_VER TO $STEP2_VER  COMPLETED SUCCESSFULLY in $phase2_duration seconds ( $phase2_minutes minutes). "


# --- Phase 3: Upgrade CRDs & operator to TARGET_VER ---
info "=== PHASE 3: Upgrade CRDs to ${TARGET_VER} and operator image to ${TARGET_VER} ==="

phase3_start_time=$SECONDS

apply_crds_from_release "$TARGET_VER"
apply_kafka_configuration "4.1"
upgrade_operator_image "$TARGET_VER"

info "Waiting for Kafka CR to reconcile after final operator upgrade..."
sleep 120
wait_for_deploy_ready "${OPERATOR_DEPLOYMENT}"
wait_for_kafka_ready
wait_for_kafka_metadata_migration_status

info " kafka resource status "
kubectl_ns get kafka


phase3_end_time=$SECONDS
phase3_duration=$((phase3_end_time - phase3_start_time))
phase3_minutes=$((phase3_duration / 60))
info " PHASE 3 KAFKA UPGRADE FROM $STEP2_VER TO $TARGET_VER  COMPLETED SUCCESSFULLY in $phase3_duration seconds ( $phase3_minutes minutes). "

# changing kafa resource name from dzs-kafka to zhone-kafka
info "=== PHASE 4: Changing Kafka resource name ${KAFKA_CR_NAME} to ${NEW_KAFKA_CR_NAME} ==="

phase4_start_time=$SECONDS

rename_kafka_resources

echo "===== Kafka PV Migration started ===="

OLD_BROKER_PVC="data-$KAFKA_CR_NAME-kafka-broker-0"
NEW_BROKER_PVC="data-$NEW_KAFKA_CR_NAME-kafka-broker-0"
POD_BROKER="pv-copy-broker"

BROKER_POD_TYPE="${NEW_BROKER_PVC#data-}"
echo "BROKER_POD_TYPE : $BROKER_POD_TYPE"
NEW_BROKER_POD_NAME=$(kubectl get pod -n "$NAMESPACE" -o jsonpath="{.items[*].metadata.name}" | tr ' ' '\n' | grep "$BROKER_POD_TYPE")
echo "NEW_BROKER_POD_NAME : $NEW_BROKER_POD_NAME"

OLD_CONTROLLER_PVC="data-$KAFKA_CR_NAME-kafka-controller-1"
NEW_CONTROLLER_PVC="data-$NEW_KAFKA_CR_NAME-kafka-controller-1"
POD_CONTROLLER="pv-copy-controller"

CONTROLLER_POD_TYPE="${NEW_CONTROLLER_PVC#data-}"
echo "CONTROLLER_POD_TYPE : $CONTROLLER_POD_TYPE"
NEW_CONTROLLER_POD_NAME=$(kubectl get pod -n "$NAMESPACE" -o jsonpath="{.items[*].metadata.name}" | tr ' ' '\n' | grep "$CONTROLLER_POD_TYPE")
echo "NEW_CONTROLLER_POD_NAME : $NEW_CONTROLLER_POD_NAME"

# Create copy pods
create_copy_pod "$POD_BROKER" "$OLD_BROKER_PVC" "$NEW_BROKER_PVC"
create_copy_pod "$POD_CONTROLLER" "$OLD_CONTROLLER_PVC" "$NEW_CONTROLLER_PVC"

# Wait for completion
wait_for_pod_completion "$POD_BROKER"
wait_for_pod_completion "$POD_CONTROLLER"

# Delete temporary pods
delete_pod "$POD_BROKER"
delete_pod "$POD_CONTROLLER"

echo "===== Kafka PV Migration Completed Successfully! ====="

echo "===== Deleting ${KAFKA_CR_NAME} kafka resources started ====="

echo " Deleting old Kafka CR "
kubectl_ns  delete kafka $KAFKA_CR_NAME 
sleep 10

#info " deleting $OPERATOR_DEPLOYMENT deployment "
#kubectl_ns delete deploy "$OPERATOR_DEPLOYMENT" 

info "deleting $KAFKA_CR_NAME kafka pods  "
kubectl_ns delete pod -l strimzi.io/name="$KAFKA_CR_NAME-kafka"

echo "===== Deleting ${KAFKA_CR_NAME} kafka resources completed Successfully ====="

info "Restarting new kafka pods"

echo "=== Restarting Broker pod ==="

kubectl delete pod -n "${NAMESPACE}" "$NEW_BROKER_POD_NAME" || warn "Failed to restart broker pod"
sleep 20

info "=== Restarting Controller pod ==="

kubectl delete pod -n "${NAMESPACE}" "$NEW_CONTROLLER_POD_NAME" || warn "Failed to restart controller pod"
sleep 20

echo "✓ new kafka pods restarted successfully."
wait_for_new_kafka_ready



phase4_end_time=$SECONDS
phase4_duration=$((phase4_end_time - phase4_start_time))
phase4_minutes=$((phase4_duration / 60))
info " PHASE 4 KAFKA Resource name change to ${NEW_KAFKA_CR_NAME} COMPLETED SUCCESSFULLY in $phase4_duration seconds ( $phase4_minutes minutes). "


# --- Validation steps ---
info "=== VALIDATION ==="
info "Pods in namespace ${NAMESPACE}:"
kubectl_ns get pods -o wide

info "Kafka CR status:"
kubectl_ns get kafka "$NEW_KAFKA_CR_NAME" -o yaml | sed -n '1,240p'

info "If you migrated from ZooKeeper, confirm there are no zookeeper pods running:"
kubectl_ns get pods | grep zookeeper || info "No zookeeper pods found (OK) or grep found nothing."

end_time=$SECONDS
duration=$((end_time - start_time))
minutes=$((duration / 60))

info "Backup files are created at $WORKDIR. please delete them if not needed."


echo "Migration task KAFKA UPGRADE FROM $ORG_VER TO $TARGET_VER COMPLETED SUCCESSFULLY  in $duration seconds ( $minutes minutes)."

