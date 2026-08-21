#!/usr/bin/env bash
#
# strimzi-migrate-to-1.1.0.sh
#
# Migrate a Strimzi-managed Kafka cluster to Cluster Operator 1.1.0 / Kafka 4.3.0.
# Supported starting points: 0.48.x, 0.49.x, 0.50.x, 0.51.x (0.48.0 and 0.50.1 are the
# two paths this was written and tested against). The source version is detected from
# .status.operatorLastSuccessfulVersion, so one invocation covers both.
#
# WHY THIS CANNOT BE A SINGLE HOP
# -------------------------------
#   1. CRD API. Strimzi 1.0.0 removed v1beta2; only kafka.strimzi.io/v1 is served. v1 first
#      appears in 0.49.0, where both are served. Custom resources must therefore be converted
#      while an operator in the 0.49.x-0.51.x window is installed. Applying the 1.1.0 CRDs
#      first leaves nothing to convert from.
#   2. Kafka version. Each operator release supports a narrow window of Kafka versions and
#      consecutive windows must overlap:
#         0.48.x  4.0.0 4.1.0
#         0.49.x  4.0.0 4.0.1 4.1.0 4.1.1
#         0.50.x  4.0.0 4.0.1 4.1.0 4.1.1
#         0.51.0  4.1.0 4.1.1 4.2.0
#         1.0.x   4.1.0 4.1.1 4.1.2 4.2.0
#         1.1.0   4.2.0 4.2.1 4.3.0
#      1.1.0 dropped 4.1.x, so Kafka must reach 4.2.0 under 0.51.0 before the final hop.
#      If Kafka is on 4.0.x the script inserts an extra pre-hop bump automatically.
#
# CRDs ARE NEVER DELETED. Deleting a Strimzi CRD garbage-collects every custom resource of
# that kind, including the Kafka CR, its node pools, StrimziPodSets, and the cluster CA
# Secrets they own. CRDs are always upgraded in place via `kubectl apply --server-side`.
#
# Usage: --help
#
set -euo pipefail

readonly SCRIPT_NAME=${0##*/}
readonly SCRIPT_VERSION="2026-08-12.8"

# ========================================================================================
# Release facts (verified against kafka-versions.yaml in each Strimzi release)
# ========================================================================================
CONVERSION_HOP_VERSION=0.51.0      # last release serving BOTH v1beta2 and v1
CONVERSION_JAVA_MIN=21             # the tool ships class file v65 = Java 21
FINAL_OPERATOR_VERSION=1.1.0
FINAL_KAFKA_VERSION=4.3.0

# Kafka versions supported by each operator release.
op_kafka_support() {
  case $1 in
    0.46.*|0.47.*) echo "3.9.0 3.9.1 4.0.0";;
    0.48.*)        echo "4.0.0 4.1.0";;
    0.49.*)        echo "4.0.0 4.0.1 4.1.0 4.1.1";;
    0.50.*)        echo "4.0.0 4.0.1 4.1.0 4.1.1";;
    0.51.*)        echo "4.1.0 4.1.1 4.2.0";;
    1.0.*)         echo "4.1.0 4.1.1 4.1.2 4.2.0";;
    1.1.*)         echo "4.2.0 4.2.1 4.3.0";;
    *)             return 1;;
  esac
}

# Bridge image that ships with each operator line.
op_bridge_version() {
  case $1 in
    0.4[6-8].*) echo "0.33.1";;
    0.4[9].*|0.5*) echo "0.33.1";;
    1.*)        echo "1.0.0";;
    *)          echo "";;
  esac
}

# metadataVersion string to pair with a Kafka version under a given operator.
# 0.5x releases use the short form ("4.2"); the 1.x line pins explicit IVs.
metadata_version_for() { # metadata_version_for OPERATOR_VERSION KAFKA_VERSION
  local op=$1 kv=$2
  case $op in
    1.*)
      case $kv in
        4.1.*) echo "4.1-IV1";;
        4.2.*) echo "4.2-IV1";;
        4.3.0) echo "4.3-IV0";;
        *)     echo "${kv%.*}";;
      esac
      ;;
    *) echo "${kv%.*}";;
  esac
}

GH_RELEASES=https://github.com/strimzi/strimzi-kafka-operator/releases/download
OPERATOR_IMAGE_REPO=quay.io/strimzi/operator
KAFKA_IMAGE_REPO=quay.io/strimzi/kafka
BRIDGE_IMAGE_REPO=quay.io/strimzi/kafka-bridge
KANIKO_IMAGE_REPO=quay.io/strimzi/kaniko-executor
MAVEN_IMAGE_REPO=quay.io/strimzi/maven-builder

# ========================================================================================
# Defaults
# ========================================================================================
NAMESPACE=""                 # namespace of the Kafka CR and the operator Deployment
KAFKA_CR_NAME=zhone-strimzi
OPERATOR_DEPLOYMENT=""       # default: <kafka-cr>-cluster-operator
SRC_OPERATOR_VERSION=""      # auto-detected unless given
OPERATOR_MODE=image          # image | helm | cmd
HELM_RELEASE=""              # auto-detected from meta.helm.sh/release-name
HELM_NAMESPACE=""            # auto-detected from meta.helm.sh/release-namespace
HELM_CHART=strimzi/strimzi-kafka-operator
HELM_EXTRA_ARGS=""
OPERATOR_UPGRADE_CMD=""      # mode=cmd; {{VERSION}} is substituted
CONVERSION_MODE=auto         # auto | local | job
CHART_DIR=""
PHASES=""
WORKDIR=""
ASSUME_YES=false
DRY_RUN=false
SKIP_METADATA_BUMP=false
SKIP_HELM_REMAP=false
READY_TIMEOUT=1800
FORCE=false
REPAIR_ONLY=false
SKIP_RBAC_REPAIR=false
USE_MAPKUBEAPIS=false
REMAP_ALL_REVISIONS=false
readonly MIGRATION_RB_NAME=strimzi-entity-operator-delegation-migration

# Derived at runtime
STATE_DIR=""; BACKUP_DIR=""; DL_DIR=""
CUR_KAFKA_VERSION=""

# ========================================================================================
# Output
# ========================================================================================
if [[ -t 2 ]]; then
  C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_BLU=$'\033[36m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_YEL=""; C_GRN=""; C_BLU=""; C_OFF=""
fi
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_info()  { printf '[%s] %sINFO%s  %s\n' "$(ts)" "$C_BLU" "$C_OFF" "$*" >&2; }
log_ok()    { printf '[%s] %sOK%s    %s\n' "$(ts)" "$C_GRN" "$C_OFF" "$*" >&2; }
log_warn()  { printf '[%s] %sWARN%s  %s\n' "$(ts)" "$C_YEL" "$C_OFF" "$*" >&2; }
log_error() { printf '[%s] %sERROR%s %s\n' "$(ts)" "$C_RED" "$C_OFF" "$*" >&2; }
die()       { log_error "$*"; exit 1; }
banner()    { printf '\n%s=== %s ===%s\n\n' "$C_BLU" "$*" "$C_OFF" >&2; }

# set -e exits silently when an assignment's command substitution fails. Report before dying.
set -E
trap 'rc=$?; log_error "aborted at line $LINENO (exit $rc): $BASH_COMMAND"; exit $rc' ERR

PREFLIGHT_BLOCKERS=()
blocker() { PREFLIGHT_BLOCKERS+=("$1"); log_error "BLOCKER: $1"; }

usage() {
  cat >&2 <<EOF
$SCRIPT_NAME - migrate Strimzi to $FINAL_OPERATOR_VERSION / Kafka $FINAL_KAFKA_VERSION

Supported source operator versions: 0.48.x, 0.49.x, 0.50.x, 0.51.x
(0.48.0 -> 1.1.0 and 0.50.1 -> 1.1.0 are both handled by the same run; the source version
is read from .status.operatorLastSuccessfulVersion and the route is computed from it.)

Required:
  --ns NAMESPACE                 Namespace of the Kafka CR and cluster operator

Identity:
  --kafka-cr NAME                Kafka CR name          (default: $KAFKA_CR_NAME)
  --operator-deploy NAME         Operator Deployment    (default: <kafka-cr>-cluster-operator)
  --src-operator-version VER     Override version detection (e.g. 0.50.1)

Operator upgrade method:
  --mode image|helm|cmd          (default: $OPERATOR_MODE)
      image  patch the Deployment image + STRIMZI_* env in place, and apply the target
             version's operator ClusterRole/Role rules (required: 0.51.0 and 1.1.0 each add
             rules without which reconciliation fails with an RBAC escalation error).
             Drifts from Helm if the Deployment is chart-managed.
      helm   helm upgrade an upstream strimzi-kafka-operator release (--helm-release).
      cmd    run your own command; {{VERSION}} is replaced with the target version.
  --helm-release NAME            Helm release owning the resources
                                 (auto-detected from meta.helm.sh/release-name)
  --helm-namespace NS            Namespace the Helm release lives in - this is often NOT
                                 the resource namespace
                                 (auto-detected from meta.helm.sh/release-namespace)
  --helm-chart REF               Chart reference for --mode helm (default: $HELM_CHART)
  --helm-extra-args "ARGS"       Appended to helm upgrade
  --operator-upgrade-cmd "CMD"   Command template for --mode cmd

v1 API conversion:
  --conversion-mode auto|local|job   auto = local if java present, else a K8s Job
  --chart-dir DIR                Your chart dir; scanned (never modified) for v1beta2
  --skip-helm-remap              Do not rewrite Helm release metadata after conversion
  --skip-rbac-repair             Do not add the additive entity-operator delegation RoleBinding
  --use-mapkubeapis              Use the helm-mapkubeapis plugin instead of the built-in
                                 release-metadata rewrite (plugin must be installed)
  --remap-all-revisions          Rewrite every stored revision, not just the deployed one
                                 (only needed if you may 'helm rollback' to an older one)

Control:
  --phase LIST                   e.g. --phase 4 or --phase 3-6
  --workdir DIR                  Backups/state/downloads.
                                 Default: ./strimzi-migration-<ns>, falling back to
                                 \$TMPDIR|/tmp then \$HOME/.cache if the working directory
                                 is not writable (the fallback is logged).
  --ready-timeout SECONDS        Wait budget per reconcile (default: $READY_TIMEOUT)
  --skip-metadata-bump           Change spec.kafka.version only
  --yes                          No prompts
  --dry-run                      Print mutating commands instead of running them
  --force                        Continue past preflight blockers
  -h, --help
  --version                      Print this copy's build id and exit

Standalone repair:
  --repair-helm-release          Rewrite a Helm release's stored manifest from
                                 kafka.strimzi.io/v1beta2 to /v1 using helm-mapkubeapis,
                                 then exit. Fixes "unable to build kubernetes objects from
                                 current release manifest ... no matches for kind Kafka".
                                 Uses --helm-release / --helm-namespace (auto-detected).

Phases:
  1  preflight + backup
  2  pre-hop Kafka alignment (only if the current Kafka version is unsupported by $CONVERSION_HOP_VERSION)
  3  operator -> $CONVERSION_HOP_VERSION + apply $CONVERSION_HOP_VERSION CRDs
  4  Kafka -> 4.2.0 (+ metadataVersion)
  5  convert custom resources to v1, crd-upgrade, rewrite Helm release metadata
  6  operator -> $FINAL_OPERATOR_VERSION + apply $FINAL_OPERATOR_VERSION CRDs
  7  Kafka -> $FINAL_KAFKA_VERSION (+ metadataVersion)
  8  validate

Completed phases are recorded under the workdir, so re-running resumes.

Examples:
  # dry run, auto-detect everything
  $SCRIPT_NAME --ns demo --dry-run

  # umbrella Helm chart 'xtreme' living in namespace 'default'
  $SCRIPT_NAME --ns demo --kafka-cr zhone-strimzi \\
    --helm-release xtreme --helm-namespace default \\
    --mode cmd --operator-upgrade-cmd \\
      'helm upgrade xtreme ./charts/xtreme -n default --set strimzi.image.tag={{VERSION}} --wait' \\
    --chart-dir ./charts/xtreme
EOF
}

# ========================================================================================
# Args
# ========================================================================================
while [[ $# -gt 0 ]]; do
  case $1 in
    --ns|--namespace)        NAMESPACE=${2:?missing value for $1}; shift 2;;
    --kafka-cr)              KAFKA_CR_NAME=${2:?}; shift 2;;
    --operator-deploy)       OPERATOR_DEPLOYMENT=${2:?}; shift 2;;
    --src-operator-version)  SRC_OPERATOR_VERSION=${2:?}; shift 2;;
    --mode)                  OPERATOR_MODE=${2:?}; shift 2;;
    --helm-release)          HELM_RELEASE=${2:?}; shift 2;;
    --helm-namespace)        HELM_NAMESPACE=${2:?}; shift 2;;
    --helm-chart)            HELM_CHART=${2:?}; shift 2;;
    --helm-extra-args)       HELM_EXTRA_ARGS=${2:?}; shift 2;;
    --operator-upgrade-cmd)  OPERATOR_UPGRADE_CMD=${2:?}; shift 2;;
    --conversion-mode)       CONVERSION_MODE=${2:?}; shift 2;;
    --chart-dir)             CHART_DIR=${2:?}; shift 2;;
    --phase|--phases)        PHASES=${2:?}; shift 2;;
    --workdir)               WORKDIR=${2:?}; shift 2;;
    --ready-timeout)         READY_TIMEOUT=${2:?}; shift 2;;
    --repair-helm-release)   REPAIR_ONLY=true; shift;;
    --skip-metadata-bump)    SKIP_METADATA_BUMP=true; shift;;
    --skip-helm-remap)       SKIP_HELM_REMAP=true; shift;;
    --skip-rbac-repair)      SKIP_RBAC_REPAIR=true; shift;;
    --use-mapkubeapis)       USE_MAPKUBEAPIS=true; shift;;
    --remap-all-revisions)   REMAP_ALL_REVISIONS=true; shift;;
    --yes|-y)                ASSUME_YES=true; shift;;
    --dry-run)               DRY_RUN=true; shift;;
    --force)                 FORCE=true; shift;;
    --version)               printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0;;
    -h|--help)               usage; exit 0;;
    *) log_error "unknown argument: $1"; usage; exit 2;;
  esac
done

[[ -n $NAMESPACE ]] || { log_error "--ns is required"; usage; exit 2; }
[[ -n $OPERATOR_DEPLOYMENT ]] || OPERATOR_DEPLOYMENT="${KAFKA_CR_NAME}-cluster-operator"
WORKDIR_EXPLICIT=false
[[ -n $WORKDIR ]] && WORKDIR_EXPLICIT=true

case $OPERATOR_MODE in
  image) ;;
  helm)  : ;;   # release name resolved after detection
  cmd)   [[ -n $OPERATOR_UPGRADE_CMD ]] || die "--mode cmd requires --operator-upgrade-cmd";;
  *)     die "--mode must be one of: image, helm, cmd";;
esac

# ========================================================================================
# Primitives
# ========================================================================================
k()  { kubectl -n "$NAMESPACE" "$@"; }
kq() { kubectl -n "$NAMESPACE" "$@" 2>/dev/null; }

run() {
  if $DRY_RUN; then
    local a out=""
    for a in "$@"; do
      if   [[ $a == k ]];              then out+="kubectl -n $NAMESPACE "
      elif [[ $a =~ [[:space:]] ]];    then out+="'$a' "
      else                                  out+="$a "; fi
    done
    printf '%sDRY-RUN%s %s\n' "$C_YEL" "$C_OFF" "${out% }" >&2
    return 0
  fi
  "$@"
}

run_sh() {
  if $DRY_RUN; then printf '%sDRY-RUN%s %s\n' "$C_YEL" "$C_OFF" "$1" >&2; return 0; fi
  bash -c "$1"
}

confirm() {
  $ASSUME_YES && return 0
  $DRY_RUN && return 0
  local reply
  printf '\n%s%s%s [y/N] ' "$C_YEL" "$1" "$C_OFF" >&2
  read -r reply </dev/tty || reply=n
  [[ $reply == [yY]* ]] || die "aborted by user"
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

phase_done()      { [[ -f "$STATE_DIR/phase-$1.done" ]]; }
mark_phase_done() { $DRY_RUN || : > "$STATE_DIR/phase-$1.done"; }

phase_selected() {
  local n=$1 part lo hi
  local -a parts=()
  [[ -z $PHASES ]] && return 0
  IFS=',' read -r -a parts <<< "$PHASES"
  for part in "${parts[@]}"; do
    if [[ $part == *-* ]]; then
      lo=${part%%-*}; hi=${part##*-}
      (( n >= lo && n <= hi )) && return 0
    elif [[ $part == "$n" ]]; then return 0
    fi
  done
  return 1
}

download() {
  local url=$1 dest=$2
  [[ -s $dest ]] && { log_info "using cached $(basename "$dest")"; return 0; }
  log_info "downloading $(basename "$dest")"
  curl -fsSL --retry 3 -o "$dest.part" "$url" || die "download failed: $url"
  mv "$dest.part" "$dest"
}

# highest_common "a b c" "b c d" -> highest version present in both lists
highest_common() {
  local a b best=""
  for a in $1; do
    for b in $2; do
      if [[ $a == "$b" ]]; then
        if [[ -z $best ]]; then best=$a
        else best=$(printf '%s\n%s\n' "$best" "$a" | sort -V | tail -1); fi
      fi
    done
  done
  printf '%s' "$best"
}

in_list() { # in_list NEEDLE "space separated list"
  local n=$1 list=$2 x
  for x in $list; do [[ $x == "$n" ]] && return 0; done
  return 1
}

# ========================================================================================
# Cluster readers
# ========================================================================================
operator_running_image() {
  kq get "deploy/$OPERATOR_DEPLOYMENT" \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="strimzi-cluster-operator")].image}'
}
kafka_get()   { kq get kafka "$KAFKA_CR_NAME" -o "jsonpath=$1"; }
crd_served()  { kubectl get crd kafkas.kafka.strimzi.io -o jsonpath='{range .spec.versions[*]}{.name}{" "}{end}' 2>/dev/null || true; }
crd_stored()  { kubectl get crd kafkas.kafka.strimzi.io -o jsonpath='{.status.storedVersions}' 2>/dev/null || true; }

detect_src_operator_version() {
  local v=""
  v=$(kafka_get '{.status.operatorLastSuccessfulVersion}' || true)
  if [[ -z $v ]]; then
    v=$(operator_running_image || true); v=${v##*:}
  fi
  printf '%s' "$v"
}

detect_helm_owner() {
  local rel ns
  rel=$(kafka_get '{.metadata.annotations.meta\.helm\.sh/release-name}' || true)
  ns=$(kafka_get '{.metadata.annotations.meta\.helm\.sh/release-namespace}' || true)
  [[ -z $HELM_RELEASE   && -n $rel ]] && HELM_RELEASE=$rel
  [[ -z $HELM_NAMESPACE && -n $ns  ]] && HELM_NAMESPACE=$ns
  [[ -z $HELM_NAMESPACE ]] && HELM_NAMESPACE=$NAMESPACE
  if [[ -n $HELM_RELEASE ]]; then
    log_info "Helm owner detected: release '$HELM_RELEASE' in namespace '$HELM_NAMESPACE'"
    if [[ $HELM_NAMESPACE != "$NAMESPACE" ]]; then
      log_warn "the Helm release lives in '$HELM_NAMESPACE' but the resources live in '$NAMESPACE';"
      log_warn "all helm commands below use -n $HELM_NAMESPACE"
    fi
  fi
}

# NotReady messages that validation produces and that waiting cannot clear.
terminal_notready() {
  local m=$1
  [[ -z $m ]] && return 1
  case $m in
    *"Unsupported Kafka.spec.kafka.version"*)         return 0;;
    *"Unsupported Kafka.spec.kafka.metadataVersion"*) return 0;;
    *"attempting to grant RBAC permissions not currently held"*) return 0;;
    *InvalidResourceException*)                      return 0;;
  esac
  return 1
}

explain_terminal_notready() {
  local m=$1 have
  have=$(running_operator_version)
  case $m in
    *"Unsupported Kafka.spec.kafka.version"*|*"Unsupported Kafka.spec.kafka.metadataVersion"*)
      log_error "The running operator is '${have:-unknown}', which supports: $(op_kafka_support "$have" 2>/dev/null || echo unknown)"
      log_error "Either the operator upgrade never took effect, or it was reverted."
      log_error "Do NOT revert spec.kafka.version - finish the operator hop and the value becomes valid."
      [[ -n $HELM_RELEASE ]] && log_error "Check: helm history $HELM_RELEASE -n $HELM_NAMESPACE"
      ;;
    *"attempting to grant RBAC permissions not currently held"*)
      log_error "The operator image moved forward but its ClusterRoles did not."
      log_error "Apply the RBAC rules for the running version:"
      log_error "  $SCRIPT_NAME --ns $NAMESPACE --phase 3   # re-runs the hop, RBAC included"
      ;;
  esac
}

running_operator_version() {
  local img
  img=$(operator_running_image || true)
  printf '%s' "${img##*:}"
}

verify_hop_operator()   { [[ $(running_operator_version) == "$CONVERSION_HOP_VERSION" ]]; }
verify_final_operator() { [[ $(running_operator_version) == "$FINAL_OPERATOR_VERSION" ]]; }

# Never patch spec.kafka.version based on which phase we think we are in - check what is
# actually running. A chart-managed Deployment can be reverted underneath us at any time.
require_operator_version() { # require_operator_version EXPECTED CONTEXT
  local want=$1 ctx=$2 have
  have=$(running_operator_version)
  [[ $have == "$want" ]] && { log_ok "running operator confirmed: $have"; return 0; }

  log_error "the running cluster operator is '${have:-unknown}' but $ctx needs '$want'"
  log_error "  deployment : $OPERATOR_DEPLOYMENT (-n $NAMESPACE)"
  log_error "  image      : $(operator_running_image)"
  log_error "  it supports: $(op_kafka_support "$have" 2>/dev/null || echo unknown)"
  if [[ -n $HELM_RELEASE ]]; then
    log_error "The Deployment was almost certainly reverted by its owner. Check:"
    log_error "  helm history $HELM_RELEASE -n $HELM_NAMESPACE"
    log_error "  kubectl get application,kustomization -A 2>/dev/null   # ArgoCD / Flux self-heal"
    log_error "With --mode image the chart still pins the old operator tag, so any chart-side"
    log_error "operation or GitOps re-sync wins. Drive the chart instead: --mode cmd."
  fi
  die "operator version mismatch - fix the operator before touching spec.kafka.version"
}

wait_for_operator() {
  log_info "waiting for deployment/$OPERATOR_DEPLOYMENT rollout"
  $DRY_RUN && return 0
  k rollout status "deploy/$OPERATOR_DEPLOYMENT" --timeout=10m || die "cluster operator did not become ready"
  sleep 10
  log_ok "cluster operator running: $(operator_running_image)"
}

# Wait until the operator has observed the current generation AND Ready=True.
wait_for_kafka_ready() {
  local what=${1:-change}
  $DRY_RUN && { log_info "would wait for Kafka Ready after $what"; return 0; }
  log_info "waiting for Kafka '$KAFKA_CR_NAME' to settle after $what (timeout ${READY_TIMEOUT}s)"
  local deadline=$(( $(date +%s) + READY_TIMEOUT ))
  local gen obs ready msg last="" terminal=0
  while (( $(date +%s) < deadline )); do
    gen=$(kafka_get '{.metadata.generation}' || true)
    obs=$(kafka_get '{.status.observedGeneration}' || true)
    ready=$(kafka_get '{.status.conditions[?(@.type=="Ready")].status}' || true)
    msg=$(kafka_get '{.status.conditions[?(@.type=="NotReady")].message}' || true)
    if [[ -n $msg && $msg != "$last" ]]; then log_warn "NotReady: $msg"; last=$msg; fi
    # Some NotReady reasons are terminal: no amount of waiting fixes them. Require two
    # consecutive observations so a stale status from a restarting operator is not fatal.
    if terminal_notready "$msg"; then
      terminal=$((terminal + 1))
      if (( terminal >= 2 )); then
        log_error "this condition will not resolve by waiting:"
        log_error "  $msg"
        explain_terminal_notready "$msg"
        die "aborting early instead of waiting out the ${READY_TIMEOUT}s timeout"
      fi
    else
      terminal=0
    fi
    if [[ -n $gen && "$obs" == "$gen" && $ready == "True" ]]; then
      log_ok "Kafka Ready (generation $gen observed)"
      return 0
    fi
    sleep 15
  done
  log_error "Kafka did not reach Ready within ${READY_TIMEOUT}s"
  k get kafka "$KAFKA_CR_NAME" -o yaml | sed -n '/^status:/,$p' >&2 || true
  k get pods >&2 || true
  die "aborting - resolve the above, then re-run to resume from this phase"
}

# A CRD's status.storedVersions must be a subset of spec.versions, and must include the
# current storage version. Hand-patching storedVersions (as some upgrade scripts do) breaks
# this and makes both `kubectl apply` of newer CRDs and `crd-upgrade` behave unpredictably.
check_crd_version_consistency() {
  local crd j served stored storage v name bad=0
  for crd in $(kubectl get crd -o name 2>/dev/null | grep -E '\.strimzi\.io$'); do
    name=${crd##*/}
    j=$(kubectl get "$crd" -o json 2>/dev/null) || continue
    served=$(jq -r  '[.spec.versions[].name]|join(" ")'                        <<<"$j")
    stored=$(jq -r  '[.status.storedVersions[]?]|join(" ")'                    <<<"$j")
    storage=$(jq -r '[.spec.versions[]|select(.storage==true)|.name]|join(" ")' <<<"$j")
    for v in $stored; do
      if ! in_list "$v" "$served"; then
        blocker "$name: status.storedVersions lists '$v' which spec.versions does not serve ($served)"
        bad=1
      fi
    done
    if [[ -n $storage ]] && ! in_list "$storage" "$stored"; then
      blocker "$name: storage version '$storage' is missing from status.storedVersions ($stored)"
      bad=1
    fi
  done
  if (( bad )); then
    log_error "This is the signature of a hand-patched CRD status. It is most often caused by:"
    log_error "  kubectl patch crd <name> --subresource=status -p '{\"status\":{\"storedVersions\":[\"v1\"]}}'"
    log_error "Do not patch storedVersions directly - the API server uses it to know what is"
    log_error "actually encoded in etcd, and the conversion tool's crd-upgrade maintains it for you."
    log_error "To recover, set storedVersions back to the version the objects are really stored as"
    log_error "(the current storage version in spec.versions), then re-run this script."
  else
    log_ok "CRD served/stored version metadata is self-consistent"
  fi
}

# ----------------------------------------------------------------------------------------
# Work tree
# ----------------------------------------------------------------------------------------
# The work tree is created as strimzi-migration-<namespace> in the directory the script is run
# from. That keeps backups and the conversion snapshots next to the chart you are working on.
#
# Each candidate is proved writable rather than assumed, so a customer running from a read-only
# checkout still gets a usable run instead of a mkdir failure. Order of preference:
#
#   1. --workdir, if given (used as-is; failure there is a hard error, since it was requested)
#   2. ./strimzi-migration-<namespace>            <- the normal case
#   3. $TMPDIR or /tmp, same name                 <- invocation directory not writable
#   4. the same, suffixed with the uid, when that path exists but belongs to someone else
#      (a shared host where another operator migrated the same namespace)
#   5. $HOME/.cache/strimzi-migration-<namespace> - still stable, so resume still works
#   6. mktemp -d as a last resort, which loses resume state between runs and says so
set_workdir_paths() {
  STATE_DIR="$WORKDIR/state"; BACKUP_DIR="$WORKDIR/backups"; DL_DIR="$WORKDIR/downloads"
}

# Can we create this directory and actually write into it? Directory permissions can lie:
# read-only mounts, a full filesystem and SELinux denials all present as writable.
workdir_usable() { # workdir_usable PATH
  local d=$1 probe
  if [[ -e $d ]]; then
    [[ -d $d ]] || return 1
    # Do not adopt a directory belonging to someone else - it may be another operator's run.
    [[ -O $d ]] || return 1
  else
    mkdir -p "$d" 2>/dev/null || return 1
  fi
  probe="$d/.write-probe.$$"
  : > "$probe" 2>/dev/null || return 1
  rm -f "$probe" 2>/dev/null
  return 0
}

resolve_workdir() {
  if $WORKDIR_EXPLICIT; then
    workdir_usable "$WORKDIR" || die "--workdir '$WORKDIR' is not usable (missing, not yours, or not writable)"
    return 0
  fi

  local base=${TMPDIR:-/tmp}
  base=${base%/}
  local name="strimzi-migration-${NAMESPACE}"
  local -a candidates=("$PWD/$name" "$base/$name" "$base/$name-$(id -u)")
  [[ -n ${HOME:-} ]] && candidates+=("$HOME/.cache/$name")

  local c
  for c in "${candidates[@]}"; do
    if workdir_usable "$c"; then
      WORKDIR=$c
      if [[ $c != "${candidates[0]}" ]]; then
        log_warn "cannot write ${candidates[0]} - using $WORKDIR instead"
      fi
      return 0
    fi
  done

  WORKDIR=$(mktemp -d "${base}/strimzi-migration-XXXXXX" 2>/dev/null) \
    || die "no writable location for the work tree; pass --workdir"
  log_warn "no stable location was writable, so this run uses $WORKDIR"
  log_warn "the name changes every run, so phase state will NOT be reused - pass --workdir"
  log_warn "to a persistent path if you need resume to work across invocations."
  return 0
}
# backup() writes every Secret in the namespace - the cluster and clients CA private keys among
# them - plus the Helm release secrets. The default location is under /tmp, which is
# world-traversable, so create the tree 0700 rather than trusting the caller's umask.
prepare_workdir() {
  resolve_workdir
  set_workdir_paths
  local d
  for d in "$WORKDIR" "$STATE_DIR" "$BACKUP_DIR" "$DL_DIR"; do
    mkdir -p "$d" || die "cannot create $d"
  done
  chmod 700 "$WORKDIR" "$STATE_DIR" "$BACKUP_DIR" "$DL_DIR" 2>/dev/null \
    || log_warn "could not restrict permissions on $WORKDIR - it holds Secret backups"
  log_info "work tree: $WORKDIR (backups, downloads and phase state)"
}

# ----------------------------------------------------------------------------------------
# State freshness
# ----------------------------------------------------------------------------------------
# Phase markers describe progress against ONE Kafka cluster. If the cluster was torn down and
# reinstalled, every marker is a lie: phase 4 would be skipped and Kafka would never leave
# 4.1.0, phase 5 would be skipped and the CRs would never be converted. The Kafka CR's uid and
# clusterId both change on a rebuild, so use them as a fingerprint.
cluster_fingerprint() {
  local uid cid
  uid=$(kafka_get '{.metadata.uid}' || true)
  cid=$(kafka_get '{.status.clusterId}' || true)
  printf '%s|%s' "${uid:-none}" "${cid:-none}"
}

discard_phase_markers() {
  local f found=0
  for f in "$STATE_DIR"/phase-*.done; do
    [[ -e $f ]] || continue
    found=1
    $DRY_RUN || rm -f "$f"
  done
  (( found )) && log_warn "discarded all phase markers in $STATE_DIR"
  return 0
}

check_state_freshness() {
  local fp_file="$STATE_DIR/cluster-fingerprint" now prev
  now=$(cluster_fingerprint)
  [[ $now == "none|none" ]] && return 0

  if [[ -f $fp_file ]]; then
    prev=$(cat "$fp_file" 2>/dev/null || true)
    if [[ $prev != "$now" ]]; then
      log_warn "this workdir holds phase state for a DIFFERENT Kafka cluster:"
      log_warn "  recorded : $prev"
      log_warn "  current  : $now"
      log_warn "the cluster was rebuilt or reinstalled, so the recorded progress does not apply"
      discard_phase_markers
    fi
  elif ls "$STATE_DIR"/phase-*.done >/dev/null 2>&1; then
    log_warn "phase markers exist but this workdir has no cluster fingerprint (written by an"
    log_warn "older version of this script). Discarding them rather than risk skipping a phase"
    log_warn "that never ran against this cluster."
    discard_phase_markers
  fi
  $DRY_RUN || printf '%s' "$now" > "$fp_file"
}

# ----------------------------------------------------------------------------------------
# Permissions
# ----------------------------------------------------------------------------------------
# This migration needs cluster-scoped rights: CRDs and the operator ClusterRoles are not
# namespaced. A kubeconfig limited to one namespace gets a long way in - far enough to change
# spec.kafka.version - and then fails partway through phase 3. Check up front instead.
can_i() { # can_i VERB RESOURCE [NAMESPACE] [--subresource=X]
  local verb=$1 res=$2 ns=${3:-} extra=${4:-} out=""
  local -a cani_args=(auth can-i "$verb" "$res")
  [[ -n $ns    ]] && cani_args+=(-n "$ns")
  [[ -n $extra ]] && cani_args+=("$extra")
  out=$(kubectl "${cani_args[@]}" 2>/dev/null) || true
  [[ $out == yes ]]
}

check_required_permissions() {
  log_info "checking the permissions this migration needs"
  local line fatal verb res ns desc
  local -a checks=(
    "fatal|patch|customresourcedefinitions||apply the upgraded Strimzi CRDs"
    "fatal|patch|kafkas.kafka.strimzi.io|$NAMESPACE|change spec.kafka.version and metadataVersion"
    "fatal|patch|kafkanodepools.kafka.strimzi.io|$NAMESPACE|restore deleteClaim after conversion"
    "warn|get|secrets|$NAMESPACE|back up the cluster CA secrets"
  )
  # The v1 conversion runs as a Job in this namespace unless java is available locally.
  use_local_conversion || checks+=("fatal|create|jobs|$NAMESPACE|run the v1 conversion Job")
  # Only --mode image touches the Deployment and the operator ClusterRoles directly.
  if [[ $OPERATOR_MODE == image ]]; then
    checks+=("fatal|patch|deployments|$NAMESPACE|set the operator image and env")
    checks+=("fatal|get|clusterroles||read the operator ClusterRoles before updating them")
    checks+=("fatal|patch|clusterroles||update the operator RBAC for each target version")
  fi
  # The additive delegation RoleBinding, if the chart's own binding names the wrong namespace.
  $SKIP_RBAC_REPAIR || checks+=("warn|create|rolebindings|$NAMESPACE|repair the entity-operator delegation")
  # Rewriting the stored release manifest.
  if [[ -n $HELM_RELEASE ]] && ! $SKIP_HELM_REMAP; then
    checks+=("fatal|patch|secrets|$HELM_NAMESPACE|rewrite the Helm release manifest to v1")
  fi

  local failed=0
  for line in "${checks[@]}"; do
    IFS='|' read -r fatal verb res ns desc <<< "$line"
    if can_i "$verb" "$res" "$ns"; then
      log_ok "  $verb $res${ns:+ in $ns}"
    elif [[ $fatal == fatal ]]; then
      log_error "  CANNOT $verb $res${ns:+ in $ns} - needed to $desc"
      failed=$((failed+1))
    else
      log_warn "  cannot $verb $res${ns:+ in $ns} - $desc will be skipped or degraded"
    fi
  done

  if (( failed )); then
    blocker "$failed required permission(s) missing - see the CANNOT lines above"
    log_error "Cluster-scoped rights are unavoidable here: CRDs and the operator ClusterRoles"
    log_error "are not namespaced objects. Options:"
    log_error "  - run with a kubeconfig that has them (cluster-admin, or a role granting"
    log_error "    customresourcedefinitions and clusterroles patch)"
    log_error "  - or have an administrator apply the CRDs and operator RBAC, then re-run"
    log_error "    this script with --mode cmd so the chart owns those objects"
  fi
}

# ========================================================================================
# PHASE 1 - preflight + backup
# ========================================================================================
preflight() {
  banner "PHASE 1 - preflight and backup"

  need_cmd kubectl; need_cmd curl; need_cmd jq
  kubectl version -o json >/dev/null 2>&1 || die "cannot reach the Kubernetes API"
  kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || die "namespace '$NAMESPACE' not found"

  local kmin=""
  kmin=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.minor // ""' | tr -cd '0-9') || true
  log_info "Kubernetes server version: 1.${kmin:-?}"
  [[ -n $kmin ]] && (( kmin < 30 )) && \
    blocker "Strimzi $FINAL_OPERATOR_VERSION is tested on Kubernetes 1.30-1.36; this cluster is 1.$kmin"

  kq get "deploy/$OPERATOR_DEPLOYMENT" >/dev/null \
    || die "deployment '$OPERATOR_DEPLOYMENT' not found in '$NAMESPACE' (use --operator-deploy)"
  log_info "operator image: $(operator_running_image)"

  check_required_permissions

  local cr_json
  cr_json=$(kq get kafka "$KAFKA_CR_NAME" -o json) \
    || die "Kafka CR '$KAFKA_CR_NAME' not found in '$NAMESPACE'"

  # ---- source version and route -------------------------------------------------------
  [[ -n $SRC_OPERATOR_VERSION ]] || SRC_OPERATOR_VERSION=$(detect_src_operator_version)
  [[ -n $SRC_OPERATOR_VERSION ]] || die "could not determine the source operator version; pass --src-operator-version"
  local src_support
  src_support=$(op_kafka_support "$SRC_OPERATOR_VERSION") \
    || die "unsupported source operator version '$SRC_OPERATOR_VERSION' - this script covers 0.48.x-0.51.x"
  log_ok "source operator version: $SRC_OPERATOR_VERSION (supports Kafka: $src_support)"

  detect_helm_owner
  if [[ $OPERATOR_MODE == helm && -z $HELM_RELEASE ]]; then
    die "--mode helm needs a release name and none was detected; pass --helm-release"
  fi
  command -v helm >/dev/null 2>&1 || {
    [[ $OPERATOR_MODE == helm ]] && die "helm not found but --mode helm requested"
    [[ -n $HELM_RELEASE ]] && log_warn "resources are Helm-managed but helm is not on PATH"
  }

  # ---- Kafka state ---------------------------------------------------------------------
  local mver state ready
  CUR_KAFKA_VERSION=$(jq -r '.spec.kafka.version // ""' <<<"$cr_json")
  mver=$(jq -r  '.spec.kafka.metadataVersion // "unset"' <<<"$cr_json")
  state=$(jq -r '.status.kafkaMetadataState // "unknown"' <<<"$cr_json")
  ready=$(jq -r '[.status.conditions[]?|select(.type=="Ready")|.status]|first // "unknown"' <<<"$cr_json")
  log_info "Kafka: version=${CUR_KAFKA_VERSION:-unset} metadataVersion=$mver metadataState=$state Ready=$ready"
  log_info "status.kafkaMetadataVersion=$(jq -r '.status.kafkaMetadataVersion // "unset"' <<<"$cr_json")"

  [[ $ready == True ]] || blocker "Kafka is not Ready - do not start a migration from a degraded cluster"
  [[ -n $CUR_KAFKA_VERSION ]] || blocker "spec.kafka.version is unset; pin it explicitly before migrating"
  if [[ -n $CUR_KAFKA_VERSION ]] && ! in_list "$CUR_KAFKA_VERSION" "$src_support"; then
    blocker "Kafka $CUR_KAFKA_VERSION is not supported by operator $SRC_OPERATOR_VERSION ($src_support)"
  fi

  jq -e '.spec.zookeeper' <<<"$cr_json" >/dev/null && \
    blocker ".spec.zookeeper present - ZooKeeper is unsupported since 0.46; migrate to KRaft first"
  [[ $state == KRaft || $state == unknown ]] || \
    blocker "status.kafkaMetadataState is '$state', expected KRaft"

  # ---- CRD state -----------------------------------------------------------------------
  local served
  served=$(crd_served) || die "CRD kafkas.kafka.strimzi.io not found - are the Strimzi CRDs installed?"
  log_info "kafkas CRD served versions: $served"
  log_info "kafkas CRD stored versions: $(crd_stored)"
  if [[ $served != *v1beta2* && $served == *v1* ]]; then
    log_warn "v1beta2 is no longer served; phase 5 will detect that conversion is already done"
  fi
  check_crd_version_consistency

  # ---- node pools must fully own replicas and storage ---------------------------------
  local pools pool np_json missing=""
  pools=$(kq get kafkanodepools -o json 2>/dev/null | jq -r '[.items[]?.metadata.name]|join(" ")' || true)
  if [[ -z ${pools// /} ]]; then
    blocker "no KafkaNodePool resources found - the v1 API requires node pools"
  else
    log_info "node pools: $pools"
    for pool in $pools; do
      np_json=$(kq get kafkanodepool "$pool" -o json) || continue
      jq -e '.spec.replicas' <<<"$np_json" >/dev/null || missing+="$pool(replicas) "
      jq -e '.spec.storage'  <<<"$np_json" >/dev/null || missing+="$pool(storage) "
      log_info "  $pool: replicas=$(jq -r '.spec.replicas // "unset"' <<<"$np_json") roles=$(jq -r '(.spec.roles//[])|join(",")' <<<"$np_json")"
    done
    [[ -n $missing ]] && blocker "node pool(s) missing required config: $missing"
  fi

  # spec.kafka.replicas / spec.kafka.storage are dropped by the v1 conversion. That is only
  # safe because the node pools above carry the real values - verify, do not assume.
  if jq -e '.spec.kafka.replicas' <<<"$cr_json" >/dev/null; then
    log_warn "spec.kafka.replicas=$(jq -r '.spec.kafka.replicas' <<<"$cr_json") is deprecated and will be REMOVED by the v1 conversion"
    log_warn "  -> the node pool replica counts above are what will apply afterwards"
  fi
  if jq -e '.spec.kafka.storage' <<<"$cr_json" >/dev/null; then
    log_warn "spec.kafka.storage is deprecated and will be REMOVED by the v1 conversion"
    log_warn "  -> confirm each node pool's spec.storage matches the volumes currently in use"
    kq get kafkanodepools -o json 2>/dev/null | jq -r \
      '.items[]|"      \(.metadata.name): \(.spec.storage|tostring)"' >&2 || true
  fi

  # ---- things the conversion tool cannot fix ------------------------------------------
  jq -e '.spec.kafka.resources' <<<"$cr_json" >/dev/null && \
    blocker ".spec.kafka.resources is unsupported in v1 - move requests/limits into each KafkaNodePool"
  if jq -e '[.spec.kafka.listeners[]?.authentication?.type // empty]|index("oauth")' <<<"$cr_json" >/dev/null 2>&1; then
    blocker "listener authentication 'type: oauth' is removed in v1 - use 'type: custom'"
  fi
  local authz; authz=$(jq -r '.spec.kafka.authorization.type // ""' <<<"$cr_json")
  [[ $authz == keycloak || $authz == opa ]] && \
    blocker "authorization 'type: $authz' is removed in v1 - use 'type: custom'"

  # KafkaUser singular ACL 'operation' must be fixed BEFORE entering the 0.49-0.51 window.
  local bad_users=""
  if kq get kafkausers -o json >/dev/null 2>&1; then
    bad_users=$(kq get kafkausers -o json \
      | jq -r '.items[]|select([.spec.authorization.acls[]?|select(has("operation"))]|length>0)|.metadata.name' \
      | tr '\n' ' ')
  fi
  [[ -n ${bad_users// /} ]] && \
    blocker "KafkaUser(s) using the removed singular ACL field 'operation': ${bad_users}- switch to the 'operations' array FIRST"

  local extras="" kind names
  for kind in kafkaconnects kafkamirrormaker2s kafkabridges; do
    names=$(kq get "$kind" -o json 2>/dev/null \
            | jq -r '[.items[]?.metadata.name]|join(" ")' 2>/dev/null || true)
    [[ -n ${names// /} ]] && extras+="$kind: $names "
  done
  if [[ -n $extras ]]; then
    log_warn "additional components present ($extras)"
    log_warn "v1 requires manual work on these: spec.replicas becomes mandatory, externalConfiguration"
    log_warn "is removed, MM2 connectCluster/clusters become spec.target + mirrors[].source, jaeger goes."
  fi
  for kind in kafkaconnects kafkamirrormaker2s; do
    kq get "$kind" -o json 2>/dev/null | jq -e '.items[]|select(.spec.externalConfiguration)' >/dev/null 2>&1 \
      && blocker "$kind .spec.externalConfiguration is removed in v1 - move it to .spec.template"
  done
  kq get kafkanodepools -o json 2>/dev/null | jq -e '.items[]|select(.spec.storage.overrides)' >/dev/null 2>&1 \
    && blocker "KafkaNodePool .spec.storage.overrides is removed in v1 - split into separate node pools"

  jq -e '.spec.kafka.template.statefulset' <<<"$cr_json" >/dev/null && log_warn ".spec.kafka.template.statefulset will be dropped"
  jq -e '.spec.cruiseControl.tlsSidecar'   <<<"$cr_json" >/dev/null && log_warn ".spec.cruiseControl.tlsSidecar will be dropped"
  jq -e '.spec.entityOperator.tlsSidecar'  <<<"$cr_json" >/dev/null && log_warn ".spec.entityOperator.tlsSidecar will be dropped"
  local legacy
  for legacy in inter.broker.protocol.version log.message.format.version; do
    jq -e --arg k "$legacy" '.spec.kafka.config[$k]' <<<"$cr_json" >/dev/null \
      && log_warn "spec.kafka.config['$legacy'] is meaningless under KRaft/Kafka 4.x and will be removed"
  done

  # ---- Helm release health -------------------------------------------------------------
  if [[ -n $HELM_RELEASE ]] && command -v helm >/dev/null 2>&1; then
    local st
    st=$(helm list -n "$HELM_NAMESPACE" -o json 2>/dev/null \
         | jq -r --arg r "$HELM_RELEASE" '.[]|select(.name==$r)|.status' || true)
    log_info "helm release '$HELM_RELEASE' (-n $HELM_NAMESPACE) status: ${st:-not found}"
    if [[ -z $st ]]; then
      log_warn "release not listed in '$HELM_NAMESPACE'; check --helm-namespace"
    elif [[ $st != deployed ]]; then
      blocker "helm release '$HELM_RELEASE' is '$st', not 'deployed' - repair it before migrating"
    fi
  fi

  # ---- your chart ----------------------------------------------------------------------
  if [[ -n $CHART_DIR ]]; then
    if [[ -d $CHART_DIR ]]; then
      local hits
      hits=$(grep -rl 'kafka\.strimzi\.io/v1beta2' "$CHART_DIR" 2>/dev/null || true)
      if [[ -n $hits ]]; then
        log_warn "these files still reference kafka.strimzi.io/v1beta2 and must move to /v1 before phase 6"
        log_warn "(Go templating means the conversion tool cannot process templates - edit by hand):"
        printf '    %s\n' $hits >&2
      else
        log_ok "no v1beta2 references under $CHART_DIR"
      fi
      if grep -rqE '^[[:space:]]*(replicas|storage):' "$CHART_DIR" 2>/dev/null; then
        log_info "reminder: remove spec.kafka.replicas / spec.kafka.storage from the Kafka template;"
        log_info "v1 has no such fields and they will be pruned silently"
      fi
    else
      log_warn "--chart-dir '$CHART_DIR' is not a directory; skipping scan"
    fi
  else
    log_warn "--chart-dir not given: your chart templates must still be moved to kafka.strimzi.io/v1"
  fi

  print_route "$SRC_OPERATOR_VERSION" "$src_support"

  if (( ${#PREFLIGHT_BLOCKERS[@]} > 0 )); then
    log_error "${#PREFLIGHT_BLOCKERS[@]} blocker(s):"
    printf '    - %s\n' "${PREFLIGHT_BLOCKERS[@]}" >&2
    $FORCE || die "resolve the blockers, or re-run with --force"
    log_warn "--force given: continuing despite blockers"
  fi

  backup
  log_ok "preflight complete"
}

print_route() {
  local src=$1 src_support=$2
  local hop_support align
  hop_support=$(op_kafka_support "$CONVERSION_HOP_VERSION")
  banner "computed route"
  {
    printf '  operator %s' "$src"
    if in_list "$CUR_KAFKA_VERSION" "$hop_support"; then
      align=""
      printf ' (Kafka %s already supported by %s)\n' "$CUR_KAFKA_VERSION" "$CONVERSION_HOP_VERSION"
    else
      align=$(highest_common "$src_support" "$hop_support")
      printf '\n  phase 2: Kafka %s -> %s   (still under operator %s, so the windows overlap)\n' \
        "$CUR_KAFKA_VERSION" "${align:-<none>}" "$src"
    fi
    printf '  phase 3: operator %s -> %s   (CRDs serve v1beta2 + v1)\n' "$src" "$CONVERSION_HOP_VERSION"
    printf '  phase 4: Kafka -> 4.2.0            (required: %s dropped Kafka 4.1.x)\n' "$FINAL_OPERATOR_VERSION"
    printf '  phase 5: convert CRs to v1, crd-upgrade%s\n' \
      "$( [[ -n $HELM_RELEASE ]] && printf ', remap helm release %s' "$HELM_RELEASE" )"
    printf '  phase 6: operator %s -> %s   (v1-only CRDs)\n' "$CONVERSION_HOP_VERSION" "$FINAL_OPERATOR_VERSION"
    printf '  phase 7: Kafka -> %s\n' "$FINAL_KAFKA_VERSION"
  } >&2
  echo >&2
}

backup() {
  log_info "backing up to $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
  local kind
  for kind in kafkas kafkanodepools kafkatopics kafkausers kafkaconnects kafkaconnectors \
              kafkamirrormaker2s kafkabridges kafkarebalances strimzipodsets; do
    kq get "$kind" -o yaml > "$BACKUP_DIR/$kind.yaml" 2>/dev/null || true
  done
  kubectl get crd -o name | grep -E 'strimzi\.io$' | xargs -r kubectl get -o yaml \
    > "$BACKUP_DIR/crds.yaml" 2>/dev/null || true
  kq get pvc    -o yaml > "$BACKUP_DIR/pvcs.yaml"    2>/dev/null || true
  kq get secret -o yaml > "$BACKUP_DIR/secrets.yaml" 2>/dev/null || true
  kq get "deploy/$OPERATOR_DEPLOYMENT" -o yaml > "$BACKUP_DIR/operator-deployment.yaml" 2>/dev/null || true
  if [[ -n $HELM_RELEASE ]] && command -v helm >/dev/null 2>&1; then
    helm get values   "$HELM_RELEASE" -n "$HELM_NAMESPACE" -a > "$BACKUP_DIR/helm-$HELM_RELEASE-values.yaml"   2>/dev/null || true
    helm get manifest "$HELM_RELEASE" -n "$HELM_NAMESPACE"    > "$BACKUP_DIR/helm-$HELM_RELEASE-manifest.yaml" 2>/dev/null || true
    kubectl -n "$HELM_NAMESPACE" get secret -l "owner=helm,name=$HELM_RELEASE" -o yaml \
      > "$BACKUP_DIR/helm-$HELM_RELEASE-release-secrets.yaml" 2>/dev/null || true
  fi
  # The conversion tool has been reported to drop KafkaNodePool
  # spec.storage.volumes[].deleteClaim (strimzi#12312); record it so we can restore.
  kq get kafkanodepools -o json 2>/dev/null | jq -r \
    '.items[]|.metadata.name as $n|(.spec.storage.volumes//[])[]?|"\($n) volume \(.id) deleteClaim=\(if has("deleteClaim") then .deleteClaim else "unset" end)"' \
    > "$BACKUP_DIR/nodepool-deleteclaim.txt" 2>/dev/null || true
  if [[ -s "$BACKUP_DIR/nodepool-deleteclaim.txt" ]]; then
    log_info "recorded node pool deleteClaim settings:"
    sed 's/^/    /' "$BACKUP_DIR/nodepool-deleteclaim.txt" >&2
  fi
  log_ok "backup written to $BACKUP_DIR"
}

# ========================================================================================
# CRDs - in place, never deleted
# ========================================================================================
apply_crds() {
  local ver=$1 f="$DL_DIR/strimzi-crds-$1.yaml"
  download "$GH_RELEASES/$ver/strimzi-crds-$ver.yaml" "$f"
  log_info "applying $ver CRDs (server-side apply; CRDs are never deleted)"
  # Server-side apply avoids the last-applied-configuration annotation size limit that
  # client-side apply hits on the very large Strimzi schemas.
  run kubectl apply --server-side --force-conflicts -f "$f"
  log_info "kafkas served now: $(crd_served)"
  log_info "kafkas stored now: $(crd_stored)"
}

# ----------------------------------------------------------------------------------------
# Operator RBAC
# ----------------------------------------------------------------------------------------
# The operator creates a Role for the Entity Operator. Kubernetes forbids granting rights the
# grantor does not itself hold, so when the operator image moves forward but its ClusterRoles
# do not, reconciliation fails with:
#   roles "<cluster>-entity-operator" is forbidden: user "system:serviceaccount:<ns>:strimzi-cluster-operator"
#   is attempting to grant RBAC permissions not currently held: {kafkatopics/finalizers ...}
# 0.51.0 added kafkatopics/finalizers + kafkausers/finalizers to ClusterRole
# strimzi-entity-operator, and 1.1.0 added pods/resize and gateway tlsroutes to
# strimzi-cluster-operator-namespaced. Both must be applied with the image.
#
# Only the ClusterRole/Role *rules* are applied. The bindings already exist and their names
# and subject namespaces differ between the Helm chart and the plain install files, so
# touching them would be riskier than it is useful.
fetch_install_files() {
  local ver=$1
  local tgz="$DL_DIR/strimzi-$ver.tar.gz"
  download "$GH_RELEASES/$ver/strimzi-$ver.tar.gz" "$tgz"
  [[ -d "$DL_DIR/strimzi-$ver" ]] || tar xzf "$tgz" -C "$DL_DIR"
  printf '%s' "$DL_DIR/strimzi-$ver/install/cluster-operator"
}

apply_operator_rbac() {
  local ver=$1 dir f kind name applied=0 missing="" forbidden=""
  dir=$(fetch_install_files "$ver")
  [[ -d $dir ]] || { log_warn "no install/cluster-operator directory in the $ver archive; skipping RBAC"; return 0; }
  log_info "updating cluster operator RBAC rules to $ver"
  for f in "$dir"/0[123]*.yaml; do
    kind=$(awk '/^kind:/{print $2; exit}' "$f")
    [[ $kind == ClusterRole || $kind == Role ]] || continue
    name=$(awk '/^metadata:/{m=1} m && /^  name:/{print $2; exit}' "$f")
    [[ -n $name ]] || continue
    local actual rendered
    actual=$(resolve_rbac_name "$kind" "$name")
    if [[ -z $actual ]]; then
      case $(probe_rbac_object "$kind" "$name") in
        forbidden) forbidden+="$name ";;
        *)         missing+="$name ";;
      esac
      continue
    fi
    if [[ $actual != "$name" ]]; then
      log_info "  $name -> $actual (renamed by your chart)"
      rendered="$DL_DIR/rbac-$ver-$actual.yaml"
      awk -v old="  name: $name" -v new="  name: $actual" \
        'BEGIN{d=0} {if(!d && $0==old){print new; d=1} else print}' "$f" > "$rendered"
    else
      rendered=$f
    fi
    if [[ $kind == ClusterRole ]]; then
      run kubectl apply --server-side --force-conflicts -f "$rendered"
    else
      run kubectl apply --server-side --force-conflicts -n "$NAMESPACE" -f "$rendered"
    fi
    applied=$((applied+1))
  done
  if (( applied == 0 )); then
    log_error "applied 0 operator ClusterRole/Role objects for $ver"
    log_error "none of the $ver RBAC objects could be read or updated. Either they are named"
    log_error "differently by your chart, or this kubeconfig cannot manage cluster-scoped RBAC."
    log_error "Check with:  kubectl auth can-i patch clusterroles"
    $FORCE || die "operator RBAC was not updated"
  else
    log_ok "applied $applied operator ClusterRole/Role object(s) for $ver"
  fi
  if [[ -n $missing ]]; then
    log_warn "not present in this cluster, left alone: $missing"
    log_warn "Strimzi-related ClusterRoles that DO exist:"
    kubectl get clusterrole -o name 2>/dev/null | grep -i strimzi | sed 's|^clusterrole.rbac.authorization.k8s.io/|    |' >&2 \
      || log_warn "    (none, or they cannot be listed)"
    log_warn "and the roles actually bound to the operator ServiceAccount:"
    show_operator_role_bindings
    log_warn "if your chart renames these, the upstream RBAC files will not update them and the"
    log_warn "operator will hit escalation errors - update the renamed objects yourself, or use"
    log_warn "--mode cmd so the chart owns them."
  fi
  if [[ -n $forbidden ]]; then
    log_error "you lack permission to read/update these: $forbidden"
    log_error "run this script with a kubeconfig that can manage ClusterRoles"
    $FORCE || die "cannot update operator RBAC"
  fi
  verify_operator_rbac "$ver"
}

# Distinguish "does not exist" from "you may not look" - conflating them silently skips the
# object that matters and the operator then fails with an escalation error.
# What roles is the operator ServiceAccount actually bound to, and under what names? A chart
# that renames the upstream objects looks identical to a cluster that is missing them.
show_operator_role_bindings() {
  local sa
  sa=$(operator_service_account)
  kubectl get clusterrolebindings,rolebindings -A -o json 2>/dev/null | jq -r --arg sa "$sa" --arg ns "$NAMESPACE" '
    .items[]
    | select([.subjects[]? | select(.kind=="ServiceAccount" and .name==$sa and (.namespace//$ns)==$ns)] | length > 0)
    | "    \(.kind) \(.metadata.namespace // "<cluster>")/\(.metadata.name) -> \(.roleRef.kind)/\(.roleRef.name)"' >&2 \
    || log_warn "    (could not list bindings)"
}

probe_rbac_object() { # probe_rbac_object KIND NAME -> present|absent|forbidden
  # `x=$(cmd)` aborts the shell under set -e when cmd fails, and here failure is expected.
  # `|| rc=$?` puts the assignment in an OR list, which set -e exempts.
  local kind=$1 name=$2 err="" rc=0
  if [[ $kind == ClusterRole ]]; then
    err=$(kubectl get clusterrole "$name" -o name 2>&1 >/dev/null) || rc=$?
  else
    err=$(kubectl -n "$NAMESPACE" get role "$name" -o name 2>&1 >/dev/null) || rc=$?
  fi
  (( rc == 0 )) && { printf present; return 0; }
  case $err in
    *[Ff]orbidden*|*"cannot get"*) printf forbidden;;
    *) printf absent;;
  esac
}

# Charts commonly rename the operator RBAC objects - this cluster has demo-strimzi-entity-operator
# where upstream ships strimzi-entity-operator, while strimzi-cluster-operator-global keeps the
# upstream name. A fixed prefix guess would be wrong either way, so the real names are
# discovered from the bindings that actually reference the operator ServiceAccount, and the
# upstream rules are then applied under whatever name this cluster uses.
OPERATOR_BOUND_ROLES=""
operator_bound_roles() {
  [[ -n $OPERATOR_BOUND_ROLES ]] && { printf '%s' "$OPERATOR_BOUND_ROLES"; return 0; }
  local sa
  sa=$(operator_service_account)
  OPERATOR_BOUND_ROLES=$(kubectl get clusterrolebindings,rolebindings -A -o json 2>/dev/null \
    | jq -r --arg sa "$sa" --arg ns "$NAMESPACE" '
        .items[]
        | select([.subjects[]? | select(.kind=="ServiceAccount" and .name==$sa and (.namespace//$ns)==$ns)] | length > 0)
        | "\(.roleRef.kind) \(.roleRef.name)"' 2>/dev/null | sort -u) || OPERATOR_BOUND_ROLES=""
  printf '%s' "$OPERATOR_BOUND_ROLES"
}

declare -A RBAC_NAME_CACHE=()

# resolve_rbac_name KIND UPSTREAM_NAME -> the name this cluster uses, or empty
resolve_rbac_name() {
  local kind=$1 up=$2 key="$1/$2" cand line rk rn
  [[ -n ${RBAC_NAME_CACHE[$key]+x} ]] && { printf '%s' "${RBAC_NAME_CACHE[$key]}"; return 0; }

  # 1. the upstream name itself
  if [[ $(probe_rbac_object "$kind" "$up") == present ]]; then
    RBAC_NAME_CACHE[$key]=$up; printf '%s' "$up"; return 0
  fi
  # 2. a role bound to the operator whose name ends with the upstream name
  while IFS=' ' read -r rk rn; do
    [[ -z ${rn:-} ]] && continue
    [[ $rk == "$kind" ]] || continue
    if [[ $rn == "$up" || $rn == *-"$up" ]]; then
      RBAC_NAME_CACHE[$key]=$rn; printf '%s' "$rn"; return 0
    fi
  done <<< "$(operator_bound_roles)"
  # 3. the two prefixes charts use most often
  for cand in "${NAMESPACE}-${up}" "${HELM_RELEASE:-}-${up}"; do
    [[ $cand == -* ]] && continue
    if [[ $(probe_rbac_object "$kind" "$cand") == present ]]; then
      RBAC_NAME_CACHE[$key]=$cand; printf '%s' "$cand"; return 0
    fi
  done
  RBAC_NAME_CACHE[$key]=""
  return 0
}

# The Strimzi chart renders the entity-operator delegation binding with
#   subjects[].namespace: {{ .Release.Namespace }}
# so when the Helm release lives in a different namespace from the operator's ServiceAccount,
# the binding grants an identity that does not exist. Nothing notices until a release adds a
# rule that exists ONLY in clusterrole/strimzi-entity-operator - which 0.51.0 does with
# kafkatopics/finalizers - and every reconcile then fails with a 403 escalation error.
#
# The repair is an ADDITIVE RoleBinding under a distinct name. RBAC is a union, so this grants
# the missing rights without touching the chart's object, which means a later helm upgrade
# cannot revert it. Remove it once the chart itself is correct.
report_entity_operator_bindings() {
  local eo
  eo=$(resolve_rbac_name ClusterRole strimzi-entity-operator)
  log_info "bindings referencing clusterrole/${eo:-strimzi-entity-operator}:"
  kubectl get rolebindings,clusterrolebindings -A -o json 2>/dev/null | jq -r --arg eo "${eo:-strimzi-entity-operator}" '
    .items[]|select(.roleRef.name==$eo)|
    "    \(.kind) \(.metadata.namespace // "<cluster>")/\(.metadata.name)  subjects=\([.subjects[]?|"\(.kind):\(.namespace // "-"):\(.name)"]|join(","))"' >&2 \
    || log_warn "    (could not list bindings)"
}

operator_service_account() {
  local sa
  sa=$(kq get "deploy/$OPERATOR_DEPLOYMENT" -o jsonpath='{.spec.template.spec.serviceAccountName}' || true)
  printf '%s' "${sa:-strimzi-cluster-operator}"
}

repair_entity_operator_delegation() {
  local sa manifest eo
  sa=$(operator_service_account)
  eo=$(resolve_rbac_name ClusterRole strimzi-entity-operator)
  [[ -n $eo ]] || { log_error "cannot find the entity-operator ClusterRole to bind"; return 1; }
  report_entity_operator_bindings
  log_warn "the operator runs as system:serviceaccount:$NAMESPACE:$sa but no binding grants it"
  log_warn "the strimzi-entity-operator rules in '$NAMESPACE'."
  if [[ -n $HELM_RELEASE && $HELM_NAMESPACE != "$NAMESPACE" ]]; then
    log_warn "cause: the chart sets the binding's subject namespace to the RELEASE namespace"
    log_warn "('$HELM_NAMESPACE'), but the ServiceAccount lives in '$NAMESPACE'."
  fi
  log_info "fix: an additive RoleBinding '$MIGRATION_RB_NAME' in '$NAMESPACE'. RBAC is a union,"
  log_info "and because the chart does not own this object a helm upgrade cannot revert it."
  confirm "Create rolebinding/$MIGRATION_RB_NAME in $NAMESPACE for ServiceAccount $NAMESPACE:$sa?"
  manifest="$WORKDIR/$MIGRATION_RB_NAME.yaml"
  cat > "$manifest" <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: $MIGRATION_RB_NAME
  namespace: $NAMESPACE
  labels:
    app: strimzi
    strimzi.io/added-by: migration-script
  annotations:
    migration/purpose: >-
      Grants the cluster operator ServiceAccount the strimzi-entity-operator rules in this
      namespace. The chart's own delegation binding names the release namespace as the
      subject namespace, which does not match where the ServiceAccount actually lives.
      Safe to delete once the chart renders a correct binding.
subjects:
  - kind: ServiceAccount
    name: $sa
    namespace: $NAMESPACE
roleRef:
  kind: ClusterRole
  name: $eo
  apiGroup: rbac.authorization.k8s.io
YAML
  run kubectl apply -f "$manifest"
  log_ok "applied rolebinding/$MIGRATION_RB_NAME (manifest kept at $manifest)"
}

operator_can_grant_finalizers() {
  local sa subject ans
  sa=$(operator_service_account)
  subject="system:serviceaccount:$NAMESPACE:$sa"
  ans=$(kubectl auth can-i update kafkatopics.kafka.strimzi.io --subresource=finalizers \
          -n "$NAMESPACE" --as="$subject" 2>/dev/null || true)
  printf '%s' "$ans"
}

# Applying a manifest is not evidence that the rules are in effect. Verify structurally, and
# then effectively via SubjectAccessReview when impersonation is available.
verify_operator_rbac() {
  local ver=$1 sa subject bad=0
  $DRY_RUN && { log_info "dry run: would verify the operator holds the entity-operator finalizers rules"; return 0; }
  # Rules the operator must HOLD in order to GRANT them to the Entity Operator Role.
  # Added in 0.51.0; without them reconciliation dies with a 403 escalation error.
  case $ver in
    0.4[0-9].*) log_info "$ver predates the entity-operator finalizers rules; nothing to verify"; return 0;;
  esac

  local cr_json="" have="" eo_name=""
  eo_name=$(resolve_rbac_name ClusterRole strimzi-entity-operator)
  if [[ -z $eo_name ]]; then
    log_warn "no ClusterRole matching strimzi-entity-operator found - skipping RBAC verification"
    return 0
  fi
  [[ $eo_name == strimzi-entity-operator ]] || log_info "entity-operator ClusterRole is named '$eo_name' here"
  cr_json=$(kubectl get clusterrole "$eo_name" -o json 2>/dev/null || true)
  if ! jq -e . >/dev/null 2>&1 <<<"$cr_json"; then
    log_warn "cannot read clusterrole/strimzi-entity-operator - skipping RBAC verification"
    return 0
  fi
  have=$(jq -r '[.rules[]?|select((.resources//[])|index("kafkatopics/finalizers"))
                          |select((.verbs//[])|index("update"))]|length' <<<"$cr_json")
  if [[ ${have:-0} -lt 1 ]]; then
    log_error "clusterrole/$eo_name still lacks: kafkatopics/finalizers, kafkausers/finalizers [update]"
    log_error "The cluster operator must HOLD these to grant them to the '$KAFKA_CR_NAME-entity-operator' Role."
    log_error "Without them every reconcile fails with an RBAC escalation 403."
    if [[ -n $HELM_RELEASE ]]; then
      log_error "This ClusterRole is rendered by the Strimzi Helm chart, so if release '$HELM_RELEASE'"
      log_error "still pins the 0.48.0 subchart, any helm operation restores the old rules. Verify with:"
      log_error "  helm get manifest $HELM_RELEASE -n $HELM_NAMESPACE | grep -A40 'name: strimzi-entity-operator' | grep -c finalizers"
      log_error "The durable fix is to bump the subchart version, not to patch the ClusterRole."
    fi
    bad=1
  else
    log_ok "clusterrole/$eo_name carries the finalizers rules"
  fi

  sa=$(operator_service_account)
  subject="system:serviceaccount:$NAMESPACE:$sa"
  local ans
  ans=$(operator_can_grant_finalizers)
  case $ans in
    yes) log_ok "$subject can update kafkatopics/finalizers in $NAMESPACE";;
    no)
      log_error "$subject CANNOT update kafkatopics/finalizers in $NAMESPACE"
      if $SKIP_RBAC_REPAIR; then
        log_error "--skip-rbac-repair given; not adding the delegation binding"
        bad=1
      else
        repair_entity_operator_delegation
        ans=$(operator_can_grant_finalizers)
        if [[ $ans == yes ]]; then
          log_ok "$subject can now update kafkatopics/finalizers in $NAMESPACE"
        else
          log_error "still denied after adding rolebinding/$MIGRATION_RB_NAME (got: ${ans:-unknown})"
          log_error "inspect the bindings above - the ClusterRole or the SA name may differ"
          bad=1
        fi
      fi
      ;;
    *) log_info "could not run SubjectAccessReview (impersonation not permitted); relied on the structural check";;
  esac

  if (( bad )); then
    $FORCE || die "operator RBAC is not in effect - fix it before the operator reconciles"
    log_warn "--force given: continuing with known-insufficient RBAC"
  fi
}

# ========================================================================================
# Operator upgrade
# ========================================================================================
kafka_image_list() { # opver "4.2.0 4.2.1 4.3.0"
  local opver=$1 v out=""
  for v in $2; do out+="$v=$KAFKA_IMAGE_REPO:$opver-kafka-$v"$'\n'; done
  printf '%s' "$out"
}

upgrade_operator_image_mode() {
  local opver=$1 kvers=$2 latest=${2##* } bridge imgs
  bridge=$(op_bridge_version "$opver")
  imgs=$(kafka_image_list "$opver" "$kvers")

  [[ -n $HELM_RELEASE ]] && log_warn "mode=image drifts from Helm release '$HELM_RELEASE' - the next helm upgrade will revert it"

  # RBAC must land BEFORE the new image starts reconciling, or the Entity Operator Role
  # patch is rejected as a privilege escalation.
  apply_operator_rbac "$opver"

  run k set env "deploy/$OPERATOR_DEPLOYMENT" \
    "STRIMZI_KAFKA_IMAGES=$imgs" \
    "STRIMZI_KAFKA_CONNECT_IMAGES=$imgs" \
    "STRIMZI_KAFKA_MIRROR_MAKER_2_IMAGES=$imgs" \
    "STRIMZI_DEFAULT_KAFKA_VERSION=$latest" \
    "STRIMZI_DEFAULT_KAFKA_EXPORTER_IMAGE=$KAFKA_IMAGE_REPO:$opver-kafka-$latest" \
    "STRIMZI_DEFAULT_CRUISE_CONTROL_IMAGE=$KAFKA_IMAGE_REPO:$opver-kafka-$latest" \
    "STRIMZI_DEFAULT_TOPIC_OPERATOR_IMAGE=$OPERATOR_IMAGE_REPO:$opver" \
    "STRIMZI_DEFAULT_USER_OPERATOR_IMAGE=$OPERATOR_IMAGE_REPO:$opver" \
    "STRIMZI_DEFAULT_KAFKA_INIT_IMAGE=$OPERATOR_IMAGE_REPO:$opver" \
    "STRIMZI_DEFAULT_KAFKA_BRIDGE_IMAGE=$BRIDGE_IMAGE_REPO:$bridge" \
    "STRIMZI_DEFAULT_KANIKO_EXECUTOR_IMAGE=$KANIKO_IMAGE_REPO:$opver" \
    "STRIMZI_DEFAULT_MAVEN_BUILDER=$MAVEN_IMAGE_REPO:$opver"

  # MirrorMaker 1 and JmxTrans no longer exist; the current deployment still carries both
  # (and STRIMZI_KAFKA_MIRROR_MAKER_IMAGES is malformed in the 0.48.0 values). Drop them.
  local stale=()
  kq get "deploy/$OPERATOR_DEPLOYMENT" -o json \
    | jq -e '.spec.template.spec.containers[]?.env[]?|select(.name=="STRIMZI_KAFKA_MIRROR_MAKER_IMAGES")' >/dev/null 2>&1 \
    && stale+=("STRIMZI_KAFKA_MIRROR_MAKER_IMAGES-")
  kq get "deploy/$OPERATOR_DEPLOYMENT" -o json \
    | jq -e '.spec.template.spec.containers[]?.env[]?|select(.name=="STRIMZI_DEFAULT_JMXTRANS_IMAGE")' >/dev/null 2>&1 \
    && stale+=("STRIMZI_DEFAULT_JMXTRANS_IMAGE-")
  if (( ${#stale[@]} > 0 )); then
    log_info "removing obsolete env vars: ${stale[*]//-/}"
    run k set env "deploy/$OPERATOR_DEPLOYMENT" "${stale[@]}"
  fi

  run k set image "deploy/$OPERATOR_DEPLOYMENT" "strimzi-cluster-operator=$OPERATOR_IMAGE_REPO:$opver"
}

upgrade_operator() {
  local opver=$1
  local running; running=$(operator_running_image || true)
  if [[ $running == *:$opver ]]; then
    log_info "operator already running $opver - nothing to do"
    return 0
  fi
  local kvers; kvers=$(op_kafka_support "$opver")
  log_info "upgrading cluster operator to $opver (mode=$OPERATOR_MODE)"
  case $OPERATOR_MODE in
    image) upgrade_operator_image_mode "$opver" "$kvers";;
    helm)
      run_sh "helm upgrade '$HELM_RELEASE' '$HELM_CHART' --version '$opver' \
                -n '$HELM_NAMESPACE' --reuse-values --wait --timeout 10m $HELM_EXTRA_ARGS"
      ;;
    cmd)
      local cmd=${OPERATOR_UPGRADE_CMD//\{\{VERSION\}\}/$opver}
      log_info "running: $cmd"
      run_sh "$cmd"
      ;;
  esac
  wait_for_operator
}

# ========================================================================================
# Kafka version / metadataVersion
# ========================================================================================
strip_legacy_kafka_config() {
  local key
  for key in inter.broker.protocol.version log.message.format.version; do
    if kq get kafka "$KAFKA_CR_NAME" -o json | jq -e --arg k "$key" '.spec.kafka.config[$k]' >/dev/null; then
      log_info "removing obsolete spec.kafka.config['$key']"
      run k patch kafka "$KAFKA_CR_NAME" --type=json \
        -p "[{\"op\":\"remove\",\"path\":\"/spec/kafka/config/$key\"}]"
    fi
  done
}

upgrade_kafka() { # upgrade_kafka TARGET_KAFKA_VERSION OPERATOR_VERSION
  local target=$1 opver=$2
  local metadata; metadata=$(metadata_version_for "$opver" "$target")
  local cur; cur=$(kafka_get '{.spec.kafka.version}' || echo "")

  in_list "$target" "$(op_kafka_support "$opver")" \
    || die "Kafka $target is not supported by operator $opver"
  # Guard against a reverted/rolled-back operator: patching an unsupported version just
  # parks the CR in NotReady until someone notices.
  $DRY_RUN || require_operator_version "$opver" "Kafka $target"

  strip_legacy_kafka_config

  if [[ $cur == "$target" ]]; then
    log_info "spec.kafka.version is already $target"
  else
    log_info "setting spec.kafka.version: $cur -> $target"
    run k patch kafka "$KAFKA_CR_NAME" --type=merge -p "{\"spec\":{\"kafka\":{\"version\":\"$target\"}}}"
    wait_for_kafka_ready "kafka version $target"
  fi

  if $SKIP_METADATA_BUMP; then
    log_warn "--skip-metadata-bump: metadataVersion left at $(kafka_get '{.spec.kafka.metadataVersion}' || echo unset)"
    log_warn "raise it to '$metadata' before the next operator hop"
    return 0
  fi

  local curm; curm=$(kafka_get '{.spec.kafka.metadataVersion}' || echo "")
  if [[ $curm == "$metadata" ]]; then
    log_info "spec.kafka.metadataVersion is already $metadata"
    return 0
  fi
  log_warn "raising metadataVersion $curm -> $metadata. This is effectively one-way."
  confirm "Set spec.kafka.metadataVersion=$metadata now?"
  run k patch kafka "$KAFKA_CR_NAME" --type=merge -p "{\"spec\":{\"kafka\":{\"metadataVersion\":\"$metadata\"}}}"
  wait_for_kafka_ready "metadataVersion $metadata"
}

# ========================================================================================
# v1 conversion
# ========================================================================================
CONV_BIN=""
# The conversion tool is compiled for Java 21 (class file version 65). An older JRE fails with
# UnsupportedClassVersionError only once the tool is actually invoked, so check the version up
# front rather than assuming that any `java` on PATH will do.
java_major_version() {
  local line v=""
  command -v java >/dev/null 2>&1 || { printf ''; return 0; }
  line=$(java -version 2>&1 | head -1) || { printf ''; return 0; }
  # "21.0.2"           -> 21
  # "1.8.0_402"        -> 8
  v=$(sed -n 's/.*version "1\.\([0-9][0-9]*\).*/\1/p' <<<"$line")
  [[ -n $v ]] || v=$(sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' <<<"$line")
  printf '%s' "$v"
}

local_java_is_usable() {
  local v
  v=$(java_major_version)
  [[ -n $v ]] || return 1
  (( v >= CONVERSION_JAVA_MIN ))
}

use_local_conversion() {
  local v
  case $CONVERSION_MODE in
    local)
      if ! local_java_is_usable; then
        v=$(java_major_version)
        log_error "--conversion-mode local was requested but the local Java is ${v:-absent}"
        log_error "the $CONVERSION_HOP_VERSION conversion tool needs Java $CONVERSION_JAVA_MIN or newer"
        log_error "re-run with --conversion-mode job to run it inside the operator image instead"
        die "local Java is too old for the conversion tool"
      fi
      return 0;;
    job)   return 1;;
    auto)  local_java_is_usable;;
    *)     die "--conversion-mode must be auto, local or job";;
  esac
}

fetch_conversion_tool() {
  local ver=$CONVERSION_HOP_VERSION
  local tgz="$DL_DIR/strimzi-v1-api-conversion-$ver.tar.gz"
  download "$GH_RELEASES/$ver/strimzi-v1-api-conversion-$ver.tar.gz" "$tgz"
  [[ -d "$DL_DIR/v1-api-conversion-$ver" ]] || tar xzf "$tgz" -C "$DL_DIR"
  CONV_BIN="$DL_DIR/v1-api-conversion-$ver/bin/v1-api-conversion.sh"
  chmod +x "$CONV_BIN"
  log_ok "conversion tool: $CONV_BIN"
}

conversion_job() {
  local name; name="strimzi-v1-conv-$(date +%s)"
  local args="" a
  for a in "$@"; do args+="            - \"$a\""$'\n'; done
  local manifest="$WORKDIR/$name.yaml"
  cat > "$manifest" <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: strimzi-v1-api-conversion
  namespace: $NAMESPACE
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: strimzi-v1-api-conversion
rules:
  - apiGroups: ["kafka.strimzi.io"]
    resources: ["kafkas","kafkanodepools","kafkaconnects","kafkaconnectors","kafkabridges","kafkamirrormaker2s","kafkarebalances","kafkatopics","kafkausers"]
    verbs: ["get","list","patch","update"]
  - apiGroups: ["core.strimzi.io"]
    resources: ["strimzipodsets"]
    verbs: ["get","list","patch","update"]
  - apiGroups: ["apiextensions.k8s.io"]
    resources: ["customresourcedefinitions","customresourcedefinitions/status"]
    verbs: ["get","list","patch","update"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get","list","create","patch","update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: strimzi-v1-api-conversion
subjects:
  - kind: ServiceAccount
    name: strimzi-v1-api-conversion
    namespace: $NAMESPACE
roleRef:
  kind: ClusterRole
  name: strimzi-v1-api-conversion
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: batch/v1
kind: Job
metadata:
  name: $name
  namespace: $NAMESPACE
spec:
  backoffLimit: 0
  template:
    spec:
      serviceAccountName: strimzi-v1-api-conversion
      restartPolicy: Never
      containers:
        - name: conversion
          image: $OPERATOR_IMAGE_REPO:$CONVERSION_HOP_VERSION
          command:
            - /opt/v1-api-conversion/bin/v1-api-conversion.sh
$args
YAML
  log_info "running conversion as Job $name ($*)"
  run kubectl apply -f "$manifest"
  $DRY_RUN && return 0
  if ! k wait --for=condition=complete "job/$name" --timeout=15m; then
    log_error "conversion Job did not complete; logs:"
    k logs "job/$name" >&2 || true
    die "conversion failed"
  fi
  k logs "job/$name" >&2 || true
  log_ok "Job $name completed"
}

conversion_run() {
  if use_local_conversion; then
    log_info "running conversion locally: $*"
    run "$CONV_BIN" "$@"
  else
    conversion_job "$@"
  fi
}

snapshot_crs() { # snapshot_crs DIRNAME
  local d="$BACKUP_DIR/$1" kind
  mkdir -p "$d"
  for kind in kafkas kafkanodepools kafkatopics kafkausers kafkaconnects kafkaconnectors \
              kafkamirrormaker2s kafkabridges kafkarebalances; do
    kq get "$kind" -o yaml > "$d/$kind.yaml" 2>/dev/null || true
  done
}

convert_to_v1() {
  banner "PHASE 5 - convert custom resources and CRDs to the v1 API"

  local served stored
  served=$(crd_served) || die "CRD kafkas.kafka.strimzi.io not found"
  if ! in_list v1 "$served"; then
    if $DRY_RUN; then
      log_warn "installed CRDs do not serve v1 yet (phase 3 provides them); continuing the dry run"
    else
      die "installed CRDs do not serve v1 - phase 3 must run first"
    fi
  fi

  stored=$(crd_stored)
  if [[ $stored != *v1beta2* && $stored == *v1* ]]; then
    log_ok "stored version is already v1 ($stored) - conversion appears complete"
  elif $DRY_RUN; then
    log_warn "dry run: would convert all custom resources with 'convert-resource --namespace $NAMESPACE'"
    log_warn "dry run: would then run 'crd-upgrade' to make v1 the stored version"
  else
    use_local_conversion && fetch_conversion_tool \
      || log_info "conversion will run as a Kubernetes Job (java not found or --conversion-mode job)"

    snapshot_crs pre-v1
    confirm "Convert all Strimzi custom resources in namespace '$NAMESPACE' to the v1 API?"
    conversion_run convert-resource --namespace "$NAMESPACE"
    restore_delete_claim

    log_info "flipping the CRD stored version to v1 (crd-upgrade)"
    confirm "Run crd-upgrade? This makes v1 the stored version and drops v1beta2 from CRD status."
    conversion_run crd-upgrade

    stored=$(crd_stored)
    log_info "kafkas stored versions after crd-upgrade: $stored"
    if { [[ $stored != *v1* ]] || [[ $stored == *v1beta2* ]]; }; then
      die "crd-upgrade left stored versions as '$stored' - do NOT proceed to phase 6"
    fi

    snapshot_crs post-v1
    log_info "review the diff: diff -ru $BACKUP_DIR/pre-v1 $BACKUP_DIR/post-v1"
    wait_for_kafka_ready "v1 conversion"
  fi

  remap_helm_release_metadata
  log_ok "custom resources and CRDs are on the v1 API"
}

restore_delete_claim() {
  local rec="$BACKUP_DIR/nodepool-deleteclaim.txt"
  [[ -s $rec ]] || return 0
  local pool id kv want have idx pool_json
  while read -r pool _ id kv; do
    want=${kv#deleteClaim=}
    [[ $want == unset ]] && continue
    pool_json=$(kq get kafkanodepool "$pool" -o json) || continue
    have=$(jq -r --argjson i "$id" \
      '(.spec.storage.volumes//[])[]|select(.id==$i)|if has("deleteClaim") then .deleteClaim else "unset" end' <<<"$pool_json")
    idx=$(jq -r --argjson i "$id" \
      '[(.spec.storage.volumes//[])|to_entries[]|select(.value.id==$i)|.key]|first // empty' <<<"$pool_json")
    if [[ $have == unset && -n $idx ]]; then
      log_warn "conversion dropped deleteClaim on node pool '$pool' volume $id; restoring $want"
      run k patch kafkanodepool "$pool" --type=json \
        -p "[{\"op\":\"add\",\"path\":\"/spec/storage/volumes/$idx/deleteClaim\",\"value\":$want}]" \
        || log_warn "could not restore deleteClaim on $pool volume $id - set it manually"
    fi
  done < "$rec"
}

# ========================================================================================
# Helm release metadata rewrite (v1beta2 -> v1 inside the stored manifest)
# ========================================================================================
# Read release state from the Secret rather than through `helm get manifest`. That call was
# both a needless dependency and the source of two failures: a `x=$(...); rc=$?` assignment
# that set -e turned into a silent exit, and multi-megabyte output fed to bash string ops.
release_secrets() { # release_secrets [deployed]  -> secret names, oldest first
  local sel="owner=helm,name=$HELM_RELEASE"
  [[ ${1:-} == deployed ]] && sel+=",status=deployed"
  kubectl -n "$HELM_NAMESPACE" get secret -l "$sel" \
    --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | sed 's|^secret/||'
}

# Decode one release Secret to a file. Large releases stay out of shell variables entirely.
release_secret_to_file() { # release_secret_to_file SECRET_NAME DEST
  kubectl -n "$HELM_NAMESPACE" get secret "$1" -o jsonpath='{.data.release}' 2>/dev/null \
    | helm_release_decode > "$2" 2>/dev/null || return 1
  jq -e . >/dev/null 2>&1 < "$2" || return 1
  return 0
}

# Prints the count of v1beta2 references in a stored revision, or "unknown" if it could not be
# decoded. An unreadable revision must never be mistaken for a clean one.
stored_v1beta2_count() { # stored_v1beta2_count SECRET_NAME
  local tmp
  tmp=$(mktemp "$WORKDIR/.rel-XXXXXX") || { printf 'unknown'; return 0; }
  if ! release_secret_to_file "$1" "$tmp"; then rm -f "$tmp"; printf 'unknown'; return 0; fi
  jq -r '.manifest // ""' < "$tmp" | grep -c 'strimzi\.io/v1beta2' || true
  rm -f "$tmp"
}

# ----------------------------------------------------------------------------------------
# Release-manifest remap without the helm-mapkubeapis plugin
# ----------------------------------------------------------------------------------------
# Helm stores each revision in a Secret sh.helm.release.v1.<release>.v<n> whose data.release
# is base64( gzip( JSON ) ) - and kubectl's jsonpath adds Kubernetes' own base64 layer on top,
# hence the double decode. Only the .manifest string is rewritten, via jq, so JSON escaping in
# unrelated fields (values containing quotes, tabs, newlines) cannot be corrupted.
helm_release_decode() { base64 -d | base64 -d | gunzip; }
helm_release_encode() { gzip -n -c | base64 | tr -d '\n' | base64 | tr -d '\n'; }

# Rewrite the Strimzi apiVersions inside a release JSON's .manifest.
#
# jq's gsub is quadratic in the number of matches, so a release with thousands of Strimzi
# resources (each KafkaTopic counts) never finishes - measured: 14k replacements in a 3.4 MB
# manifest does not complete in 30s, while the route below takes 0.3s. The manifest is
# therefore extracted, rewritten with sed, and reattached with --rawfile.
#
# jq -r appends a newline of its own; rtrimstr removes exactly that one, so a manifest both
# with and without a trailing newline round-trips unchanged (verified both ways).
remap_release_json() { # remap_release_json SRC_JSON DEST_JSON SCRATCH_DIR
  local src=$1 dst=$2 wd=$3
  jq -e '.manifest|type == "string"' >/dev/null 2>&1 < "$src" \
    || { log_error "release .manifest is missing or not a string"; return 1; }
  jq -r '.manifest' < "$src" > "$wd/manifest.txt" || return 1
  sed -i -e 's|kafka\.strimzi\.io/v1beta2|kafka.strimzi.io/v1|g' \
         -e 's|core\.strimzi\.io/v1beta2|core.strimzi.io/v1|g' "$wd/manifest.txt" || return 1
  jq --rawfile m "$wd/manifest.txt" '.manifest = ($m | rtrimstr("\n"))' < "$src" > "$dst" || return 1
  return 0
}

# Rewrite a revision's stored manifest in place. mapkubeapis appends a new revision instead;
# in place is simpler and Helm keeps no checksum over the manifest, so nothing is invalidated.
# All large data is handled in files: bash string operations on megabyte values do not scale.
remap_one_revision() { # remap_one_revision SECRET_NAME
  local name=$1 before after backup tmpd
  backup="$BACKUP_DIR/$name.before-remap.yaml"
  kubectl -n "$HELM_NAMESPACE" get secret "$name" -o yaml > "$backup" 2>/dev/null \
    || { log_error "  $name: could not back up"; return 1; }

  tmpd=$(mktemp -d "$WORKDIR/.remap-XXXXXX") || return 1
  if ! release_secret_to_file "$name" "$tmpd/rel.json"; then
    log_error "  $name: could not decode release secret"; rm -rf "$tmpd"; return 1
  fi

  before=$(jq -r '.manifest // ""' < "$tmpd/rel.json" | grep -c 'strimzi\.io/v1beta2' || true)
  if [[ ${before:-0} -eq 0 ]]; then
    log_info "  $name: already clean"; rm -rf "$tmpd"; return 0
  fi

  if ! remap_release_json "$tmpd/rel.json" "$tmpd/new.json" "$tmpd"; then
    log_error "  $name: remap failed"; rm -rf "$tmpd"; return 1
  fi
  after=$(jq -r '.manifest // ""' < "$tmpd/new.json" | grep -c 'strimzi\.io/v1beta2' || true)
  if [[ ${after:-1} -ne 0 ]]; then
    log_error "  $name: remap left $after v1beta2 reference(s) - refusing to write"
    rm -rf "$tmpd"; return 1
  fi
  # Prove nothing outside .manifest changed.
  jq -S 'del(.manifest)' < "$tmpd/rel.json" > "$tmpd/a.json"
  jq -S 'del(.manifest)' < "$tmpd/new.json" > "$tmpd/b.json"
  if ! diff -q "$tmpd/a.json" "$tmpd/b.json" >/dev/null; then
    log_error "  $name: remap altered fields outside .manifest - refusing to write"
    rm -rf "$tmpd"; return 1
  fi

  log_info "  $name: rewriting $before reference(s) to /v1 (backup: $backup)"
  helm_release_encode < "$tmpd/new.json" > "$tmpd/enc.b64"
  jq -n --rawfile r "$tmpd/enc.b64" '{data:{release:($r|rtrimstr("\n"))}}' > "$tmpd/patch.json"
  if ! run kubectl -n "$HELM_NAMESPACE" patch secret "$name" --type=merge \
        --patch-file "$tmpd/patch.json"; then
    log_error "  $name: patch failed"; rm -rf "$tmpd"; return 1
  fi
  rm -rf "$tmpd"

  $DRY_RUN && return 0
  local verify
  verify=$(stored_v1beta2_count "$name")
  case $verify in
    0) log_ok "  $name: verified clean";;
    *) log_error "  $name: post-write check returned '$verify'. Restore with:"
       log_error "    kubectl -n $HELM_NAMESPACE apply -f $backup"
       return 1;;
  esac
  return 0
}

remap_release_manifest_native() {
  local -a targets=()
  local n
  if $REMAP_ALL_REVISIONS; then
    while IFS= read -r n; do [[ -n $n ]] && targets+=("$n"); done < <(release_secrets)
    log_info "rewriting all ${#targets[@]} stored revision(s) of '$HELM_RELEASE'"
  else
    while IFS= read -r n; do [[ -n $n ]] && targets+=("$n"); done < <(release_secrets deployed)
    log_info "rewriting the deployed revision of '$HELM_RELEASE'"
  fi
  if (( ${#targets[@]} == 0 )); then
    log_error "no release secrets for '$HELM_RELEASE' in namespace '$HELM_NAMESPACE'"
    log_error "check: kubectl -n $HELM_NAMESPACE get secret -l owner=helm,name=$HELM_RELEASE"
    return 1
  fi

  confirm "Rewrite kafka.strimzi.io/v1beta2 -> /v1 in ${#targets[@]} stored revision(s)?"
  local failed=0
  for n in "${targets[@]}"; do remap_one_revision "$n" || failed=1; done
  (( failed )) && return 1

  if ! $REMAP_ALL_REVISIONS && ! $DRY_RUN; then
    local other=0
    while IFS= read -r n; do
      [[ -n $n ]] || continue
      case $(stored_v1beta2_count "$n") in 0|unknown) ;; *) other=$((other+1));; esac
    done < <(release_secrets)
    if (( other )); then
      log_warn "$other older revision(s) still reference v1beta2. helm upgrade does not read them,"
      log_warn "but 'helm rollback' to one would fail. Re-run with --remap-all-revisions to fix."
    fi
  fi
  return 0
}

write_mapkubeapis_mapfile() {
  local mapfile=$1 kind
  {
    echo "mappings:"
    for kind in Kafka KafkaNodePool KafkaTopic KafkaUser KafkaConnect KafkaConnector \
                KafkaMirrorMaker2 KafkaBridge KafkaRebalance; do
      printf '  - deprecatedAPI: "apiVersion: kafka.strimzi.io/v1beta2\\nkind: %s"\n' "$kind"
      printf '    newAPI: "apiVersion: kafka.strimzi.io/v1\\nkind: %s"\n' "$kind"
      printf '    deprecatedInVersion: "v0.49.0"\n'
      printf '    removedInVersion: "v1.0.0"\n'
    done
    printf '  - deprecatedAPI: "apiVersion: core.strimzi.io/v1beta2\\nkind: StrimziPodSet"\n'
    printf '    newAPI: "apiVersion: core.strimzi.io/v1\\nkind: StrimziPodSet"\n'
    printf '    deprecatedInVersion: "v0.49.0"\n'
    printf '    removedInVersion: "v1.0.0"\n'
  } > "$mapfile"
}

remap_helm_release_metadata() {
  [[ -n $HELM_RELEASE ]] || { log_info "no Helm release detected - skipping release metadata rewrite"; return 0; }
  $SKIP_HELM_REMAP && { log_warn "--skip-helm-remap: release metadata still references v1beta2"; return 0; }
  # helm itself is not required: the built-in rewrite works directly on the release Secret.

  local dep manifest_has=""
  dep=$(release_secrets deployed | tail -1)
  if [[ -z $dep ]]; then
    log_warn "no deployed release secret for '$HELM_RELEASE' in '$HELM_NAMESPACE' - skipping remap"
    log_warn "check: kubectl -n $HELM_NAMESPACE get secret -l owner=helm,name=$HELM_RELEASE"
    return 0
  fi
  manifest_has=$(stored_v1beta2_count "$dep")
  if [[ $manifest_has == unknown ]]; then
    log_warn "could not decode release secret $dep - skipping the remap rather than guessing"
    return 0
  fi
  if [[ $manifest_has == 0 ]]; then
    log_ok "release '$HELM_RELEASE' ($dep) has no v1beta2 references"
    return 0
  fi

  log_warn "release '$HELM_RELEASE' ($dep) stores $manifest_has v1beta2 reference(s)."
  log_warn "Once the $FINAL_OPERATOR_VERSION CRDs are applied, 'helm upgrade' will fail with"
  log_warn "  'unable to build kubernetes objects from current release manifest ... no matches for kind Kafka'"
  log_warn "because Helm renders the PREVIOUS revision to compute its diff."

  # Default: rewrite the stored manifest ourselves. No plugin, no network access.
  if ! $USE_MAPKUBEAPIS; then
    if remap_release_manifest_native; then
      log_ok "release metadata rewritten"
      log_warn "this fixes Helm's bookkeeping only - the chart templates still need apiVersion: kafka.strimzi.io/v1"
      return 0
    fi
    log_error "the built-in rewrite failed - see above"
    $FORCE || die "cannot rewrite the release metadata"
    return 0
  fi

  if ! helm plugin list 2>/dev/null | grep -q '^mapkubeapis'; then
    log_error "--use-mapkubeapis given but the plugin is not installed:"
    log_error "  helm plugin install https://github.com/helm/helm-mapkubeapis"
    log_error "omit --use-mapkubeapis to use the built-in rewrite"
    $FORCE || die "mapkubeapis requested but unavailable"
    return 0
  fi

  local mapfile="$WORKDIR/strimzi-v1beta2-to-v1.yaml"
  write_mapkubeapis_mapfile "$mapfile"
  log_ok "wrote mapping file $mapfile"
  run_sh "helm mapkubeapis '$HELM_RELEASE' -n '$HELM_NAMESPACE' --mapfile '$mapfile' --dry-run"
  confirm "Rewrite the stored release metadata of '$HELM_RELEASE' to kafka.strimzi.io/v1?"
  run_sh "helm mapkubeapis '$HELM_RELEASE' -n '$HELM_NAMESPACE' --mapfile '$mapfile'"
  log_ok "release metadata rewritten"
  log_warn "this fixes Helm's bookkeeping only - the chart templates still need apiVersion: kafka.strimzi.io/v1"
}

repair_only() {
  banner "repair mode - Helm release metadata"
  need_cmd kubectl; need_cmd jq
  if [[ -z $HELM_RELEASE || -z $HELM_NAMESPACE ]]; then
    kq get kafka "$KAFKA_CR_NAME" >/dev/null 2>&1 \
      || die "cannot auto-detect the release: Kafka CR '$KAFKA_CR_NAME' not readable. Pass --helm-release/--helm-namespace."
    detect_helm_owner
  fi
  [[ -n $HELM_RELEASE ]] || die "no Helm release name; pass --helm-release"
  [[ -n $HELM_NAMESPACE ]] || HELM_NAMESPACE=$NAMESPACE
  log_info "release '$HELM_RELEASE' in namespace '$HELM_NAMESPACE'"
  command -v helm >/dev/null 2>&1 && { helm history "$HELM_RELEASE" -n "$HELM_NAMESPACE" >&2 || true; }
  log_info "release secrets:"; release_secrets | sed 's/^/    /' >&2 || true
  SKIP_HELM_REMAP=false
  remap_helm_release_metadata
}

# ========================================================================================
# Post-migration Helm readiness
# ========================================================================================
# After an in-place migration the follow-up `helm upgrade` to the 1.1.0 chart is what brings
# the release back in line with the cluster. Three things have to be true for it to succeed,
# and all three are silently breakable by the migration itself.
check_helm_upgrade_readiness() {
  [[ -n $HELM_RELEASE ]] || return 0
  banner "readiness for the follow-up helm upgrade"
  local problems=0

  # 1. Helm ownership metadata must have survived the v1 conversion, or helm upgrade will
  #    refuse with "invalid ownership metadata".
  local rel ns
  rel=$(kafka_get '{.metadata.annotations.meta\.helm\.sh/release-name}' || true)
  ns=$(kafka_get '{.metadata.annotations.meta\.helm\.sh/release-namespace}' || true)
  if [[ $rel == "$HELM_RELEASE" ]]; then
    log_ok "Kafka CR still carries Helm ownership: release=$rel namespace=$ns"
  else
    log_error "Kafka CR ownership annotation is '$rel' (expected '$HELM_RELEASE')"
    log_error "helm upgrade will refuse to adopt it. Restore with:"
    log_error "  kubectl -n $NAMESPACE annotate kafka $KAFKA_CR_NAME --overwrite \\"
    log_error "    meta.helm.sh/release-name=$HELM_RELEASE meta.helm.sh/release-namespace=$HELM_NAMESPACE"
    problems=$((problems+1))
  fi
  local pool rel_p
  for pool in $(kq get kafkanodepools -o json 2>/dev/null | jq -r '.items[]?.metadata.name'); do
    rel_p=$(kq get kafkanodepool "$pool" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' || true)
    [[ $rel_p == "$HELM_RELEASE" ]] || {
      log_warn "KafkaNodePool '$pool' ownership annotation is '${rel_p:-missing}'"
      problems=$((problems+1))
    }
  done

  # 2. The stored release manifest must not reference v1beta2, or helm upgrade fails while
  #    building objects from the PREVIOUS revision - the original error in this saga.
  local dep8
  dep8=$(release_secrets deployed | tail -1)
  if [[ -n $dep8 ]]; then
    local n
    n=$(stored_v1beta2_count "$dep8")
    case $n in
      0) log_ok "stored release manifest ($dep8) is free of v1beta2 references";;
      unknown)
        log_warn "could not decode release secret $dep8 - verify manually before upgrading"
        problems=$((problems+1));;
      *)
        log_error "the stored release manifest still has $n v1beta2 reference(s)"
        log_error "helm upgrade will fail with 'no matches for kind Kafka in version .../v1beta2'"
        log_error "run: $SCRIPT_NAME --ns $NAMESPACE --repair-helm-release"
        problems=$((problems+1));;
    esac
  fi

  # 3. The chart you are about to apply must describe THIS cluster. A fresh-install chart can
  #    differ in node pool names, storage size, or listeners - helm upgrade would then roll or
  #    rebuild rather than reconcile.
  log_warn "before running helm upgrade, diff the chart against the live cluster:"
  log_warn "  helm template $HELM_RELEASE <chart> -n $HELM_NAMESPACE -f <values> \\"
  log_warn "    | grep -E 'kind: (Kafka|KafkaNodePool)' -A40 > /tmp/rendered.yaml"
  log_warn "  kubectl -n $NAMESPACE get kafka,kafkanodepools -o yaml > /tmp/live.yaml"
  log_warn "Check node pool NAMES, storage size/class and listener config match. A"
  log_warn "fresh-install chart that names its pools differently will create new pools and"
  log_warn "orphan the existing ones - along with their data."
  log_info "current pools: $(kq get kafkanodepools -o json 2>/dev/null | jq -r '[.items[]?.metadata.name]|join(", ")')"
  log_info "current storage: $(kq get kafkanodepools -o json 2>/dev/null | jq -c '[.items[]?|{(.metadata.name): .spec.storage}]')"

  (( problems == 0 )) && log_ok "no blockers found for the follow-up helm upgrade"
  return 0
}

# ========================================================================================
# Validation
# ========================================================================================
validate() {
  banner "PHASE 8 - validation"
  log_info "operator image   : $(operator_running_image)"
  log_info "operator reported: $(kafka_get '{.status.operatorLastSuccessfulVersion}')"
  log_info "kafkas served    : $(crd_served)"
  log_info "kafkas stored    : $(crd_stored)"
  log_info "kafka version    : $(kafka_get '{.spec.kafka.version}')"
  log_info "metadataVersion  : $(kafka_get '{.spec.kafka.metadataVersion}') (status: $(kafka_get '{.status.kafkaMetadataVersion}'))"
  log_info "Ready            : $(kafka_get '{.status.conditions[?(@.type=="Ready")].status}')"
  echo >&2; k get kafka,kafkanodepools >&2 || true
  echo >&2; k get pods -o wide >&2 || true
  echo >&2; kubectl api-resources --api-group=kafka.strimzi.io >&2 || true

  local warns
  warns=$(kafka_get '{range .status.conditions[?(@.type=="Warning")]}{.message}{"\n"}{end}' || true)
  grep -q '[^[:space:]]' <<<"$warns" && { log_warn "remaining warning conditions:"; sed 's/^/    /' <<<"$warns" >&2; }

  check_helm_upgrade_readiness

  $DRY_RUN && { log_warn "dry run: skipping final assertions"; return 0; }
  local ok=true
  [[ $(kafka_get '{.spec.kafka.version}') == "$FINAL_KAFKA_VERSION" ]] || { log_error "kafka version is not $FINAL_KAFKA_VERSION"; ok=false; }
  [[ $(kafka_get '{.status.conditions[?(@.type=="Ready")].status}') == True ]] || { log_error "Kafka is not Ready"; ok=false; }
  [[ $(operator_running_image) == *:$FINAL_OPERATOR_VERSION ]] || { log_error "operator is not $FINAL_OPERATOR_VERSION"; ok=false; }
  [[ $(crd_stored) != *v1beta2* ]] || { log_error "CRD still stores v1beta2"; ok=false; }
  $ok || die "validation failed"
  log_ok "validation passed"
}

# ========================================================================================
# Phases
# ========================================================================================
phase2_align_kafka() {
  banner "PHASE 2 - align the Kafka version before the operator hop"
  local hop_support src_support target
  hop_support=$(op_kafka_support "$CONVERSION_HOP_VERSION")
  src_support=$(op_kafka_support "$SRC_OPERATOR_VERSION")
  CUR_KAFKA_VERSION=$(kafka_get '{.spec.kafka.version}' || echo "$CUR_KAFKA_VERSION")

  if in_list "$CUR_KAFKA_VERSION" "$hop_support"; then
    log_ok "Kafka $CUR_KAFKA_VERSION is already supported by $CONVERSION_HOP_VERSION ($hop_support) - nothing to align"
    return 0
  fi
  target=$(highest_common "$src_support" "$hop_support")
  [[ -n $target ]] || die "no Kafka version common to $SRC_OPERATOR_VERSION ($src_support) and $CONVERSION_HOP_VERSION ($hop_support); an extra operator hop is needed"
  log_info "Kafka $CUR_KAFKA_VERSION is unsupported by $CONVERSION_HOP_VERSION; bumping to $target first"
  upgrade_kafka "$target" "$SRC_OPERATOR_VERSION"
}

phase3_operator_hop() {
  banner "PHASE 3 - cluster operator -> $CONVERSION_HOP_VERSION (serves v1beta2 + v1)"
  # Operator first, CRDs second, per the Strimzi upgrade procedure.
  upgrade_operator "$CONVERSION_HOP_VERSION"
  apply_crds "$CONVERSION_HOP_VERSION"
  wait_for_kafka_ready "operator $CONVERSION_HOP_VERSION"
}

phase4_kafka_bridge_version() {
  banner "PHASE 4 - Kafka -> 4.2.0"
  log_info "4.2.0 is the only version common to $CONVERSION_HOP_VERSION and $FINAL_OPERATOR_VERSION"
  $DRY_RUN || require_operator_version "$CONVERSION_HOP_VERSION" "phase 4"
  upgrade_kafka 4.2.0 "$CONVERSION_HOP_VERSION"
}

phase6_final_operator() {
  banner "PHASE 6 - cluster operator -> $FINAL_OPERATOR_VERSION (v1 only)"
  local stored kver
  stored=$(crd_stored)
  if [[ $stored == *v1beta2* ]]; then
    if $DRY_RUN; then log_warn "dry run: stored versions still include v1beta2 ($stored); phase 5 handles this"
    else die "CRD stored versions still include v1beta2 ($stored) - phase 5 must complete first"; fi
  fi
  kver=$(kafka_get '{.spec.kafka.version}' || echo "")
  if ! in_list "$kver" "$(op_kafka_support "$FINAL_OPERATOR_VERSION")"; then
    if $DRY_RUN; then
      log_warn "dry run: spec.kafka.version is '$kver'; phase 4 raises it to 4.2.0 before this point"
    else
      die "spec.kafka.version is '$kver'; $FINAL_OPERATOR_VERSION supports only $(op_kafka_support "$FINAL_OPERATOR_VERSION")"
    fi
  fi
  if [[ -n $CHART_DIR && -d $CHART_DIR ]] && grep -rq 'kafka\.strimzi\.io/v1beta2' "$CHART_DIR" 2>/dev/null; then
    log_error "$CHART_DIR still references kafka.strimzi.io/v1beta2"
    $FORCE || die "update your chart templates to kafka.strimzi.io/v1 before this phase"
  fi
  upgrade_operator "$FINAL_OPERATOR_VERSION"
  apply_crds "$FINAL_OPERATOR_VERSION"
  wait_for_kafka_ready "operator $FINAL_OPERATOR_VERSION"
}

phase7_final_kafka() {
  banner "PHASE 7 - Kafka -> $FINAL_KAFKA_VERSION"
  $DRY_RUN || require_operator_version "$FINAL_OPERATOR_VERSION" "phase 7"
  upgrade_kafka "$FINAL_KAFKA_VERSION" "$FINAL_OPERATOR_VERSION"
}

# run_phase N FUNC [VERIFY_FUNC]
# A completed phase is only skipped if the cluster still reflects it. Otherwise the marker is
# discarded and the phase re-runs - which is what you want when something external reverted
# an operator Deployment between runs.
run_phase() {
  local n=$1 fn=$2 verify=${3:-}
  phase_selected "$n" || { log_info "phase $n not selected - skipping"; return 0; }
  # Naming a phase explicitly is a request to run it. Markers exist so that an unqualified
  # re-run resumes; they must not silently turn "--phase 1" into a no-op.
  if [[ -n $PHASES ]] && phase_done "$n"; then
    log_info "phase $n was already marked complete, but you asked for it - running it again"
  elif phase_done "$n"; then
    if [[ -n $verify ]] && ! $DRY_RUN && ! "$verify"; then
      log_warn "phase $n is marked complete but the cluster no longer reflects it"
      log_warn "  (running operator: $(running_operator_version)) - discarding marker, re-running"
      rm -f "$STATE_DIR/phase-$n.done"
    else
      log_info "phase $n already completed - skipping"
      return 0
    fi
  fi
  "$fn"
  mark_phase_done "$n"
}

# ========================================================================================
# Main
# ========================================================================================
main() {
  prepare_workdir

  if $REPAIR_ONLY; then repair_only; exit 0; fi

  banner "Strimzi -> $FINAL_OPERATOR_VERSION / Kafka $FINAL_KAFKA_VERSION"
  cat >&2 <<EOF
  script version  : $SCRIPT_VERSION
  namespace       : $NAMESPACE
  Kafka CR        : $KAFKA_CR_NAME
  operator deploy : $OPERATOR_DEPLOYMENT
  operator mode   : $OPERATOR_MODE
  conversion mode : $CONVERSION_MODE
  workdir         : $WORKDIR
  phases          : ${PHASES:-all}
  dry-run         : $DRY_RUN
EOF

  need_cmd kubectl
  check_state_freshness

  # Phase 1 always runs its detection logic, even when not selected, because later phases
  # depend on SRC_OPERATOR_VERSION / HELM_RELEASE / CUR_KAFKA_VERSION.
  if phase_selected 1 && { [[ -n $PHASES ]] || ! phase_done 1; }; then
    if [[ -n $PHASES ]] && phase_done 1; then
      log_info "phase 1 was already marked complete, but you asked for it - running it again"
    fi
    confirm "Proceed?"
    preflight
    mark_phase_done 1
  else
    log_info "phase 1 skipped - re-running detection only"
    need_cmd kubectl; need_cmd jq
    [[ -n $SRC_OPERATOR_VERSION ]] || SRC_OPERATOR_VERSION=$(detect_src_operator_version)
    op_kafka_support "$SRC_OPERATOR_VERSION" >/dev/null \
      || die "unsupported/undetectable source operator version '$SRC_OPERATOR_VERSION'; pass --src-operator-version"
    CUR_KAFKA_VERSION=$(kafka_get '{.spec.kafka.version}' || echo "")
    detect_helm_owner
    log_info "source operator $SRC_OPERATOR_VERSION, Kafka $CUR_KAFKA_VERSION"
  fi

  run_phase 2 phase2_align_kafka
  run_phase 3 phase3_operator_hop verify_hop_operator
  run_phase 4 phase4_kafka_bridge_version
  run_phase 5 convert_to_v1
  run_phase 6 phase6_final_operator verify_final_operator
  run_phase 7 phase7_final_kafka
  run_phase 8 validate

  # Report what actually happened. Printing a success banner unconditionally made a
  # single-phase run look like a completed migration.
  local n
  local -a outstanding=()
  for n in 1 2 3 4 5 6 7 8; do phase_done "$n" || outstanding+=("$n"); done

  if $DRY_RUN; then
    banner "dry run finished - nothing was changed"
    log_info "re-run without --dry-run to apply"
    return 0
  fi

  if (( ${#outstanding[@]} > 0 )); then
    banner "run finished - migration NOT complete"
    log_warn "phases still outstanding: ${outstanding[*]}"
    log_info "current state: operator $(running_operator_version), Kafka $(kafka_get '{.spec.kafka.version}' || echo unknown)"
    log_info "target:        operator $FINAL_OPERATOR_VERSION, Kafka $FINAL_KAFKA_VERSION"
    log_info "continue with: $SCRIPT_NAME --ns $NAMESPACE --kafka-cr $KAFKA_CR_NAME${HELM_RELEASE:+ --helm-release $HELM_RELEASE --helm-namespace $HELM_NAMESPACE} --yes"
    log_info "state and backups: $WORKDIR"
    return 0
  fi

  banner "migration complete"
  log_ok "operator $FINAL_OPERATOR_VERSION, Kafka $FINAL_KAFKA_VERSION, API kafka.strimzi.io/v1"
  log_info "backups and phase state remain in $WORKDIR"
  if kq get rolebinding "$MIGRATION_RB_NAME" >/dev/null 2>&1; then
    log_warn "this script added rolebinding/$MIGRATION_RB_NAME in $NAMESPACE to work around a"
    log_warn "chart bug (delegation binding subject pointed at the release namespace)."
    log_warn "Delete it once your chart renders a binding whose subject namespace is '$NAMESPACE':"
    log_warn "  kubectl -n $NAMESPACE delete rolebinding $MIGRATION_RB_NAME"
  fi
  if [[ -n $HELM_RELEASE ]]; then
    log_warn "final step for you: make sure the '$HELM_RELEASE' chart renders kafka.strimzi.io/v1 and"
    log_warn "no longer sets spec.kafka.replicas / spec.kafka.storage, then run a normal helm upgrade."
  fi
}

main
