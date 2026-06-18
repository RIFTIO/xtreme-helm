#!/bin/bash

# Deletes orphaned secrets (those without Helm-managed annotations) that are
# defined in xtreme/charts/secrets/templates/secrets.yaml.
#
# Usage: delete_orphaned_secrets.sh <namespace>
#
# Checks both <namespace> and aeo-<namespace>.
# Called from install_xtreme after argument parsing so the real NS is known.

set -euo pipefail

log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*" >&2
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" >&2
}

if [ $# -ne 1 ]; then
    echo "Usage: $(basename "$0") <namespace>" >&2
    exit 1
fi

# Secret names defined in xtreme/charts/secrets/templates/secrets.yaml
SECRET_NAMES=("dzs-secret" "harbor")

delete_if_orphaned() {
    local name="$1"
    local namespace="$2"

    if ! kubectl get secret "$name" -n "$namespace" &>/dev/null; then
        log_info "Secret '$name' not found in namespace '$namespace' — skipping."
        return
    fi

    local helm_annotation
    helm_annotation=$(kubectl get secret "$name" -n "$namespace" \
        -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || true)

    if [ -n "$helm_annotation" ]; then
        log_info "Secret '$name' in '$namespace' is managed by Helm release '$helm_annotation' — skipping."
        return
    fi

    log_info "Deleting orphaned secret '$name' in namespace '$namespace'."
    kubectl delete secret "$name" -n "$namespace"
}

for ns in "$@"; do
    for paired_ns in "$ns" "aeo-${ns}"; do
        log_info "Scanning namespace '$paired_ns' for orphaned secrets..."
        for secret in "${SECRET_NAMES[@]}"; do
            delete_if_orphaned "$secret" "$paired_ns"
        done
    done
done

log_info "Orphaned secret cleanup complete."
