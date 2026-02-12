#!/usr/bin/env bash
#./migrate-pm-pvc-data.sh

set -euo pipefail
IFS=$'\n\t'


########################
# Defaults (editable)
########################
DEFAULT_NAMESPACE="aeo-dzs"

########################
# Helpers
########################

die(){ echo "ERROR: $*" >&2; exit 1; }
info(){ echo -e "\n\033[1;34mINFO:\033[0m $*\n"; }
warn(){ echo -e "\n\033[1;33mWARN:\033[0m $*\n"; }
confirm(){ read -r -p "$* [y/N]: " _resp; [[ "$_resp" =~ ^[Yy] ]] ; }

kubectl_ns() { kubectl -n "$NAMESPACE" "$@"; }


########################
# Helper functions
#######################

function create_copy_pod() {
  local pod_name=$1
  local old_pvc=$2
  local new_pvc=$3
  info "Creating pod $pod_name to copy $old_pvc → $new_pvc..."

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
  info "Waiting for pod $pod_name to complete..."
  info "Waiting for pod $pod_name to finish..."
  kubectl wait --for=condition=Initialized pod/$pod_name -n "$NAMESPACE" --timeout=5m

  while true; do
    phase=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
    if [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ]; then
        echo "Pod finished with phase: $phase"
        break
    fi
    sleep 2
  done
  info "Pod $pod_name finished."
}

function delete_pod() {
  local pod_name=$1
  info "Deleting pod $pod_name..."
  kubectl delete pod $pod_name -n $NAMESPACE
}

function verify_pvc_resources(){
	local source_pvc=$1
        #local source_pod=$2
        local target_pvc=$2
        local target_pod=$3

        info "Ensure source pvc exists in  exists in namespace ${NAMESPACE}"
        if ! kubectl -n $NAMESPACE get pvc  $source_pvc >/dev/null 2>&1; then
           echo "Source pvc $source_pvc not found in namespace $NAMESPACE.  correct the Namespace  name before proceeding."
	   exit 1
        fi
	info "✓ Source pvc $source_pvc found in namespace  $NAMESPACE."


        info "Ensure target pvc exists in exists in namespace $NAMESPACE"
        if ! kubectl -n $NAMESPACE get pvc  $target_pvc >/dev/null 2>&1; then
           echo "Target pvc $target_pvc not found in namespace $NAMESPACE.  correct the Namespace name before proceeding."
	   exit 1
        fi
        info "✓ Target pvc $target_pvc found in namespace  $NAMESPACE."

	info "Ensure target pod exists in exists in namespace $NAMESPACE"
        if ! kubectl -n $NAMESPACE get pod  $target_pod >/dev/null 2>&1; then
           echo "Target pod $target_pod  not found in namespace $NAMESPACE.  correct the Namespace name before proceeding."
	   exit 1
        fi
        info "✓ Target pod $target_pod found in namespace  $NAMESPACE."


}

########################
# Start
########################

info "Migrating pm  pvc data from source pvc to target pvc "

migration_start_time=$SECONDS

#######################
# Interactive input
########################
read -r -p "Enter namespace [${DEFAULT_NAMESPACE}]: " NAMESPACE_INPUT
NAMESPACE="${NAMESPACE_INPUT:-$DEFAULT_NAMESPACE}"
SOURCE_PVC_NAME="data-dzs-sdnc-influxdb-0"
TARGET_PVC_NAME="data-zhone-sdnc-influxdb-0"
TARGET_POD_NAME="${TARGET_PVC_NAME#data-}"


verify_pvc_resources $SOURCE_PVC_NAME  $TARGET_PVC_NAME $TARGET_POD_NAME


info "check the user input for confirmation"
info "===================================="
echo "Namespace: $NAMESPACE"
echo "Source PVC Name: $SOURCE_PVC_NAME"
echo "Destination/Target PVC Name : $TARGET_PVC_NAME"
echo "Target Pod Name : $TARGET_POD_NAME"

COPY_POD="copy-pvc-data"


# Create copy pods
create_copy_pod "$COPY_POD" "$SOURCE_PVC_NAME" "$TARGET_PVC_NAME"
# Wait for completion
wait_for_pod_completion "$COPY_POD"
# Delete temporary pods
delete_pod $COPY_POD

info "=== Restarting Target pod ==="

kubectl delete pod -n $NAMESPACE $TARGET_POD_NAME || warn "Failed to restart Target pod"

migration_end_time=$SECONDS
migration_duration=$((migration_end_time - migration_start_time))
migration_minutes=$((migration_duration / 60))

info " Migrating pm  PVC data completed successfully in $migration_duration seconds ( $migration_minutes minutes). "



