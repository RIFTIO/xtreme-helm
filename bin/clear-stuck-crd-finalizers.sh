#!/bin/bash
# copyright 2026 Zhone Technologies, Inc

# clear-stuck-crd-finalizers.sh -- unblock CRDs stuck in Terminating state
#
# A CRD delete (e.g. from `install_xtreme --clean --purge-crds`) blocks until
# every instance of that CRD, cluster-wide, is gone. If an instance is stuck
# in Terminating with a finalizer that will never be cleared -- its owning
# operator is gone, or its namespace itself has already been deleted -- the
# CRD delete hangs forever.
#
# This script finds such orphaned instances and strips their finalizers so
# any pending deletion can complete. If an instance's namespace no longer
# exists, the namespace is recreated just long enough to patch the instance,
# then removed again.
#
# Usage: clear-stuck-crd-finalizers.sh [--dry-run] [crd-name ...]
#
# With no crd-name arguments, scans every CRD on the cluster currently in the
# Terminating condition. Pass one or more CRD names (e.g.
# kafkatopics.kafka.strimzi.io) to target only those, regardless of whether
# the CRD itself shows as Terminating yet.
#
# Only instances that both (a) still carry finalizers and (b) already have a
# deletionTimestamp (deletion already requested) are touched -- this never
# force-deletes something that isn't already being deleted.

set -euo pipefail

log_info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*" >&2; }
log_warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" >&2; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

if ! command -v jq >/dev/null 2>&1; then
    log_error "jq is required but not found in PATH"
    exit 1
fi

dry_run=false
crd_names=()

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) dry_run=true;;
        -h|--help)
            cat >&2 <<EOF
Usage: $0 [--dry-run] [crd-name ...]

With no arguments, scans all CRDs currently stuck in the Terminating
condition. Pass one or more CRD names to target only those.
EOF
            exit 0
            ;;
        --) shift; break;;
        -*)
            log_error "Unknown option: $1"
            exit 1
            ;;
        *) crd_names+=("$1");;
    esac
    shift
done

if [ ${#crd_names[@]} -eq 0 ]; then
    log_info "No CRD names given — scanning cluster for CRDs stuck Terminating..."
    mapfile -t crd_names < <(kubectl get crd -o json \
        | jq -r '.items[] | select(.status.conditions[]? | .type=="Terminating" and .status=="True") | .metadata.name')
fi

if [ ${#crd_names[@]} -eq 0 ]; then
    log_info "No CRDs are stuck Terminating. Nothing to do."
    exit 0
fi

log_info "Target CRD(s): ${crd_names[*]}"

created_namespaces=()

cleanup_created_namespaces() {
    if [ ${#created_namespaces[@]} -eq 0 ]; then
        return
    fi
    local ns
    for ns in "${created_namespaces[@]}"; do
        log_info "Removing temporary namespace $ns"
        kubectl delete ns "$ns" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
    done
}
err_file=$(mktemp)

on_exit() {
    cleanup_created_namespaces
    rm -f "$err_file"
}
trap on_exit EXIT

clear_finalizers() {
    local resource=$1 name=$2 ns=$3

    if $dry_run; then
        log_info "[dry-run] would clear finalizers on $resource/$name${ns:+ -n $ns}"
        return
    fi

    if [ -z "$ns" ]; then
        kubectl patch "$resource" "$name" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null
        log_info "Cleared finalizers on $resource/$name"
        return
    fi

    if kubectl patch "$resource" "$name" -n "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>"$err_file"; then
        log_info "Cleared finalizers on $resource/$name -n $ns"
        return
    fi

    if grep -q "namespaces \"$ns\" not found" "$err_file"; then
        log_warn "Namespace $ns no longer exists — recreating temporarily to clear finalizer on $name"
        kubectl create ns "$ns" >/dev/null
        created_namespaces+=("$ns")
        kubectl patch "$resource" "$name" -n "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null
        log_info "Cleared finalizers on $resource/$name -n $ns"
    else
        log_error "Failed to patch $resource/$name -n $ns: $(cat "$err_file")"
    fi
}

for crd in "${crd_names[@]}"; do
    log_info "=== $crd ==="

    crd_json=$(kubectl get crd "$crd" -o json 2>/dev/null) || {
        log_warn "CRD $crd not found, skipping"
        continue
    }

    group=$(echo "$crd_json" | jq -r '.spec.group')
    plural=$(echo "$crd_json" | jq -r '.spec.names.plural')

    if [ -z "$group" ] || [ -z "$plural" ]; then
        log_warn "Could not determine group/plural for $crd, skipping"
        continue
    fi

    resource="${plural}.${group}"

    instances=$(kubectl get "$resource" --all-namespaces -o json 2>/dev/null) || {
        log_warn "Could not list instances of $resource, skipping"
        continue
    }

    stuck=$(echo "$instances" | jq -c \
        '[.items[] | select((.metadata.finalizers // []) != [] and .metadata.deletionTimestamp != null) | {name: .metadata.name, namespace: (.metadata.namespace // "")}]')

    count=$(echo "$stuck" | jq 'length')
    if [ "$count" -eq 0 ]; then
        log_info "No stuck instances of $resource found"
        continue
    fi

    log_info "$count stuck instance(s) of $resource found"

    while IFS= read -r item; do
        name=$(echo "$item" | jq -r '.name')
        ns=$(echo "$item" | jq -r '.namespace')
        clear_finalizers "$resource" "$name" "$ns"
    done < <(echo "$stuck" | jq -c '.[]')
done

log_info "Rechecking target CRD(s)..."
for crd in "${crd_names[@]}"; do
    status=$(kubectl get crd "$crd" -o json 2>/dev/null \
        | jq -r '.status.conditions[]? | select(.type=="Terminating") | .status' || true)
    if kubectl get crd "$crd" >/dev/null 2>&1; then
        if [ "$status" = "True" ]; then
            log_warn "$crd is still Terminating — other stuck instances may remain, or its owning delete request hasn't caught up yet"
        else
            log_info "$crd is present and not Terminating"
        fi
    else
        log_info "$crd is gone"
    fi
done

log_info "Done."
