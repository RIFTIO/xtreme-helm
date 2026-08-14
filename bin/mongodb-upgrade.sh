#!/usr/bin/env bash
#
# mongodb-upgrade.sh
#
# Upgrades MongoDB in a Kubernetes namespace by reloading its data:
#
#   dump  ->  stop  ->  erase the data volume  ->  deploy the target  ->  restore
#
# MongoDB refuses to start when its data files are more than one major version
# behind the binary, which normally forces an upgrade through every intervening
# release (5.0 -> 6.0 -> 7.0 -> 8.0), each needing its own image. That check does
# not apply to an EMPTY data directory: the target initialises fresh. Reloading
# the data logically therefore needs only ONE image -- the target -- and skips
# the featureCompatibilityVersion ladder entirely.
#
# The cost: between the erase and the restore, the dump archive is the only copy
# of the data. Nothing here runs without one that has been verified.
#
# The StatefulSet, PersistentVolumeClaim, Service and any sidecars are unchanged,
# so nothing downstream needs repointing.
#
# Usage:  ./mongodb-upgrade.sh -n <namespace> [-t <tag>] [options]
#
set -euo pipefail

# Associative arrays require bash 4.0+. macOS still ships bash 3.2 as /bin/bash,
# which would otherwise fail with an opaque syntax error.
if [[ -z "${BASH_VERSINFO:-}" || "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  printf 'ERROR: bash 4.0 or newer is required (found %s).\n' "${BASH_VERSION:-unknown}" >&2
  printf '       On macOS: brew install bash, then run with the newer bash.\n' >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Configuration
#
# Precedence, highest wins:
#   1. command-line flags
#   2. environment variables  (MONGO_UPGRADE_<KEY>)
#   3. config file            (--config FILE)
#   4. built-in defaults      (below)
# ---------------------------------------------------------------------------

SCRIPT_NAME="$(basename "$0")"

declare -A DEFAULTS=(
  [NAMESPACE]=""
  [TARGET_TAG]="auto"               # auto = newest tag the repository offers
  [STRATEGY]="inplace"              # inplace | reinit
  [HOP_TAGS]=""                     # inplace: explicit tag per major, "6.0=x,7.0=y"
  [IMAGE_REPO]="bitnamilegacy/mongodb"  # where images are pulled from;
                                    # "auto" reuses the running image's repo
  [TAG_SOURCE]=""                   # where to look up tags; defaults to IMAGE_REPO
  [STATEFULSET]=""                  # auto-detected when empty
  [RELEASE]=""                      # auto-detected when empty
  [CONTAINER]=""                    # auto-detected when empty
  [MONGO_PORT]=""                   # auto-detected, else 27017
  [MONGO_USER]="root"
  [PASSWORD_SECRET]=""              # auto-detected when empty
  [PASSWORD_KEY]=""                 # auto-detected when empty
  [NO_AUTH]="false"                 # auto-detected from the pod spec
  [MONGO_SHELL_ARGS]=""             # e.g. --tls
  [MONGO_TOOL_ARGS]=""              # e.g. --ssl
  [WORKDIR]=""                      # auto-timestamped when empty
  [REPORT_JSON]=""                  # defaults to <WORKDIR>/report.json
  [HEALTH_TIMEOUT]="900"
  [PROBE_TIMEOUT]="300"
  [DRY_RUN]="false"
  [NON_INTERACTIVE]="true"
  [ASSUME_YES]="false"
  [SKIP_IMAGE_CHECK]="false"
  [SKIP_PROBE_CHECK]="false"
  [AUTO_FIX_PROBES]="true"          # repair probes that block 6.0+ during the run
  [SKIP_CONFIG_CHECK]="false"       # validate mongod.conf against the target
  [SKIP_INVENTORY]="false"          # proceed even if the inventory check fails
  [AUTO_FIX_CONFIG]="true"          # strip options the target rejects
  [ALLOW_IMAGE_FAMILY_CHANGE]="false"
  [SKIP_BACKUP]="false"             # refusing to back up also refuses the erase
  [ALLOW_IRREVERSIBLE]="false"      # only needed when there is no usable backup
)

declare -A CFG=() FROM_CLI=() FROM_FILE=() ORIGIN=()

CONFIG_FILE=""
CHECK_IMAGE=""
INSPECT_IMAGE=""
LIST_TAGS=0
FIX_PROBES=0
TRY_TAGS=""
PRINT_CONFIG=0
WRITE_CONFIG=""

# Runtime state
ROOT_PW="${MONGODB_ROOT_PASSWORD:-}"
LOG_FILE=""
RUN_STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CURRENT_VERSION=""
TARGET_IMAGE=""
BACKUP_OK=0
BACKUP_PATH=""
MONGO_BIN_PATH=""
MONGO_CONTAINER=""
MONGO_PORT=""
PROBE_REASON=""
PROBE_MESSAGE=""
REGISTRY_AUTH_USED=0
REGISTRY_AUTH_HOSTS=""

# Exit codes -- stable, so pipelines can branch on the reason for failure.
readonly EX_OK=0
readonly EX_GENERAL=1
readonly EX_CONFIG=2        # bad arguments or config file
readonly EX_DISCOVERY=3     # could not find/identify the cluster
readonly EX_PREFLIGHT=4     # unhealthy cluster, missing tools, image unusable
readonly EX_UPGRADE=5       # the upgrade itself failed
readonly EX_VERIFY=6        # post-upgrade verification mismatch
readonly EX_REFUSED=7       # refused for safety

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'
  C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m';    C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_OFF=""
fi

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '%s [%sINFO%s ] %s\n'  "$(_ts)" "$C_BLU" "$C_OFF" "$*" | tee -a "${LOG_FILE:-/dev/null}"; }
ok()   { printf '%s [%s OK %s ] %s\n'  "$(_ts)" "$C_GRN" "$C_OFF" "$*" | tee -a "${LOG_FILE:-/dev/null}"; }
warn() { printf '%s [%sWARN%s ] %s\n'  "$(_ts)" "$C_YEL" "$C_OFF" "$*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }
err()  { printf '%s [%sFAIL%s ] %s\n'  "$(_ts)" "$C_RED" "$C_OFF" "$*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }

banner() {
  printf '\n%s%s%s\n' "$C_BLD" "=========================================================================" "$C_OFF"
  printf '%s  %s%s\n'  "$C_BLD" "$*" "$C_OFF"
  printf '%s%s%s\n\n'  "$C_BLD" "=========================================================================" "$C_OFF"
  [[ -n "${LOG_FILE:-}" ]] && printf '\n=== %s ===\n\n' "$*" >> "$LOG_FILE"
  return 0
}

die()  { err "$*"; finalize_report "failed" "$*"; exit "${EX_GENERAL}"; }
die_code() { local code="$1"; shift; err "$*"; finalize_report "failed" "$*"; exit "$code"; }

is_true()  { case "${1,,}" in true|yes|1|on) return 0 ;; *) return 1 ;; esac; }
is_false() { ! is_true "$1"; }
run() {
  if is_true "${CFG[DRY_RUN]}"; then
    printf '%s  [dry-run] %s%s\n' "$C_YEL" "$*" "$C_OFF"
    return 0
  fi
  log "exec: $*"
  "$@"
}

# Ordinary confirmation. Auto-approves when running unattended.
confirm() {
  local prompt="$1"
  if is_true "${CFG[NON_INTERACTIVE]}" || is_true "${CFG[ASSUME_YES]}"; then
    log "auto-approved: ${prompt}"
    return 0
  fi
  local reply
  printf '\n%s%s%s [yes/no]: ' "$C_YEL" "$prompt" "$C_OFF"
  read -r reply
  [[ "$reply" == "yes" ]] || die_code "$EX_REFUSED" "aborted by operator"
}

# Confirmation for an action that cannot be undone. Unattended runs must opt in
# explicitly via ALLOW_IRREVERSIBLE -- silence is not consent.
confirm_irreversible() {
  local prompt="$1"
  # A dry run changes nothing, so there is nothing to be irreversible about.
  if is_true "${CFG[DRY_RUN]}"; then
    log "would require confirmation for an irreversible step: ${prompt}"
    return 0
  fi

  # Raising the FCV cannot be undone in place -- but it can be recovered from
  # by restoring the pre-upgrade dump. With a verified backup on disk the step
  # is recoverable, so it does not need a separate opt-in.
  if (( BACKUP_OK )) && is_false "${CFG[SKIP_BACKUP]}"; then
    warn "proceeding with an irreversible step: ${prompt}"
    warn "recovery path is the pre-upgrade backup: ${BACKUP_PATH}"
    return 0
  fi

  if is_true "${CFG[NON_INTERACTIVE]}"; then
    if is_true "${CFG[ALLOW_IRREVERSIBLE]}"; then
      warn "unattended approval of an irreversible step: ${prompt}"
      return 0
    fi
    err "This step cannot be undone: ${prompt}"
    err "There is no usable pre-upgrade backup to recover from"
    if is_true "${CFG[SKIP_BACKUP]}"; then
      err "  (--skip-backup was set)"
    else
      err "  (the backup step did not produce an archive)"
    fi
    err "Either allow the backup to run, or accept the risk explicitly with"
    err "--allow-irreversible / ALLOW_IRREVERSIBLE=true."
    die_code "$EX_REFUSED" "irreversible step blocked in non-interactive mode"
  fi
  if is_true "${CFG[ASSUME_YES]}"; then
    warn "auto-approved irreversible step (--yes): ${prompt}"
    return 0
  fi
  local reply
  printf '\n%s%s%s\n%sThis cannot be undone.%s Type "yes" to proceed: ' \
    "$C_YEL" "$prompt" "$C_OFF" "$C_RED" "$C_OFF"
  read -r reply
  [[ "$reply" == "yes" ]] || die_code "$EX_REFUSED" "aborted by operator"
}

major_of() { local v="$1"; printf '%s.%s' "${v%%.*}" "$(cut -d. -f2 <<<"$v")"; }
# Parsed line by line against a key whitelist. The file is never sourced --
# an upgrade config should not be able to execute arbitrary shell.
load_config_file() {
  local file="$1" lineno=0 line key val

  [[ -f "$file" ]] || die_code "$EX_CONFIG" "config file not found: ${file}"
  [[ -r "$file" ]] || die_code "$EX_CONFIG" "config file not readable: ${file}"

  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%%#*}"                      # strip comments
    line="${line#"${line%%[![:space:]]*}"}" # ltrim
    line="${line%"${line##*[![:space:]]}"}" # rtrim
    [[ -z "$line" ]] && continue

    if [[ "$line" != *=* ]]; then
      die_code "$EX_CONFIG" "${file}:${lineno}: expected KEY=VALUE, got: ${line}"
    fi

    key="${line%%=*}"; val="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    val="${val#"${val%%[![:space:]]*}"}"
    key="${key^^}"

    # strip one layer of matching quotes
    if [[ "$val" == \"*\" && ${#val} -ge 2 ]]; then val="${val:1:${#val}-2}"
    elif [[ "$val" == \'*\' && ${#val} -ge 2 ]]; then val="${val:1:${#val}-2}"; fi

    if [[ -z "${DEFAULTS[$key]+isset}" ]]; then
      die_code "$EX_CONFIG" "${file}:${lineno}: unknown config key '${key}' (see --write-config for the valid set)"
    fi

    FROM_FILE["$key"]="$val"
  done < "$file"

  ok "loaded config file: ${file} (${#FROM_FILE[@]} key(s))"
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die_code "$EX_PREFLIGHT" "required command not found: $1"; }
check_prereqs() {
  need_cmd kubectl
  need_cmd jq
  is_true "${CFG[DRY_RUN]}" || need_cmd helm
  kubectl get ns "${CFG[NAMESPACE]}" >/dev/null 2>&1 || die_code "$EX_DISCOVERY" "namespace '${CFG[NAMESPACE]}' not found or not accessible"
  ok "prerequisites present; namespace '${CFG[NAMESPACE]}' reachable"
}

discover_statefulset() {
  if [[ -n "${CFG[STATEFULSET]}" ]]; then
    kubectl -n "${CFG[NAMESPACE]}" get sts "${CFG[STATEFULSET]}" >/dev/null 2>&1 \
      || die_code "$EX_DISCOVERY" "StatefulSet '${CFG[STATEFULSET]}' not found in namespace '${CFG[NAMESPACE]}'"
    return 0
  fi

  local candidates
  candidates="$(kubectl -n "${CFG[NAMESPACE]}" get sts -o json \
    | jq -r '.items[]
             | select((.spec.template.spec.containers[].image // "") | test("mongo"; "i"))
             | .metadata.name' | sort -u)"

  local count
  count="$(grep -c . <<<"$candidates" || true)"

  if [[ "$count" -eq 0 ]]; then
    die_code "$EX_DISCOVERY" "no MongoDB StatefulSet found in namespace '${CFG[NAMESPACE]}'. Pass --statefulset explicitly."
  elif [[ "$count" -gt 1 ]]; then
    err "multiple MongoDB StatefulSets found in '${CFG[NAMESPACE]}':"
    sed 's/^/    /' <<<"$candidates" >&2
    die_code "$EX_DISCOVERY" "disambiguate with --statefulset"
  fi

  CFG[STATEFULSET]="$candidates"
  ok "discovered StatefulSet: ${CFG[STATEFULSET]}"
}

discover_release() {
  [[ -n "${CFG[RELEASE]}" ]] && return 0
  CFG[RELEASE]="$(kubectl -n "${CFG[NAMESPACE]}" get sts "${CFG[STATEFULSET]}" \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/instance}' 2>/dev/null || true)"
  [[ -n "${CFG[RELEASE]}" ]] || CFG[RELEASE]="${CFG[STATEFULSET]}"
  ok "Helm release: ${CFG[RELEASE]}"
}

detect_sharding() {
  local mongos
  mongos="$(kubectl -n "${CFG[NAMESPACE]}" get pods -o json \
    | jq -r '[.items[] | select(.metadata.name | test("mongos|configsvr|shard[0-9]"))] | length')"
  if [[ "$mongos" -gt 0 ]]; then
    err "this namespace appears to contain a sharded cluster (found ${mongos} mongos/config/shard pods)."
    err "Sharded upgrades require balancer control and per-component ordering that this script"
    err "does not implement. Follow the MongoDB sharded cluster upgrade procedure manually."
    die_code "$EX_REFUSED" "refusing to proceed on a sharded cluster"
  fi
  ok "topology check: not a sharded cluster"
}

# Reads the StatefulSet pod spec -- the authoritative record of what the
# running MongoDB is actually configured with. Far more reliable than guessing
# secret names, and it works with auth.existingSecret, which the chart's own
# secret.yaml deliberately does not render.
sts_json() {
  kubectl -n "${CFG[NAMESPACE]}" get sts "${CFG[STATEFULSET]}" -o json 2>/dev/null || true
}

# Value of a plain (non-secret) env var on any container in the pod spec.
sts_env_value() {
  local var="$1"
  sts_json | jq -r --arg v "$var" '
    [ (.spec.template.spec.containers // [])[],
      (.spec.template.spec.initContainers // [])[] ]
    | map(.env // [] | .[] | select(.name == $v) | .value // empty)
    | flatten | map(select(. != "")) | first // empty' 2>/dev/null || true
}

# secretKeyRef name/key backing an env var, e.g. MONGODB_ROOT_PASSWORD.
sts_env_secret_ref() {
  local var="$1" field="$2"
  sts_json | jq -r --arg v "$var" --arg f "$field" '
    [ (.spec.template.spec.containers // [])[],
      (.spec.template.spec.initContainers // [])[] ]
    | map(.env // [] | .[] | select(.name == $v) | .valueFrom.secretKeyRef // empty)
    | flatten | map(.[$f] // empty) | map(select(. != "")) | first // empty' 2>/dev/null || true
}

# Secrets pulled in wholesale via envFrom.
sts_envfrom_secrets() {
  sts_json | jq -r '
    [ (.spec.template.spec.containers // [])[],
      (.spec.template.spec.initContainers // [])[] ]
    | map(.envFrom // [] | .[] | .secretRef.name // empty)
    | flatten | map(select(. != "")) | unique | .[]' 2>/dev/null || true
}

# Secrets mounted as volumes -- some charts deliver credentials this way.
sts_volume_secrets() {
  sts_json | jq -r '
    (.spec.template.spec.volumes // [])
    | map(.secret.secretName // empty) | map(select(. != "")) | unique | .[]' 2>/dev/null || true
}

# The StatefulSet's own selector -- the only reliable way to find its pods.
# The Helm release label is useless on an umbrella chart, where every subchart
# shares app.kubernetes.io/instance.
sts_pod_selector() {
  sts_json | jq -r '
    (.spec.selector.matchLabels // {})
    | to_entries | map("\(.key)=\(.value)") | join(",")' 2>/dev/null || true
}

sts_pods() {
  local sel pods=""
  sel="$(sts_pod_selector)"

  if [[ -n "${sel//[[:space:]]/}" ]]; then
    pods="$(kubectl -n "${CFG[NAMESPACE]}" get pods -l "$sel" \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  fi

  # Fallback: StatefulSet pods are always <sts-name>-<ordinal>.
  if [[ -z "${pods//[[:space:]]/}" ]]; then
    pods="$(kubectl -n "${CFG[NAMESPACE]}" get pods \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
            | grep -E "^${CFG[STATEFULSET]}-[0-9]+$" || true)"
  fi

  printf '%s\n' "$pods" | grep -v '^$' | sort -V || true
}

# Previous images for this StatefulSet, newest revision last. ControllerRevisions
# retain the full pod template, so a broken rollout can be traced back to a
# known-good image without guessing.
sts_previous_images() {
  kubectl -n "${CFG[NAMESPACE]}" get controllerrevision -o json 2>/dev/null \
    | jq -r --arg sts "${CFG[STATEFULSET]}" --arg c "${MONGO_CONTAINER:-mongodb}" '
        [ .items[]? | select((.metadata.ownerReferences // [])[]?.name == $sts) ]
        | sort_by(.revision)
        | .[]
        | "\(.revision)\t\(((.data.spec.template.spec.containers // [])[]
              | select(.name == $c) | .image) // "")"' 2>/dev/null || true
}

# The volumeClaimTemplate name, its mount path, and the PVCs derived from it.
sts_volume_claim_name() {
  sts_json | jq -r '(.spec.volumeClaimTemplates // [])[0].metadata.name // empty' 2>/dev/null || true
}

sts_data_mount_path() {
  local vct="$1"
  sts_json | jq -r --arg c "${MONGO_CONTAINER:-mongodb}" --arg v "$vct" '
    [ (.spec.template.spec.containers // [])[]
      | select(.name == $c)
      | (.volumeMounts // [])[]
      | select(.name == $v) | .mountPath ] | first // empty' 2>/dev/null || true
}

sts_replica_count() {
  sts_json | jq -r '.spec.replicas // 1' 2>/dev/null || echo 1
}

sts_pvc_names() {
  local vct="$1" n i
  [[ -n "$vct" ]] || return 1
  n="$(sts_replica_count)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=1
  for (( i = 0; i < n; i++ )); do
    printf '%s-%s-%s\n' "$vct" "${CFG[STATEFULSET]}" "$i"
  done
}

# Strip the tag or digest from an image reference, leaving the repository.
# Handles registries with a port, e.g. registry.local:5000/team/mongodb:1.2.
strip_image_tag() {
  local ref="$1"
  ref="${ref%@sha256:*}"
  local last="${ref##*/}"
  if [[ "$last" == *:* ]]; then printf '%s' "${ref%:*}"; else printf '%s' "$ref"; fi
}

# The org/project segment of an image reference, ignoring the registry host.
#   docker.io/dzscloudadmin/mongodb:1  -> dzscloudadmin
#   dzscloudadmin/rw-replicator:2.7    -> dzscloudadmin
#   harbor.local/team/mongodb:1        -> team
image_org() {
  local ref; ref="$(strip_image_tag "$1")"
  local first="${ref%%/*}"
  # Drop a leading registry host (contains a dot or a port).
  if [[ "$ref" == */* ]] && [[ "$first" == *.* || "$first" == *:* ]]; then
    ref="${ref#*/}"
  fi
  if [[ "$ref" == */* ]]; then printf '%s' "${ref%%/*}"; else printf '%s' "$ref"; fi
}

# The image currently on the MongoDB container.
current_container_image() {
  sts_json | jq -r --arg c "${MONGO_CONTAINER:-}" '
    [ (.spec.template.spec.containers // [])[]
      | select(($c == "") or (.name == $c)) | .image ] | first // empty' 2>/dev/null || true
}

# Never invent a repository. Whatever is running is, by definition, pullable
# from this cluster; a hand-written default may not be.
detect_image_repo() {
  local cur repo
  cur="$(current_container_image)"

  if [[ "${CFG[IMAGE_REPO]}" != "auto" ]]; then
    log "image repository : ${CFG[IMAGE_REPO]} (${ORIGIN[IMAGE_REPO]})"
    if [[ -n "$cur" ]]; then
      repo="$(strip_image_tag "$cur")"
      if [[ "$repo" != "${CFG[IMAGE_REPO]}" ]]; then
        if [[ "${ORIGIN[IMAGE_REPO]}" == "default" ]]; then
          log "running image comes from '${repo}'; images will be pulled from"
          log "'${CFG[IMAGE_REPO]}' (pass --image-repo auto to keep the current repository)"
        else
          warn "the running image uses repository '${repo}', not '${CFG[IMAGE_REPO]}'"
          warn "if '${CFG[IMAGE_REPO]}' is not pullable here the rollout will fail to start"
        fi
      fi
    fi
    return 0
  fi

  if [[ -z "$cur" ]]; then
    die_code "$EX_DISCOVERY" "could not read the current container image; pass --image-repo explicitly"
  fi

  CFG[IMAGE_REPO]="$(strip_image_tag "$cur")"
  ORIGIN[IMAGE_REPO]="auto-detected"
  log "image repository : ${CFG[IMAGE_REPO]} (from the running image)"
  log "current image    : ${cur}"
}

# MongoDB images come in incompatible families. Bitnami-derived images keep
# data under /bitnami/mongodb/data/db and run as UID 1001; the official image
# uses /data/db and UID 999, and ignores Bitnami's env vars. Swapping family
# mid-upgrade starts mongod against what looks like an empty data directory.
# $2 = "runtime" to allow the on-disk layout of the RUNNING container to
# inform the answer. That hint describes what is deployed now, so it must not
# be applied when classifying some other repository.
image_family() {
  local ref="$1" hint="${2:-}"

  # Direct evidence from the running container outranks the repository name.
  # A mirror may expose Bitnami images under a path called "mongo", and the
  # on-disk layout is what actually determines compatibility.
  if [[ "$hint" == "runtime" ]]; then
    case "${MONGO_BIN_PATH:-}" in
      /opt/bitnami/*) printf 'bitnami'; return 0 ;;
      /usr/bin/*|/usr/local/bin/*) printf 'official'; return 0 ;;
    esac
  fi

  case "$ref" in
    *bitnami*) printf 'bitnami'; return 0 ;;
  esac
  case "$ref" in
    */mongodb-community-server*|mongo|*/mongo)
      printf 'official'; return 0 ;;
  esac
  printf 'unknown'
}

# A registry mirror prefix, e.g. rt.cloud.dzsi.local/docker-hub, derived from
# the image already running. Clusters behind a pull-through proxy cannot reach
# docker.io directly, so a public repository must be addressed through it.
mirror_prefix_from() {
  local repo="$1" host rest first
  host="${repo%%/*}"
  [[ "$repo" == */* ]] || return 1
  # A registry host has a dot or a port; otherwise this is a Docker Hub org.
  [[ "$host" == *.* || "$host" == *:* ]] || return 1
  rest="${repo#*/}"
  [[ "$rest" == */* ]] || return 1          # host/repo has no proxy prefix
  first="${rest%%/*}"
  printf '%s/%s' "$host" "$first"
}

# Public repositories that mirror each family.
public_repo_for_family() {
  case "$1" in
    bitnami)  printf 'bitnamilegacy/mongodb' ;;
    official) printf 'mongo' ;;
    *)        printf '' ;;
  esac
}

pod_containers() {
  kubectl -n "${CFG[NAMESPACE]}" get pod "$1" -o json 2>/dev/null \
    | jq -r '.spec.containers[]? | "\(.name)\t\(.image)"' 2>/dev/null || true
}

# Orgs used by the other containers in this pod. Those images demonstrably pull
# in this cluster, so a historical MongoDB image from the same org is far more
# likely to be the real one than a repository that has already failed.
sibling_orgs() {
  local pod="$1" c="${MONGO_CONTAINER:-mongodb}"
  pod_containers "$pod" | awk -F'\t' -v c="$c" '$1 != c && $2 != "" {print $2}' \
    | while read -r img; do
        if [[ -n "$img" ]]; then image_org "$img"; printf '\n'; fi
      done | grep -v '^$' | sort -u || true
}

resolve_mongo_container() {
  local pod="$1" rows picked
  [[ -n "$MONGO_CONTAINER" ]] && return 0

  if [[ -n "${CFG[CONTAINER]}" ]]; then
    MONGO_CONTAINER="${CFG[CONTAINER]}"
    return 0
  fi

  rows="$(pod_containers "$pod")"
  [[ -n "${rows//[[:space:]]/}" ]] || { MONGO_CONTAINER=""; return 0; }

  # Prefer a container whose name looks like mongo, then whose image does,
  # explicitly skipping well-known sidecars.
  picked="$(printf '%s\n' "$rows" | grep -viE 'istio-proxy|linkerd-proxy|envoy|exporter|metrics|vault-agent' \
            | awk -F'\t' '$1 ~ /mongo/ {print $1; exit}')"
  [[ -z "$picked" ]] && picked="$(printf '%s\n' "$rows" \
            | grep -viE 'istio-proxy|linkerd-proxy|envoy|exporter|metrics|vault-agent' \
            | awk -F'\t' '$2 ~ /mongo/ {print $1; exit}')"
  [[ -z "$picked" ]] && picked="$(printf '%s\n' "$rows" | awk -F'\t' 'NR==1{print $1}')"

  MONGO_CONTAINER="$picked"
  local total; total="$(printf '%s\n' "$rows" | grep -c . || true)"
  if [[ "${total:-1}" -gt 1 ]]; then
    log "pod has ${total} containers; using '${MONGO_CONTAINER}' for MongoDB commands"
  fi
}

# Emits the -c flag only when a container was resolved, so single-container
# pods keep working unchanged.
kexec() {
  local pod="$1"; shift
  if [[ -n "$MONGO_CONTAINER" ]]; then
    kubectl -n "${CFG[NAMESPACE]}" exec -i "$pod" -c "$MONGO_CONTAINER" -- "$@"
  else
    kubectl -n "${CFG[NAMESPACE]}" exec -i "$pod" -- "$@"
  fi
}

MONGO_LOCATE='
_locate() {
  for _b in $1; do
    command -v "$_b" 2>/dev/null && return 0
  done
  for _d in /opt/bitnami/mongodb/bin /usr/local/bin /usr/bin /bin /opt/mongodb/bin /opt/mongo/bin; do
    for _b in $1; do
      if [ -x "$_d/$_b" ]; then echo "$_d/$_b"; return 0; fi
    done
  done
  return 1
}
'

# The shell binary is resolved inside the pod on every call rather than cached.
# After a hop from 5.0 to 6.0 the legacy 'mongo' binary is gone and only
# 'mongosh' exists; a cached name would silently break every later health check.
# MEXTRA is intentionally left unquoted inside the pod so multiple flags
# word-split correctly (e.g. --tls --tlsCAFile=/certs/ca.crt).
mongo_eval() {
  local pod="$1" js="$2"
  if is_true "${CFG[NO_AUTH]}"; then
    kexec "$pod" env MEVAL="$js" MEXTRA="${CFG[MONGO_SHELL_ARGS]}" MLOC="$MONGO_LOCATE" \
      MPORT="${MONGO_PORT:-27017}" \
      sh -c 'eval "$MLOC"; MBIN="$(_locate "mongosh mongo")" || { echo NO_MONGO_SHELL >&2; exit 127; }
             # shellcheck disable=SC2086
             "$MBIN" --quiet --host 127.0.0.1 --port "$MPORT" $MEXTRA --eval "$MEVAL"' 2>/dev/null
    return
  fi
  kexec "$pod" env MEVAL="$js" MUSER="${CFG[MONGO_USER]}" MPASS="$ROOT_PW" \
      MEXTRA="${CFG[MONGO_SHELL_ARGS]}" MLOC="$MONGO_LOCATE" \
      MPORT="${MONGO_PORT:-27017}" \
      sh -c 'eval "$MLOC"; MBIN="$(_locate "mongosh mongo")" || { echo NO_MONGO_SHELL >&2; exit 127; }
             # shellcheck disable=SC2086
             "$MBIN" --quiet --host 127.0.0.1 --port "$MPORT" -u "$MUSER" -p "$MPASS" \
                     --authenticationDatabase admin $MEXTRA --eval "$MEVAL"' 2>/dev/null
}

# Connection string for mongodump/mongorestore, with or without credentials.
mongo_uri() {
  local host="$1"
  if is_true "${CFG[NO_AUTH]}"; then
    printf 'mongodb://%s:%s/?directConnection=true' "$host" "${MONGO_PORT:-27017}"
  else
    printf 'mongodb://%s:%s@%s:%s/?authSource=admin&directConnection=true' \
      "${CFG[MONGO_USER]}" "${ROOT_PW}" "$host" "${MONGO_PORT:-27017}"
  fi
}

# Same as mongo_eval but keeps stderr, so a failing script can be reported
# rather than silently producing nothing.
mongo_eval_err() {
  local pod="$1" js="$2" errfile="$3"
  if is_true "${CFG[NO_AUTH]}"; then
    kexec "$pod" env MEVAL="$js" MEXTRA="${CFG[MONGO_SHELL_ARGS]}" MLOC="$MONGO_LOCATE" \
        MPORT="${MONGO_PORT:-27017}" \
        sh -c 'eval "$MLOC"; MBIN="$(_locate "mongosh mongo")" || exit 127
               # shellcheck disable=SC2086
               "$MBIN" --quiet --host 127.0.0.1 --port "$MPORT" $MEXTRA --eval "$MEVAL"' 2>"$errfile"
    return
  fi
  kexec "$pod" env MEVAL="$js" MUSER="${CFG[MONGO_USER]}" MPASS="$ROOT_PW" \
      MEXTRA="${CFG[MONGO_SHELL_ARGS]}" MLOC="$MONGO_LOCATE" MPORT="${MONGO_PORT:-27017}" \
      sh -c 'eval "$MLOC"; MBIN="$(_locate "mongosh mongo")" || exit 127
             # shellcheck disable=SC2086
             "$MBIN" --quiet --host 127.0.0.1 --port "$MPORT" -u "$MUSER" -p "$MPASS" \
                     --authenticationDatabase admin $MEXTRA --eval "$MEVAL"' 2>"$errfile"
}

mongo_eval_strict() {
  local out
  out="$(mongo_eval "$@")" || die "mongo command failed on pod $1"
  printf '%s' "$out"
}

get_running_version() {
  local pod="$1" v
  v="$(mongo_eval_strict "$pod" 'db.version()' | tr -d '"[:space:]')"
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || die "could not parse server version, got: '${v}'"
  printf '%s' "$v"
}

get_fcv() {
  local pod="$1" v
  v="$(mongo_eval "$pod" \
      'JSON.stringify(db.adminCommand({getParameter:1,featureCompatibilityVersion:1}))' \
      | jq -r '.featureCompatibilityVersion.version // empty' 2>/dev/null || true)"
  printf '%s' "$v"
}

# Probes that a usable shell exists in the pod and reports which one.
# mongo_eval resolves the binary itself on every call, so nothing is cached.
detect_shell_bin() {
  local pod="$1" found
  resolve_mongo_container "$pod"
  preflight_container_running "$pod"

  found="$(kexec "$pod" env MLOC="$MONGO_LOCATE" \
            sh -c 'eval "$MLOC"; _locate "mongosh mongo"' 2>/dev/null || true)"

  if [[ -n "${found//[[:space:]]/}" ]]; then
    MONGO_BIN_PATH="$found"
    ok "using '${found}' in container '${MONGO_CONTAINER:-<default>}'"
    return 0
  fi

  err "no mongosh or mongo executable found in pod '${pod}'"
  err "container tried: ${MONGO_CONTAINER:-<default, first in pod>}"
  err ""
  local rows; rows="$(pod_containers "$pod")"
  if [[ -n "${rows//[[:space:]]/}" ]]; then
    err "Containers in this pod (name / image):"
    printf '%s\n' "$rows" | sed 's/^/           /' >&2
    err ""
    err "If MongoDB lives in a different container, name it:"
    err "    --container <name>"
  fi
  err ""
  err "PATH inside the container:"
  kexec "$pod" sh -c 'echo "$PATH"' 2>/dev/null | sed 's/^/           /' >&2 || true
  err ""
  err "Searched: PATH, plus /opt/bitnami/mongodb/bin /usr/local/bin /usr/bin"
  err "          /bin /opt/mongodb/bin /opt/mongo/bin"
  err "Check what the image actually ships:"
  err "    kubectl -n ${CFG[NAMESPACE]} exec ${pod} -c ${MONGO_CONTAINER:-<container>} -- ls /opt/bitnami/mongodb/bin"
  die_code "$EX_PREFLIGHT" "no MongoDB shell available in pod ${pod}"
}

# The MongoDB container must actually be running before anything else is worth
# attempting. Reporting "no mongosh found" for a container that never started
# describes a symptom rather than the cause.
preflight_container_running() {
  local pod="$1" json state reason message ready

  json="$(kubectl -n "${CFG[NAMESPACE]}" get pod "$pod" -o json 2>/dev/null || true)"
  [[ -n "${json//[[:space:]]/}" ]] || return 0

  ready="$(printf '%s' "$json" | jq -r --arg c "${MONGO_CONTAINER:-mongodb}" '
      [ (.status.containerStatuses // [])[] | select(.name == $c) | .ready ] | first // empty' 2>/dev/null || true)"
  [[ "$ready" == "true" ]] && return 0

  reason="$(printf '%s' "$json" | jq -r --arg c "${MONGO_CONTAINER:-mongodb}" '
      [ (.status.containerStatuses // [])[] | select(.name == $c)
        | (.state.waiting.reason // .state.terminated.reason // empty) ] | first // empty' 2>/dev/null || true)"
  message="$(printf '%s' "$json" | jq -r --arg c "${MONGO_CONTAINER:-mongodb}" '
      [ (.status.containerStatuses // [])[] | select(.name == $c)
        | (.state.waiting.message // .state.terminated.message // empty) ] | first // empty' 2>/dev/null || true)"
  state="$(printf '%s' "$json" | jq -r --arg c "${MONGO_CONTAINER:-mongodb}" '
      [ (.status.containerStatuses // [])[] | select(.name == $c) | .image ] | first // empty' 2>/dev/null || true)"

  err "the MongoDB container is not running in pod '${pod}'"
  err "  container : ${MONGO_CONTAINER:-mongodb}"
  err "  image     : ${state:-unknown}"
  err "  state     : ${reason:-not ready}"
  [[ -n "$message" ]] && err "  detail    : ${message}"
  err ""

  case "$reason" in
    ImagePullBackOff|ErrImagePull|InvalidImageName)
      err "The image cannot be pulled, so MongoDB is down. This must be fixed"
      err "before any upgrade can proceed."
      err ""
      local revs orgs best
      revs="$(sts_previous_images)"
      orgs="$(sibling_orgs "$pod")"

      if [[ -n "${revs//[[:space:]]/}" ]]; then
        err "Images from this StatefulSet's revision history (oldest first):"
        local rev img mark org
        while IFS=$'\t' read -r rev img; do
          if [[ -z "$img" ]]; then continue; fi
          mark=""
          if [[ "$img" == "$state" ]]; then
            mark="   <- currently set, not pullable"
          elif [[ -n "$orgs" ]]; then
            org="$(image_org "$img")"
            if printf '%s\n' "$orgs" | grep -qxF "$org"; then
              mark="   <- same org as the working sidecars"
            fi
          fi
          err "           rev ${rev}  ${img}${mark}"
        done <<<"$revs"

        # Prefer a historical image whose org matches a container that is
        # demonstrably pulling in this cluster.
        if [[ -n "$orgs" ]]; then
          best="$(while IFS=$'\t' read -r _ img; do
                    if [[ -z "$img" || "$img" == "$state" ]]; then continue; fi
                    if printf '%s\n' "$orgs" | grep -qxF "$(image_org "$img")"; then
                      printf '%s\n' "$img"
                    fi
                  done <<<"$revs" | tail -1)" || true
        fi
        [[ -z "${best:-}" ]] && best="$(printf '%s\n' "$revs" \
          | awk -F'\t' -v bad="$state" '$2 != "" && $2 != bad {last=$2} END {print last}')"

        if [[ -n "${best:-}" ]]; then
          err ""
          err "Most likely the working image: ${best}"
        fi
      else
        best=""
        err "No revision history is available for this StatefulSet."
      fi

      err ""
      err "To recover:"
      if [[ -n "${best:-}" ]]; then
        err "    kubectl -n ${CFG[NAMESPACE]} set image statefulset/${CFG[STATEFULSET]} \\"
        err "        ${MONGO_CONTAINER:-mongodb}=${best}"
      else
        err "    kubectl -n ${CFG[NAMESPACE]} rollout undo statefulset/${CFG[STATEFULSET]}"
      fi
      err "    kubectl -n ${CFG[NAMESPACE]} delete pod ${pod}"
      err "    kubectl -n ${CFG[NAMESPACE]} rollout status statefulset/${CFG[STATEFULSET]}"
      err ""
      err "The delete is required, not optional: a StatefulSet rolling update"
      err "stalls on a pod that never becomes Ready, and correcting the spec"
      err "does not replace that pod on its own."
      err ""
      err "Data on the PersistentVolume is untouched -- the container never started."
      die_code "$EX_PREFLIGHT" "MongoDB container is not running (${reason})"
      ;;
    CrashLoopBackOff)
      err "The container is crash-looping. Inspect its logs before upgrading:"
      err "    kubectl -n ${CFG[NAMESPACE]} logs ${pod} -c ${MONGO_CONTAINER:-mongodb} --previous"
      die_code "$EX_PREFLIGHT" "MongoDB container is crash-looping"
      ;;
    *)
      err "Wait for the container to become ready, or inspect it with:"
      err "    kubectl -n ${CFG[NAMESPACE]} describe pod ${pod}"
      die_code "$EX_PREFLIGHT" "MongoDB container is not ready (${reason:-unknown})"
      ;;
  esac
}

primary_pod() {
  local pods p
  pods="$(sts_pods)"
  [[ -n "${pods//[[:space:]]/}" ]] \
    || die_code "$EX_DISCOVERY" "no pods found for StatefulSet '${CFG[STATEFULSET]}' in namespace '${CFG[NAMESPACE]}'"

  # Prefer the actual primary; fall back to the lowest ordinal for standalones.
  while read -r p; do
    [[ -z "$p" ]] && continue
    if mongo_eval "$p" 'db.hello().isWritablePrimary' 2>/dev/null | grep -qi true; then
      printf '%s' "$p"; return 0
    fi
  done <<<"$pods"

  head -1 <<<"$pods"
}

detect_mongo_port() {
  local from_env from_port c="${MONGO_CONTAINER:-}"

  if [[ -n "${CFG[MONGO_PORT]}" ]]; then
    MONGO_PORT="${CFG[MONGO_PORT]}"
    log "MongoDB port     : ${MONGO_PORT} (explicit)"
    return 0
  fi

  from_env="$(sts_env_value MONGODB_PORT_NUMBER)"
  if [[ "$from_env" =~ ^[0-9]+$ ]]; then
    MONGO_PORT="$from_env"
    CFG[MONGO_PORT]="$MONGO_PORT"
    log "MongoDB port     : ${MONGO_PORT} (from MONGODB_PORT_NUMBER)"
    return 0
  fi

  from_port="$(sts_json | jq -r --arg c "$c" '
      [ (.spec.template.spec.containers // [])[]
        | select(($c == "") or (.name == $c))
        | (.ports // [])[]
        | select((.name // "") | test("mongo|db|tcp"; "i") or true)
        | .containerPort ]
      | map(select(. != null)) | first // empty' 2>/dev/null || true)"
  if [[ "$from_port" =~ ^[0-9]+$ ]]; then
    MONGO_PORT="$from_port"
    CFG[MONGO_PORT]="$MONGO_PORT"
    log "MongoDB port     : ${MONGO_PORT} (from containerPort)"
    return 0
  fi

  MONGO_PORT="27017"
  CFG[MONGO_PORT]="$MONGO_PORT"
  log "MongoDB port     : ${MONGO_PORT} (default)"
}

# Lists secret names, distinguishing "none matched" from "cannot list".
# Swallowing the RBAC error here makes a permissions problem look identical to
# a naming problem, which is a miserable thing to debug.
list_secret_names() {
  local out rc
  set +e
  out="$(kubectl -n "${CFG[NAMESPACE]}" get secret -o name 2>&1)"
  rc=$?
  set -e

  if (( rc != 0 )); then
    err "cannot list secrets in namespace '${CFG[NAMESPACE]}':"
    printf '%s\n' "$out" | sed 's/^/         /' >&2
    err ""
    err "If RBAC blocks listing secrets, supply the password directly instead:"
    err "    export MONGODB_ROOT_PASSWORD='...'"
    err "or name the secret explicitly (reading one secret may be permitted"
    err "even when listing them all is not):"
    err "    --password-secret <name> --password-key <key>"
    die_code "$EX_DISCOVERY" "secret discovery failed: cannot list secrets"
  fi

  printf '%s' "$out" | sed 's|^secret/||'
}

secret_keys() {
  kubectl -n "${CFG[NAMESPACE]}" get secret "$1" -o json 2>/dev/null \
    | jq -r '.data // {} | keys[]' 2>/dev/null || true
}

try_secret_key() {
  local secret="$1" key="$2" val
  [[ -n "$secret" && -n "$key" ]] || return 1
  val="$(kubectl -n "${CFG[NAMESPACE]}" get secret "$secret" \
          -o jsonpath="{.data.${key//./\\.}}" 2>/dev/null | base64 -d 2>/dev/null || true)"
  [[ -n "$val" ]] || return 1
  ROOT_PW="$val"
  CFG[PASSWORD_SECRET]="$secret"; CFG[PASSWORD_KEY]="$key"
  return 0
}

resolve_password() {
  if is_true "${CFG[NO_AUTH]}"; then
    ok "authentication disabled (--no-auth); not looking for a password"
    return 0
  fi

  [[ -n "$ROOT_PW" ]] && { ok "admin password taken from environment"; return 0; }

  # --- 1. authoritative: what does the pod spec say? -----------------------
  if [[ -z "${CFG[PASSWORD_SECRET]}" ]]; then
    local spec_secret spec_key allow_empty ef
    spec_secret="$(sts_env_secret_ref MONGODB_ROOT_PASSWORD name)"
    spec_key="$(sts_env_secret_ref MONGODB_ROOT_PASSWORD key)"

    if [[ -n "$spec_secret" ]]; then
      log "StatefulSet references secret '${spec_secret}' key '${spec_key}' for the root password"
      if try_secret_key "$spec_secret" "${spec_key:-mongodb-root-password}"; then
        ok "admin password read from secret '${CFG[PASSWORD_SECRET]}' key '${CFG[PASSWORD_KEY]}' (from pod spec)"
        return 0
      fi
      warn "secret '${spec_secret}' named in the pod spec could not be read"
      warn "(it may live in another namespace, or be unreadable with these permissions)"
    fi

    # envFrom / mounted secrets are the next most reliable signal.
    for ef in $(sts_envfrom_secrets) $(sts_volume_secrets); do
      for k in "${CFG[PASSWORD_KEY]:-}" mongodb-root-password mongo-root-password \
               mongodb-password root-password password MONGODB_ROOT_PASSWORD; do
        [[ -z "$k" ]] && continue
        if try_secret_key "$ef" "$k"; then
          ok "admin password read from secret '${ef}' key '${k}' (referenced by the pod spec)"
          return 0
        fi
      done
    done

    # No root-password reference anywhere plus ALLOW_EMPTY_PASSWORD means the
    # deployment genuinely runs without authentication.
    allow_empty="$(sts_env_value ALLOW_EMPTY_PASSWORD)"
    if [[ -z "$spec_secret" ]] && [[ "${allow_empty,,}" =~ ^(yes|true|1)$ ]]; then
      warn "pod spec sets ALLOW_EMPTY_PASSWORD=${allow_empty} and references no root-password secret"
      warn "treating this deployment as running WITHOUT authentication"
      CFG[NO_AUTH]="true"
      return 0
    fi
  fi

  # --- 2. fall back to searching by name -----------------------------------
  local all candidates s k
  all="$(list_secret_names)"

  if [[ -n "${CFG[PASSWORD_SECRET]}" ]]; then
    candidates="${CFG[PASSWORD_SECRET]}"
    if ! grep -qxF "${CFG[PASSWORD_SECRET]}" <<<"$all"; then
      warn "secret '${CFG[PASSWORD_SECRET]}' was not in the namespace listing; trying it anyway"
    fi
  else
    # Widen beyond the literal string "mongo": the secret is often named after
    # the Helm release or the StatefulSet instead.
    candidates="$(printf '%s\n' "$all" \
      | grep -iE "mongo|^${CFG[RELEASE]}$|^${CFG[RELEASE]}-|^${CFG[STATEFULSET]}$|^${CFG[STATEFULSET]}-" \
      || true)"
  fi

  if [[ -z "${candidates//[[:space:]]/}" ]]; then
    err "no secret in namespace '${CFG[NAMESPACE]}' looks like a MongoDB credential."
    err "Searched for names matching: mongo, ${CFG[RELEASE]}, ${CFG[STATEFULSET]}"
    if [[ -n "${all//[[:space:]]/}" ]]; then
      err "Secrets that do exist here:"
      printf '%s\n' "$all" | sed 's/^/           /' >&2
    else
      err "There are no secrets in this namespace at all."
    fi
    err ""
    err "The chart's secret.yaml is gated on mongodb.createSecret, which skips"
    err "creating a secret when auth.enabled=false OR auth.existingSecret is set."
    err "Check which applies:"
    err "    kubectl -n ${CFG[NAMESPACE]} get sts ${CFG[STATEFULSET]} -o json | jq '.spec.template.spec.containers[].env'"
    err "    helm -n ${CFG[NAMESPACE]} get values ${CFG[RELEASE]} --all | grep -iE 'auth|existingSecret'"
    err ""
    err "If authentication is disabled:"
    err "    --no-auth"
    err ""
    err "Otherwise, name the credential explicitly:"
    err "    --password-secret <name> --password-key <key>"
    err "or set MONGODB_ROOT_PASSWORD in the environment."
    die_code "$EX_DISCOVERY" "could not locate a MongoDB credential secret"
  fi

  local keys=("${CFG[PASSWORD_KEY]:-}" mongodb-root-password mongo-root-password \
              mongodb-passwords mongodb-password root-password password \
              MONGODB_ROOT_PASSWORD)

  while read -r s; do
    [[ -z "$s" ]] && continue
    for k in "${keys[@]}"; do
      [[ -z "$k" ]] && continue
      ROOT_PW="$(kubectl -n "${CFG[NAMESPACE]}" get secret "$s" \
                  -o jsonpath="{.data.${k//./\\.}}" 2>/dev/null \
                  | base64 -d 2>/dev/null || true)"
      if [[ -n "$ROOT_PW" ]]; then
        ok "admin password read from secret '${s}' key '${k}'"
        CFG[PASSWORD_SECRET]="$s"; CFG[PASSWORD_KEY]="$k"
        return 0
      fi
    done
  done <<<"$candidates"

  # Candidate secrets exist but none held a key we recognise. Show what they
  # actually contain so the right --password-key is obvious.
  err "found candidate secret(s), but none contained a recognised password key."
  err "Keys tried: ${keys[*]}"
  err ""
  err "Keys actually present:"
  while read -r s; do
    [[ -z "$s" ]] && continue
    local ks; ks="$(secret_keys "$s")"
    if [[ -n "${ks//[[:space:]]/}" ]]; then
      err "  secret '${s}':"
      printf '%s\n' "$ks" | sed 's/^/             /' >&2
    else
      err "  secret '${s}': (no readable keys)"
    fi
  done <<<"$candidates"
  err ""
  err "Re-run with the correct key, for example:"
  err "    --password-secret <name> --password-key <key>"
  die_code "$EX_DISCOVERY" "could not read an admin password from any candidate secret"
}

# Runs the target image and returns both facts we need: that it pulls, and what
# it actually is. Determining family from the repository name is unreliable --
# a mirror may serve Bitnami images from a path called "mongo", or the official
# image from a path called "mongodb". Only the contents settle it.
PROBE_FAMILY=""
PROBE_DETAIL=""

probe_image_identify() {
  local image="$1" name="$2"
  local manifest logs deadline phase reason

  manifest="$(jq -n --arg name "$name" --arg image "$image" --arg script "$INSPECT_MARKER" \
                --argjson ps "$(sts_json | jq -c '(.spec.template.spec.imagePullSecrets // [])')" \
                --argjson ns "$(sts_json | jq -c '(.spec.template.spec.nodeSelector // {})')" \
                --argjson tol "$(sts_json | jq -c '(.spec.template.spec.tolerations // [])')" '
    { apiVersion: "v1", kind: "Pod",
      metadata: { name: $name, labels: { app: "mongo-image-probe" } },
      spec: (
        { restartPolicy: "Never", terminationGracePeriodSeconds: 0,
          containers: [ { name: "probe", image: $image,
                          command: ["/bin/sh","-c",$script] } ] }
        + (if ($ps|length)  > 0 then { imagePullSecrets: $ps } else {} end)
        + (if ($ns|length)  > 0 then { nodeSelector: $ns }    else {} end)
        + (if ($tol|length) > 0 then { tolerations: $tol }    else {} end)
      )
    }' 2>/dev/null)"
  if [[ -z "${manifest//[[:space:]]/}" ]]; then
    PROBE_REASON="probe-unavailable"; return 2
  fi

  printf '%s' "$manifest" | kubectl -n "${CFG[NAMESPACE]}" apply -f - >/dev/null 2>&1 || true

  local rc=2
  deadline=$(( SECONDS + CFG[PROBE_TIMEOUT] ))
  while (( SECONDS < deadline )); do
    phase="$(kubectl -n "${CFG[NAMESPACE]}" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    reason="$(kubectl -n "${CFG[NAMESPACE]}" get pod "$name" \
              -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
    case "$reason" in
      ErrImagePull|ImagePullBackOff|InvalidImageName|ErrImageNeverPull|ImageInspectError)
        PROBE_MESSAGE="$(kubectl -n "${CFG[NAMESPACE]}" get pod "$name" \
            -o jsonpath='{.status.containerStatuses[0].state.waiting.message}' 2>/dev/null || true)"
        if [[ -z "${PROBE_MESSAGE//[[:space:]]/}" ]] \
           || printf '%s' "$PROBE_MESSAGE" | grep -qiE 'back-?off'; then
          local ev; ev="$(probe_failure_detail "$name")"
          [[ -n "${ev//[[:space:]]/}" ]] && PROBE_MESSAGE="$ev"
        fi
        PROBE_REASON="$reason"; rc=1; break ;;
    esac
    case "$phase" in
      Succeeded|Failed) PROBE_REASON="phase ${phase}"; rc=0; break ;;
    esac
    sleep 3
  done

  if (( rc == 0 )); then
    logs="$(kubectl -n "${CFG[NAMESPACE]}" logs "$name" 2>/dev/null || true)"
    local bin bitnami odata uid
    bin="$(sed -n 's/^MARK_BIN=//p'            <<<"$logs" | head -1)"
    bitnami="$(sed -n 's/^MARK_BITNAMI=//p'    <<<"$logs" | head -1)"
    odata="$(sed -n 's/^MARK_OFFICIAL_DATA=//p'<<<"$logs" | head -1)"
    uid="$(sed -n 's/^MARK_UID=//p'            <<<"$logs" | head -1)"
    if   [[ "$bitnami" == "yes" ]]; then PROBE_FAMILY="bitnami"
    elif [[ "$odata" == "yes" || "$bin" == /usr/bin/* ]]; then PROBE_FAMILY="official"
    else PROBE_FAMILY="unknown"; fi
    PROBE_DETAIL="mongod=${bin:-unknown} /opt/bitnami=${bitnami:-?} /data/db=${odata:-?} uid=${uid:-?}"
  fi

  kubectl -n "${CFG[NAMESPACE]}" delete pod "$name" --wait=false --grace-period=0 >/dev/null 2>&1 || true
  (( rc == 2 )) && PROBE_REASON="inconclusive after ${CFG[PROBE_TIMEOUT]}s (last: ${reason:-${phase:-unknown}})"
  return "$rc"
}

# Confirm each image in the upgrade path can actually be pulled by this cluster,
# before anything is modified. An unpullable tag discovered mid-ladder means
# MongoDB is stopped between major versions.
# Build a probe pod that pulls exactly like the real workload does: same pull
# secrets, service account, node selector and tolerations. Without the pull
# secrets a private image reports as unpullable even when it exists.
probe_pod_manifest() {
  local name="$1" image="$2"
  local pull_secrets sa node_sel tolerations

  pull_secrets="$(sts_json | jq -c '(.spec.template.spec.imagePullSecrets // [])' 2>/dev/null || echo '[]')"
  sa="$(sts_json | jq -r '(.spec.template.spec.serviceAccountName // "")' 2>/dev/null || true)"
  node_sel="$(sts_json | jq -c '(.spec.template.spec.nodeSelector // {})' 2>/dev/null || echo '{}')"
  tolerations="$(sts_json | jq -c '(.spec.template.spec.tolerations // [])' 2>/dev/null || echo '[]')"

  jq -n --arg name "$name" --arg image "$image" --arg sa "$sa" \
        --argjson ps "${pull_secrets:-[]}" --argjson ns "${node_sel:-{\}}" \
        --argjson tol "${tolerations:-[]}" '
    {
      apiVersion: "v1", kind: "Pod",
      metadata: { name: $name, labels: { app: "mongo-image-probe" } },
      spec: (
        { restartPolicy: "Never",
          terminationGracePeriodSeconds: 0,
          containers: [ { name: "probe", image: $image, command: ["/bin/sh","-c","exit 0"] } ]
        }
        + (if ($ps|length)  > 0 then { imagePullSecrets: $ps } else {} end)
        + (if ($ns|length)  > 0 then { nodeSelector: $ns }    else {} end)
        + (if ($tol|length) > 0 then { tolerations: $tol }    else {} end)
        + (if $sa != ""          then { serviceAccountName: $sa } else {} end)
      )
    }' 2>/dev/null
}

# Once a pull has failed a few times the waiting message degrades to
# "Back-off pulling image ...", which says nothing about why. The original
# reason is preserved in the pod's Events, so read those instead.
probe_failure_detail() {
  local name="$1" detail
  detail="$(kubectl -n "${CFG[NAMESPACE]}" get events \
              --field-selector "involvedObject.name=${name}" \
              -o jsonpath='{range .items[*]}{.reason}{"|"}{.message}{"\n"}{end}' 2>/dev/null || true)"
  # Several Failed events are emitted; the useful one is the longest, since
  # the others are generic ("Error: ErrImagePull") or a back-off notice.
  printf '%s\n' "$detail" \
    | grep -i '^Failed|' \
    | grep -viE 'back-?off' \
    | grep -viE '\|Error: (ErrImagePull|ImagePullBackOff)$' \
    | cut -d'|' -f2- \
    | awk '{ print length "\t" $0 }' | sort -rn | head -1 | cut -f2- || true
}

# The authoritative signal is .status.containerStatuses[].imageID, which the
# kubelet populates only once the image has been resolved locally. Waiting
# reasons alone are ambiguous: ContainerCreating covers "still pulling".
probe_image() {
  local image="$1" name="$2"
  local deadline=$(( SECONDS + CFG[PROBE_TIMEOUT] )) manifest
  local phase reason image_id started

  manifest="$(probe_pod_manifest "$name" "$image")"
  if [[ -z "${manifest//[[:space:]]/}" ]]; then
    err "could not build a probe manifest for ${image}"
    err "The image cannot be verified, and an unverified image must not be"
    err "reported as usable. Re-run with --skip-image-check to proceed anyway."
    PROBE_REASON="probe-unavailable"
    return 2
  fi

  printf '%s' "$manifest" | kubectl -n "${CFG[NAMESPACE]}" apply -f - >/dev/null 2>&1 || true

  local rc=2
  while (( SECONDS < deadline )); do
    phase="$(kubectl -n "${CFG[NAMESPACE]}" get pod "$name" \
              -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    reason="$(kubectl -n "${CFG[NAMESPACE]}" get pod "$name" \
              -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
    image_id="$(kubectl -n "${CFG[NAMESPACE]}" get pod "$name" \
              -o jsonpath='{.status.containerStatuses[0].imageID}' 2>/dev/null || true)"
    started="$(kubectl -n "${CFG[NAMESPACE]}" get pod "$name" \
              -o jsonpath='{.status.containerStatuses[0].started}' 2>/dev/null || true)"

    # Definitive failure: the registry refused or the reference is invalid.
    case "$reason" in
      ErrImagePull|ImagePullBackOff|InvalidImageName|ErrImageNeverPull|ImageInspectError|RegistryUnavailable)
        PROBE_MESSAGE="$(kubectl -n "${CFG[NAMESPACE]}" get pod "$name" \
            -o jsonpath='{.status.containerStatuses[0].state.waiting.message}' 2>/dev/null || true)"
        # A back-off message is uninformative; the Events hold the real cause.
        if [[ -z "${PROBE_MESSAGE//[[:space:]]/}" ]] \
           || printf '%s' "$PROBE_MESSAGE" | grep -qiE 'back-?off'; then
          local ev; ev="$(probe_failure_detail "$name")"
          [[ -n "${ev//[[:space:]]/}" ]] && PROBE_MESSAGE="$ev"
        fi
        PROBE_REASON="$reason"; rc=1; break ;;
    esac

    # Definitive success: the image has an ID on this node, or the container ran.
    if [[ -n "${image_id//[[:space:]]/}" ]]; then
      PROBE_REASON="imageID present"; rc=0; break
    fi
    if [[ "$started" == "true" ]]; then
      PROBE_REASON="container started"; rc=0; break
    fi
    case "$phase" in
      Running|Succeeded) PROBE_REASON="phase ${phase}"; rc=0; break ;;
    esac

    # Image present but the container could not be created or run.
    case "$reason" in
      CreateContainerError|CreateContainerConfigError|RunContainerError|StartError|CrashLoopBackOff)
        PROBE_REASON="$reason (image present)"; rc=0; break ;;
    esac

    # ContainerCreating, PodInitializing, Pending, empty: still working. Wait.
    sleep 3
  done

  if (( rc == 2 )); then
    PROBE_REASON="inconclusive after ${CFG[PROBE_TIMEOUT]}s (last: ${reason:-${phase:-unknown}})"
    err "could not determine whether ${image} is pullable within ${CFG[PROBE_TIMEOUT]}s"
    err "last observed state: phase=${phase:-none} reason=${reason:-none}"
    err "recent events for the probe pod:"
    kubectl -n "${CFG[NAMESPACE]}" describe pod "$name" 2>/dev/null \
      | sed -n '/Events:/,$p' | sed 's/^/           /' >&2 || true
    err "Increase the wait with --probe-timeout, or accept the risk with --skip-image-check."
  fi

  kubectl -n "${CFG[NAMESPACE]}" delete pod "$name" --wait=false --grace-period=0 >/dev/null 2>&1 || true
  return "$rc"
}

# The kubelet's message distinguishes the three causes that matter here.
explain_pull_failure() {
  local image="$1" m="${PROBE_MESSAGE,,}"
  err ""
  case "$m" in
    *"manifest unknown"*|*"not found"*|*"manifest for"*)
      err "The registry answered, but has no such tag."
      err "The repository is reachable -- the version string is wrong."
      err "List what actually exists:"
      err "    $SCRIPT_NAME -n ${CFG[NAMESPACE]} --list-tags"
      ;;
    *unauthorized*|*authentication*|*"insufficient_scope"*|*forbidden*|*denied*)
      err "The registry refused the credentials for this repository."
      err "Either the repository is private and the pull secrets do not cover it,"
      err "or it does not exist. The pull secrets used were the StatefulSet's own."
      ;;
    *timeout*|*"no such host"*|*"connection refused"*|*"dial tcp"*|*tls*)
      err "The node could not reach the registry at all."
      err "This is a network or registry-policy problem, not a wrong tag."
      ;;
    *"back-off"*|*"backoff"*|"")
      err "The kubelet only reported a back-off, which hides the original error."
      err "Look at the events on a fresh attempt:"
      err "    kubectl -n ${CFG[NAMESPACE]} run imgtest --restart=Never \\"
      err "        --image=${image} --command -- true"
      err "    kubectl -n ${CFG[NAMESPACE]} describe pod imgtest | sed -n '/Events:/,\$p'"
      err "    kubectl -n ${CFG[NAMESPACE]} delete pod imgtest"
      ;;
    *)
      err "The cause is not clear from the kubelet's message."
      ;;
  esac
  err ""
  err "To tell 'tag does not exist' apart from 'this cluster cannot reach that"
  err "registry', test an image that is certainly public:"
  err "    $SCRIPT_NAME -n ${CFG[NAMESPACE]} --check-image busybox:latest"
  err "If that also fails, the cluster restricts which registries it may pull"
  err "from, and the MongoDB images must be mirrored into an allowed one."
}

INSPECT_MARKER='
echo "MARK_BIN=$(command -v mongod 2>/dev/null || echo none)"
if [ -d /opt/bitnami/mongodb ]; then echo "MARK_BITNAMI=yes"; else echo "MARK_BITNAMI=no"; fi
if [ -d /bitnami/mongodb ]; then echo "MARK_BITNAMI_DATA=yes"; else echo "MARK_BITNAMI_DATA=no"; fi
if [ -d /data/db ]; then echo "MARK_OFFICIAL_DATA=yes"; else echo "MARK_OFFICIAL_DATA=no"; fi
echo "MARK_UID=$(id -u)"
'

inspect_image() {
  local image="$1"
  local name="mongo-inspect-$$"
  local manifest logs

  banner "IMAGE INSPECTION"
  log "image : ${image}"

  manifest="$(jq -n --arg name "$name" --arg image "$image" --arg script "$INSPECT_MARKER" \
                --argjson ps "$(sts_json | jq -c '(.spec.template.spec.imagePullSecrets // [])')" '
    { apiVersion: "v1", kind: "Pod",
      metadata: { name: $name, labels: { app: "mongo-image-inspect" } },
      spec: (
        { restartPolicy: "Never",
          containers: [ { name: "inspect", image: $image,
                          command: ["/bin/sh","-c",$script] } ] }
        + (if ($ps|length) > 0 then { imagePullSecrets: $ps } else {} end)
      )
    }' 2>/dev/null)"
  [[ -n "${manifest//[[:space:]]/}" ]] || die_code "$EX_PREFLIGHT" "could not build an inspect manifest"

  printf '%s' "$manifest" | kubectl -n "${CFG[NAMESPACE]}" apply -f - >/dev/null 2>&1 || true

  local deadline=$(( SECONDS + CFG[PROBE_TIMEOUT] )) phase reason
  while (( SECONDS < deadline )); do
    phase="$(kubectl -n "${CFG[NAMESPACE]}" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    reason="$(kubectl -n "${CFG[NAMESPACE]}" get pod "$name" \
              -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
    case "$reason" in
      ErrImagePull|ImagePullBackOff|InvalidImageName)
        kubectl -n "${CFG[NAMESPACE]}" delete pod "$name" --wait=false >/dev/null 2>&1 || true
        err "${image} could not be pulled (${reason})"
        die_code "$EX_PREFLIGHT" "image not pullable" ;;
    esac
    [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
    sleep 3
  done

  logs="$(kubectl -n "${CFG[NAMESPACE]}" logs "$name" 2>/dev/null || true)"
  kubectl -n "${CFG[NAMESPACE]}" delete pod "$name" --wait=false >/dev/null 2>&1 || true

  if [[ -z "${logs//[[:space:]]/}" ]]; then
    err "the image ran but produced no output; it may not contain /bin/sh"
    die_code "$EX_PREFLIGHT" "inspection produced no result"
  fi

  local bin bitnami bdata odata uid family
  bin="$(sed -n 's/^MARK_BIN=//p' <<<"$logs" | head -1)"
  bitnami="$(sed -n 's/^MARK_BITNAMI=//p' <<<"$logs" | head -1)"
  bdata="$(sed -n 's/^MARK_BITNAMI_DATA=//p' <<<"$logs" | head -1)"
  odata="$(sed -n 's/^MARK_OFFICIAL_DATA=//p' <<<"$logs" | head -1)"
  uid="$(sed -n 's/^MARK_UID=//p' <<<"$logs" | head -1)"

  if [[ "$bitnami" == "yes" ]]; then family="bitnami"
  elif [[ "$odata" == "yes" || "$bin" == /usr/bin/* ]]; then family="official"
  else family="unknown"; fi

  log "mongod binary      : ${bin:-unknown}"
  log "/opt/bitnami       : ${bitnami:-unknown}"
  log "/bitnami/mongodb   : ${bdata:-unknown}"
  log "/data/db           : ${odata:-unknown}"
  log "runs as uid        : ${uid:-unknown}"
  ok  "image family       : ${family}"

  # Compare against what the cluster is currently running.
  local cur_family; cur_family="$(image_family "${CFG[IMAGE_REPO]}" runtime)"
  log "currently running  : ${cur_family}"
  if [[ "$family" != "unknown" && "$cur_family" != "unknown" && "$family" != "$cur_family" ]]; then
    err ""
    err "This image is a DIFFERENT family from what is running."
    err "Swapping it into the existing StatefulSet would not work even with a"
    err "logical reload, because the pod spec is shaped for ${cur_family}:"
    err "  * the data volume is mounted where ${cur_family} expects it, not ${family}"
    err "  * the port and environment variables are ${cur_family}-specific"
    err "Changing family means changing the chart, not just the tag."
    finalize_report "failed" "image family mismatch: ${family} vs ${cur_family}"
    exit "$EX_REFUSED"
  fi

  ok "compatible with the running deployment"
  finalize_report "succeeded" "inspected ${image}: ${family}"
  exit "$EX_OK"
}


# Basic-auth credentials for a registry host, taken from the StatefulSet's own
# imagePullSecrets. The cluster already holds what is needed to read this
# registry; there is no reason to ask the operator for it again.
registry_auth_header() {
  local host="$1" secret cfg entry sa
  local -a secrets=()

  # Pull secrets can be attached to the pod spec or to its ServiceAccount.
  mapfile -t secrets < <(sts_json | jq -r '(.spec.template.spec.imagePullSecrets // [])[].name // empty' 2>/dev/null || true)
  sa="$(sts_json | jq -r '(.spec.template.spec.serviceAccountName // "default")' 2>/dev/null || echo default)"
  if [[ -n "$sa" ]]; then
    mapfile -t -O "${#secrets[@]}" secrets < <(kubectl -n "${CFG[NAMESPACE]}" get sa "$sa" \
      -o jsonpath='{range .imagePullSecrets[*]}{.name}{"\n"}{end}' 2>/dev/null || true)
  fi

  REGISTRY_AUTH_HOSTS=""
  for secret in "${secrets[@]}"; do
    [[ -n "$secret" ]] || continue
    cfg="$(kubectl -n "${CFG[NAMESPACE]}" get secret "$secret" \
            -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    [[ -n "${cfg//[[:space:]]/}" ]] || continue

    # Record which registries these secrets cover, for diagnostics. Never the
    # credentials themselves.
    local hosts
    hosts="$(printf '%s' "$cfg" | jq -r '(.auths // {}) | keys[]' 2>/dev/null | tr '\n' ' ' || true)"
    [[ -n "${hosts//[[:space:]]/}" ]] && REGISTRY_AUTH_HOSTS+="${secret}: ${hosts}"$'\n'

    entry="$(printf '%s' "$cfg" | jq -r --arg h "$host" '
        (.auths // {}) | to_entries
        | map(select((.key == $h) or (.key | contains($h))))
        | first // empty
        | if . == null then empty
          else (.value.auth // (
                 if (.value.username // "") != "" then
                   ((.value.username + ":" + (.value.password // "")) | @base64)
                 else empty end))
          end' 2>/dev/null || true)"

    if [[ -n "${entry//[[:space:]]/}" ]]; then
      printf 'Authorization: Basic %s' "$entry"
      return 0
    fi
  done
  return 1
}

# Tags straight from a private registry via the Docker Registry v2 API.
# Docker Hub's API only covers public repositories, so a mirrored or internal
# registry needs its own endpoint. Artifactory exposes both the plain /v2/ path
# and an /artifactory/api/docker/<repo>/v2/ variant, so try both.
list_tags_registry_v2() {
  local repo="$1" host path body url first_seg rest auth_hdr
  command -v curl >/dev/null 2>&1 || return 1

  host="${repo%%/*}"
  [[ "$repo" == */* ]] || return 1
  [[ "$host" == *.* || "$host" == *:* ]] || return 1
  path="${repo#*/}"
  first_seg="${path%%/*}"
  rest="${path#*/}"

  local -a urls=("https://${host}/v2/${path}/tags/list")
  [[ "$path" == */* ]] && urls+=("https://${host}/artifactory/api/docker/${first_seg}/v2/${rest}/tags/list")

  auth_hdr="$(registry_auth_header "$host" 2>/dev/null || true)"

  local tags
  for url in "${urls[@]}"; do
    if [[ -n "$auth_hdr" ]]; then
      body="$(curl -fsSL --max-time 25 -H "$auth_hdr" "$url" 2>/dev/null || true)"
    else
      body="$(curl -fsSL --max-time 25 "$url" 2>/dev/null || true)"
    fi
    [[ -z "${body//[[:space:]]/}" ]] && continue
    tags="$(printf '%s' "$body" | jq -r '.tags[]? // empty' 2>/dev/null || true)"
    if [[ -n "${tags//[[:space:]]/}" ]]; then
      printf '%s\n' "$tags"
      return 0
    fi
  done
  return 1
}

# All tags for a major, newest last. Docker Hub's API only exposes public
# repositories anonymously; a private registry returns nothing here.
list_tags_for_major() {
  local repo="$1" major="$2" path url body
  command -v curl >/dev/null 2>&1 || return 1
  path="$repo"; [[ "$path" != */* ]] && path="library/${path}"
  url="https://hub.docker.com/v2/repositories/${path}/tags?page_size=100&name=${major}."
  body="$(curl -fsSL --max-time 20 "$url" 2>/dev/null || true)"
  [[ -n "${body//[[:space:]]/}" ]] || return 1
  if [[ -z "$major" ]]; then
    printf '%s' "$body" | jq -r '.results[]?.name // empty' 2>/dev/null | sort -V || true
  else
    printf '%s' "$body" | jq -r '.results[]?.name // empty' 2>/dev/null \
      | grep -E "^${major//./\\.}\\." | sort -V || true
  fi
}

DBCOUNT_JS='
var dbs = db.adminCommand({listDatabases:1}).databases;
var n = 0;
for (var i = 0; i < dbs.length; i++) {
  var name = dbs[i].name;
  if (name != "admin" && name != "config" && name != "local") { n++; }
}
print(n);
'

INVENTORY_JS='
var dbs = db.adminCommand({listDatabases:1}).databases;
for (var i = 0; i < dbs.length; i++) {
  var n = dbs[i].name;
  if (n == "admin" || n == "config" || n == "local") { continue; }
  var d = db.getSiblingDB(n);
  var cols = d.getCollectionNames().sort();
  for (var j = 0; j < cols.length; j++) {
    var c = cols[j];
    if (c.indexOf("system.") == 0) { continue; }
    print(n + "." + c + "|" + d.getCollection(c).countDocuments({}) + "|" + d.getCollection(c).getIndexes().length);
  }
}
'

capture_inventory() {
  local pod="$1" outfile="$2"
  log "capturing collection inventory -> ${outfile}"
  if is_true "${CFG[DRY_RUN]}"; then
    printf '%s  [dry-run] would capture inventory to %s%s\n' "$C_YEL" "$outfile" "$C_OFF"
    return 0
  fi

  local errfile; errfile="$(mktemp)"
  mongo_eval_err "$pod" "$INVENTORY_JS" "$errfile" | grep -v '^$' > "$outfile" || true

  local n dbs
  n="$(grep -c . "$outfile" || true)"
  dbs="$(mongo_eval "$pod" "$DBCOUNT_JS" | tr -cd '0-9')"

  if [[ "${n:-0}" -eq 0 ]] && [[ "${dbs:-0}" -gt 0 ]]; then
    # The server has user databases but the inventory came back empty. That is
    # a broken check, not an empty database, and it must not pass silently.
    err "inventory returned nothing, but the server reports ${dbs} user database(s)"
    if [[ -s "$errfile" ]]; then
      err "the inventory script reported:"
      sed 's/^/           /' "$errfile" >&2
    fi
    rm -f "$errfile"
    err ""
    err "Verification cannot be trusted in this state. Re-run with"
    err "--skip-inventory to proceed knowingly, or report this output."
    is_true "${CFG[SKIP_INVENTORY]}" || die_code "$EX_VERIFY" "inventory check failed"
    return 0
  fi
  rm -f "$errfile"

  ok "inventory captured: ${n} collections"
  if [[ "${n:-0}" -eq 0 && "${dbs:-0}" -eq 0 ]]; then
    log "this server holds no user databases"
  fi
}

take_backup() {
  local pod="$1" outfile="${CFG[WORKDIR]}/pre-upgrade-dump.gz"

  if is_true "${CFG[SKIP_BACKUP]}"; then
    warn "--skip-backup set; no pre-upgrade dump will be taken"
    return 0
  fi

  log "taking pre-upgrade logical backup from ${pod}"
  if is_true "${CFG[DRY_RUN]}"; then
    printf '%s  [dry-run] would mongodump %s -> %s%s\n' "$C_YEL" "$pod" "$outfile" "$C_OFF"
    return 0
  fi

  if is_true "${CFG[NO_AUTH]}"; then
    kexec "$pod" env MTOOLS="${CFG[MONGO_TOOL_ARGS]}" MLOC="$MONGO_LOCATE" \
        MPORT="${MONGO_PORT:-27017}" \
        sh -c 'eval "$MLOC"; MD="$(_locate mongodump)" || { echo NO_MONGODUMP >&2; exit 127; }
               "$MD" --host 127.0.0.1 --port "$MPORT" --gzip --archive $MTOOLS' \
        > "$outfile" || die_code "$EX_PREFLIGHT" "mongodump failed (is mongodump present in the container?)"
  else
    kexec "$pod" env MUSER="${CFG[MONGO_USER]}" MPASS="$ROOT_PW" \
        MTOOLS="${CFG[MONGO_TOOL_ARGS]}" MLOC="$MONGO_LOCATE" \
        MPORT="${MONGO_PORT:-27017}" \
        sh -c 'eval "$MLOC"; MD="$(_locate mongodump)" || { echo NO_MONGODUMP >&2; exit 127; }
               "$MD" --host 127.0.0.1 --port "$MPORT" --username "$MUSER" --password "$MPASS" \
                     --authenticationDatabase admin --gzip --archive $MTOOLS' \
        > "$outfile" || die_code "$EX_PREFLIGHT" "mongodump failed (is mongodump present in the container?)"
  fi

  local sz; sz="$(du -h "$outfile" | cut -f1)"
  [[ -s "$outfile" ]] || die_code "$EX_PREFLIGHT" "backup archive is empty"
  ok "backup written: ${outfile} (${sz})"
  BACKUP_OK=1
  BACKUP_PATH="$outfile"
  printf '%s\n' "$outfile" > "${CFG[WORKDIR]}/.backup-path"
}

# Same checks as wait_for_health but returns non-zero instead of exiting, so
# the caller can revert before giving up.
wait_for_health_soft() {
  local deadline=$(( SECONDS + CFG[HEALTH_TIMEOUT] ))
  log "waiting for StatefulSet '${CFG[STATEFULSET]}' to become ready (timeout ${CFG[HEALTH_TIMEOUT]}s)"

  kubectl -n "${CFG[NAMESPACE]}" rollout status "sts/${CFG[STATEFULSET]}" \
      --timeout="${CFG[HEALTH_TIMEOUT]}s" || return 1

  local pod unhealthy
  while (( SECONDS < deadline )); do
    pod="$(sts_pods | head -1)"
    if [[ -n "$pod" ]] && mongo_eval "$pod" 'db.hello().isWritablePrimary' 2>/dev/null | grep -qi true; then
      unhealthy="$(mongo_eval "$pod" \
        'try { rs.status().members.filter(m => !["PRIMARY","SECONDARY","ARBITER"].includes(m.stateStr)).length } catch(e) { 0 }' \
        | tr -d '[:space:]')"
      if [[ "${unhealthy:-0}" == "0" ]]; then
        ok "cluster healthy"
        return 0
      fi
    fi
    sleep 10
  done
  return 1
}

# Empty one PVC using the image already running -- it is known to pull, and a
# generic utility image may not be available in a restricted registry.
wipe_pvc() {
  local pvc="$1" mount="$2" image="$3"
  local name="mongo-wipe-$$-${pvc//[^a-zA-Z0-9]/-}"
  name="$(printf '%s' "${name,,}" | cut -c1-62)"

  log "wiping ${pvc} (contents of ${mount})"
  if is_true "${CFG[DRY_RUN]}"; then
    printf '%s  [dry-run] would empty %s at %s%s\n' "$C_YEL" "$pvc" "$mount" "$C_OFF"
    return 0
  fi

  local manifest
  manifest="$(jq -n --arg name "$name" --arg image "$image" --arg pvc "$pvc" \
                    --arg mount "$mount" \
                    --argjson ps "$(sts_json | jq -c '(.spec.template.spec.imagePullSecrets // [])')" '
    { apiVersion: "v1", kind: "Pod",
      metadata: { name: $name, labels: { app: "mongo-data-wipe" } },
      spec: (
        { restartPolicy: "Never",
          containers: [ {
            name: "wipe", image: $image,
            command: ["/bin/sh","-c","set -e; ls -A \"$0\" >/dev/null 2>&1 || exit 0; rm -rf -- \"$0\"/* \"$0\"/.[!.]* 2>/dev/null || true; echo wiped", $mount],
            volumeMounts: [ { name: "data", mountPath: $mount } ]
          } ],
          volumes: [ { name: "data", persistentVolumeClaim: { claimName: $pvc } } ]
        }
        + (if ($ps|length) > 0 then { imagePullSecrets: $ps } else {} end)
      )
    }' 2>/dev/null)"

  [[ -n "${manifest//[[:space:]]/}" ]] \
    || die_code "$EX_UPGRADE" "could not build a wipe manifest for ${pvc}"

  printf '%s' "$manifest" | kubectl -n "${CFG[NAMESPACE]}" apply -f - >/dev/null 2>&1 \
    || die_code "$EX_UPGRADE" "could not start the wipe pod for ${pvc}"

  local deadline=$(( SECONDS + 300 )) phase
  while (( SECONDS < deadline )); do
    phase="$(kubectl -n "${CFG[NAMESPACE]}" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in
      Succeeded) kubectl -n "${CFG[NAMESPACE]}" delete pod "$name" --wait=false >/dev/null 2>&1 || true
                 ok "  ${pvc} emptied"; return 0 ;;
      Failed)    kubectl -n "${CFG[NAMESPACE]}" logs "$name" 2>/dev/null | sed 's/^/           /' >&2 || true
                 kubectl -n "${CFG[NAMESPACE]}" delete pod "$name" --wait=false >/dev/null 2>&1 || true
                 die_code "$EX_UPGRADE" "wipe pod failed for ${pvc}" ;;
    esac
    sleep 3
  done
  kubectl -n "${CFG[NAMESPACE]}" delete pod "$name" --wait=false >/dev/null 2>&1 || true
  die_code "$EX_UPGRADE" "wipe pod timed out for ${pvc}"
}

# ---------------------------------------------------------------------------
# Configuration resolution
# ---------------------------------------------------------------------------

resolve_config() {
  local key envvar envval
  for key in "${!DEFAULTS[@]}"; do
    envvar="MONGO_UPGRADE_${key}"
    envval="${!envvar:-}"
    if   [[ -n "${FROM_CLI[$key]+isset}"  ]]; then CFG["$key"]="${FROM_CLI[$key]}";  ORIGIN["$key"]="cli"
    elif [[ -n "$envval"                  ]]; then CFG["$key"]="$envval";            ORIGIN["$key"]="env:${envvar}"
    elif [[ -n "${FROM_FILE[$key]+isset}" ]]; then CFG["$key"]="${FROM_FILE[$key]}"; ORIGIN["$key"]="file"
    else                                           CFG["$key"]="${DEFAULTS[$key]}";  ORIGIN["$key"]="default"
    fi
  done

  if [[ "${CFG[NON_INTERACTIVE]}" == "auto" ]]; then
    if [[ ! -t 0 ]] || [[ -n "${CI:-}" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]] \
       || [[ -n "${JENKINS_URL:-}" ]] || [[ -n "${GITLAB_CI:-}" ]]; then
      CFG[NON_INTERACTIVE]="true"
    else
      CFG[NON_INTERACTIVE]="false"
    fi
    ORIGIN[NON_INTERACTIVE]="auto-detected"
  fi

  [[ -n "${CFG[WORKDIR]}" ]] || CFG[WORKDIR]="${PWD}/mongo-upgrade-$(date +%Y%m%d-%H%M%S)"
  [[ -n "${CFG[REPORT_JSON]}" ]] || CFG[REPORT_JSON]="${CFG[WORKDIR]}/report.json"
}

validate_config() {
  local errs=() b

  [[ -n "${CFG[NAMESPACE]}" ]] \
    || errs+=("NAMESPACE is required (--namespace, or NAMESPACE= in the config file)")

  # A tag is only dispensable for the read-only modes.
  if [[ -z "${CFG[TARGET_TAG]}" ]] && (( ! LIST_TAGS )) && (( ! PRINT_CONFIG )) \
     && (( ! FIX_PROBES )) \
     && [[ -z "$CHECK_IMAGE" && -z "$INSPECT_IMAGE" && -z "$TRY_TAGS" ]]; then
    errs+=("TARGET_TAG is required (-t/--target), e.g. -t 8.0.12-debian-12-r0")
    errs+=("  discover what your registry holds with:  --list-tags")
  fi

  case "${CFG[STRATEGY]}" in
    inplace|reinit) ;;
    *) errs+=("STRATEGY must be inplace or reinit, got '${CFG[STRATEGY]}'") ;;
  esac

  for b in HEALTH_TIMEOUT PROBE_TIMEOUT; do
    [[ "${CFG[$b]}" =~ ^[0-9]+$ ]] || errs+=("${b} must be an integer, got '${CFG[$b]}'")
  done

  for b in DRY_RUN NON_INTERACTIVE ASSUME_YES SKIP_IMAGE_CHECK SKIP_PROBE_CHECK SKIP_BACKUP \
           AUTO_FIX_PROBES SKIP_CONFIG_CHECK AUTO_FIX_CONFIG SKIP_INVENTORY \
           ALLOW_IMAGE_FAMILY_CHANGE ALLOW_IRREVERSIBLE NO_AUTH; do
    case "${CFG[$b],,}" in
      true|false|yes|no|1|0|on|off) ;;
      *) errs+=("${b} must be a boolean, got '${CFG[$b]}'") ;;
    esac
  done

  if [[ "${#errs[@]}" -gt 0 ]]; then
    err "configuration is invalid:"
    local e; for e in "${errs[@]}"; do err "  - ${e}"; done
    exit "$EX_CONFIG"
  fi
}

print_config() {
  local key
  printf '\n%sEffective configuration%s\n' "$C_BLD" "$C_OFF"
  printf '%-26s %-34s %s\n' "KEY" "VALUE" "SOURCE"
  printf '%-26s %-34s %s\n' "--------------------------" "----------------------------------" "----------"
  for key in $(printf '%s\n' "${!CFG[@]}" | sort); do
    printf '%-26s %-34s %s\n' "$key" "${CFG[$key]:-<empty>}" "${ORIGIN[$key]}"
  done
  printf '\n'
}

write_config_template() {
  local out="$1" key
  [[ -e "$out" ]] && die_code "$EX_CONFIG" "refusing to overwrite existing file: ${out}"
  {
    printf '# %s configuration\n' "$SCRIPT_NAME"
    printf '# Generated %s\n#\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '# Precedence: CLI flag > MONGO_UPGRADE_<KEY> env var > this file > default.\n'
    printf '# Blank values fall through to the default or to auto-detection.\n\n'
    for key in $(printf '%s\n' "${!DEFAULTS[@]}" | sort); do
      printf '%-26s = %s\n' "$key" "${DEFAULTS[$key]}"
    done
  } > "$out"
  ok "wrote config template: ${out}"
}

finalize_report() {
  local status="$1" message="${2:-}"
  local target="${CFG[REPORT_JSON]:-}"
  [[ -n "$target" ]] || return 0
  [[ -d "$(dirname "$target")" ]] || return 0
  local esc="${message//\\/\\\\}"; esc="${esc//\"/\\\"}"
  cat > "$target" <<JSONEOF
{
  "status": "${status}",
  "message": "${esc}",
  "started_at": "${RUN_STARTED}",
  "finished_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "namespace": "${CFG[NAMESPACE]:-}",
  "statefulset": "${CFG[STATEFULSET]:-}",
  "release": "${CFG[RELEASE]:-}",
  "version_from": "${CURRENT_VERSION:-}",
  "target_image": "${TARGET_IMAGE:-}",
  "backup": "${BACKUP_PATH:-}",
  "dry_run": ${CFG[DRY_RUN]:-false},
  "workdir": "${CFG[WORKDIR]:-}"
}
JSONEOF
  return 0
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
${SCRIPT_NAME} - upgrade MongoDB in a Kubernetes namespace

Given only a namespace it discovers the StatefulSet, container, port and
credentials, picks the newest tag the image repository offers, checks that the
probes and mongod config will work with it, backs the data up, and performs the
upgrade without prompting.

  inplace (default)  walk every major version in between, raising the FCV after
                     each. Storage is never touched.
  reinit             dump, erase the data volume, deploy the target directly,
                     restore. Needs only the target image.

REQUIRED
  -n, --namespace NS        Namespace containing the MongoDB StatefulSet
  -t, --target TAG          Image tag to upgrade to, e.g. 8.0.13-debian-12-r0
                            Default "auto": the newest version the image
                            repository offers, in the tag convention already in
                            use. With it, a namespace is the only argument
                            needed.

STRATEGY
      --strategy MODE       inplace | reinit  [inplace]
                            inplace  keep the existing data files and walk every
                                     major version between current and target,
                                     raising the FCV after each. Needs an image
                                     per major. Storage is never erased.
                            reinit   dump, erase the data volume, deploy the
                                     target directly, restore. Needs only the
                                     target image. Requires the volume to be
                                     eraseable.
      --hop-tags a=b,c=d    Explicit tag per intermediate major, e.g.
                            "6.0=6.0.9-debian-11-r16,7.0=7.0.14-debian-12-r0".
                            Discovered from the repository when omitted.

READ-ONLY MODES (change nothing, then exit)
      --fix-probes          Rewrite any probe that execs the removed 'mongo'
                            shell to use 'mongosh', keeping the other arguments,
                            then restart the pods. Required before any upgrade
                            to 6.0 or later.
      --list-tags           List tags available in the image repository
      --try-tags a,b,c      Ask the cluster to pull each candidate tag and
                            report which exist. Use when the registry will not
                            list its tags.
      --check-image REF     Report whether an image can be pulled by this
                            cluster, using the StatefulSet's own pull secrets
      --inspect-image REF   Run an image briefly and report what it actually is:
                            binary location, data directory, user, and family
      --print-config        Show the effective configuration and its origins
      --write-config FILE   Write a config template
      --dry-run             Print every step without performing any of it

DISCOVERY (auto-detected when omitted)
      --image-repo REPO     Repository the images are PULLED from.
                            [${DEFAULTS[IMAGE_REPO]}]
                            This repository is public and lists its tags, so
                            target discovery works without extra arguments.
                            Use "auto" to reuse whatever the running container
                            pulls from instead -- correct when a cluster can
                            only reach its own registry.
      --tag-source REPO     Repository to look up available TAGS in, when the
                            pull repository will not list them (common for
                            private registries and mirrors). Defaults to
                            --image-repo. Tags found here are still verified
                            against the pull repository before use.
      --statefulset NAME    StatefulSet name
      --container NAME      Container inside the pod
      --port PORT           MongoDB port
      --user NAME           Admin username [${DEFAULTS[MONGO_USER]}]
      --password-secret S   Secret holding the admin password
      --password-key K      Key within that secret
                            (or set MONGODB_ROOT_PASSWORD in the environment)
      --no-auth             Deployment runs without authentication

CONNECTION
      --tls                 Shorthand for --mongo-shell-args "--tls"
                            plus --mongo-tool-args "--ssl"
      --mongo-shell-args A  Extra flags for mongosh
      --mongo-tool-args A   Extra flags for mongodump/mongorestore

BEHAVIOUR
  -c, --config FILE         Load settings from FILE (KEY=VALUE, # comments)
      --workdir DIR         Artifact directory [./mongo-upgrade-<timestamp>]
      --report-json FILE    Machine-readable run report
      --health-timeout SEC  Wait for cluster health [${DEFAULTS[HEALTH_TIMEOUT]}]
      --probe-timeout SEC   Wait for an image pull probe [${DEFAULTS[PROBE_TIMEOUT]}]
      --skip-image-check    Do not verify the target image is pullable first
      --skip-probe-check    Do not check that the container probes work with the
                            target version
      --no-fix-probes       Do not repair probes automatically; fail instead
      --skip-config-check   Do not validate mongod.conf against the target image
      --no-fix-config       Do not strip rejected options automatically; fail
      --skip-inventory      Continue even if the collection inventory cannot be
                            captured (verification is then meaningless)
      --skip-backup         Do not take a pre-upgrade dump. The erase then has
                            no recovery path and is refused unless you also pass
                            --allow-irreversible.
      --allow-image-family-change
                            Permit a target from a different image family.
                            Rarely correct: the pod spec's mount path, port and
                            environment are specific to the running family.
      --allow-irreversible  Proceed with the erase even without a usable backup
      --interactive         Prompt for confirmation (default: non-interactive)
  -y, --yes                 Auto-approve prompts in interactive mode
  -h, --help                This message

EXIT CODES
  0 success   2 bad config   3 discovery failed   4 preflight failed
  5 upgrade failed   6 verification mismatch   7 refused for safety

EXAMPLES
  # everything automatic -- discovers target, fixes probes, upgrades
  ${SCRIPT_NAME} -n demo

  # rehearse the same run without changing anything
  ${SCRIPT_NAME} -n demo --dry-run

  ${SCRIPT_NAME} -n demo --list-tags
  ${SCRIPT_NAME} -n demo --inspect-image myreg.local/docker/mongodb:8.0.12-debian-12-r0
  ${SCRIPT_NAME} -n demo -t 8.0.12-debian-12-r0 --dry-run
  ${SCRIPT_NAME} -n demo -t 8.0.12-debian-12-r0
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

parse_args() {
  local -a argv=()
  local a
  for a in "$@"; do
    if [[ "$a" == --*=* ]]; then argv+=("${a%%=*}" "${a#*=}"); else argv+=("$a"); fi
  done
  set -- "${argv[@]+"${argv[@]}"}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--namespace)       FROM_CLI[NAMESPACE]="${2:?}"; shift 2 ;;
      -t|--target|--target-tag) FROM_CLI[TARGET_TAG]="${2:?}"; shift 2 ;;
      --strategy)           FROM_CLI[STRATEGY]="${2:?}"; shift 2 ;;
      --hop-tags)           FROM_CLI[HOP_TAGS]="${2:?}"; shift 2 ;;
      --image-repo)         FROM_CLI[IMAGE_REPO]="${2:?}"; shift 2 ;;
      --tag-source)         FROM_CLI[TAG_SOURCE]="${2:?}"; shift 2 ;;
      --statefulset)        FROM_CLI[STATEFULSET]="${2:?}"; shift 2 ;;
      --release)            FROM_CLI[RELEASE]="${2:?}"; shift 2 ;;
      --container)          FROM_CLI[CONTAINER]="${2:?}"; shift 2 ;;
      --port)               FROM_CLI[MONGO_PORT]="${2:?}"; shift 2 ;;
      --user)               FROM_CLI[MONGO_USER]="${2:?}"; shift 2 ;;
      --password-secret)    FROM_CLI[PASSWORD_SECRET]="${2:?}"; shift 2 ;;
      --password-key)       FROM_CLI[PASSWORD_KEY]="${2:?}"; shift 2 ;;
      --mongo-shell-args)   FROM_CLI[MONGO_SHELL_ARGS]="${2:?}"; shift 2 ;;
      --mongo-tool-args)    FROM_CLI[MONGO_TOOL_ARGS]="${2:?}"; shift 2 ;;
      --workdir)            FROM_CLI[WORKDIR]="${2:?}"; shift 2 ;;
      --report-json)        FROM_CLI[REPORT_JSON]="${2:?}"; shift 2 ;;
      --health-timeout)     FROM_CLI[HEALTH_TIMEOUT]="${2:?}"; shift 2 ;;
      --probe-timeout)      FROM_CLI[PROBE_TIMEOUT]="${2:?}"; shift 2 ;;

      --tls)                FROM_CLI[MONGO_SHELL_ARGS]="${FROM_CLI[MONGO_SHELL_ARGS]:-} --tls"
                            FROM_CLI[MONGO_TOOL_ARGS]="${FROM_CLI[MONGO_TOOL_ARGS]:-} --ssl"
                            shift ;;
      --no-auth)            FROM_CLI[NO_AUTH]="true"; shift ;;
      --dry-run)            FROM_CLI[DRY_RUN]="true"; shift ;;
      -y|--yes)             FROM_CLI[ASSUME_YES]="true"; shift ;;
      --skip-image-check)   FROM_CLI[SKIP_IMAGE_CHECK]="true"; shift ;;
      --skip-probe-check)   FROM_CLI[SKIP_PROBE_CHECK]="true"; shift ;;
      --no-fix-probes)      FROM_CLI[AUTO_FIX_PROBES]="false"; shift ;;
      --skip-config-check)  FROM_CLI[SKIP_CONFIG_CHECK]="true"; shift ;;
      --skip-inventory)     FROM_CLI[SKIP_INVENTORY]="true"; shift ;;
      --no-fix-config)      FROM_CLI[AUTO_FIX_CONFIG]="false"; shift ;;
      --skip-backup)        FROM_CLI[SKIP_BACKUP]="true"; shift ;;
      --allow-image-family-change) FROM_CLI[ALLOW_IMAGE_FAMILY_CHANGE]="true"; shift ;;
      --allow-irreversible) FROM_CLI[ALLOW_IRREVERSIBLE]="true"; shift ;;
      --non-interactive)    FROM_CLI[NON_INTERACTIVE]="true"; shift ;;
      --interactive)        FROM_CLI[NON_INTERACTIVE]="false"; shift ;;

      -c|--config)          CONFIG_FILE="${2:?}"; shift 2 ;;
      --check-image)        CHECK_IMAGE="${2:?}"; shift 2 ;;
      --inspect-image)      INSPECT_IMAGE="${2:?}"; shift 2 ;;
      --list-tags)          LIST_TAGS=1; shift ;;
      --fix-probes)         FIX_PROBES=1; shift ;;
      --try-tags)           TRY_TAGS="${2:?}"; shift 2 ;;
      --print-config)       PRINT_CONFIG=1; shift ;;
      --write-config)       WRITE_CONFIG="${2:?}"; shift 2 ;;

      -h|--help)            usage; exit "$EX_OK" ;;
      --)                   shift; break ;;
      -*) usage >&2; err "unknown argument: $1"; exit "$EX_CONFIG" ;;
      *)  usage >&2; err "unexpected positional argument: $1"; exit "$EX_CONFIG" ;;
    esac
  done
}

bootstrap_config() {
  parse_args "$@"
  if [[ -n "$WRITE_CONFIG" ]]; then write_config_template "$WRITE_CONFIG"; exit "$EX_OK"; fi
  [[ -z "$CONFIG_FILE" && -n "${MONGO_UPGRADE_CONFIG:-}" ]] && CONFIG_FILE="$MONGO_UPGRADE_CONFIG"
  [[ -n "$CONFIG_FILE" ]] && load_config_file "$CONFIG_FILE"
  resolve_config
  if (( PRINT_CONFIG )); then print_config; validate_config; ok "configuration is valid"; exit "$EX_OK"; fi
  validate_config
}

# ---------------------------------------------------------------------------
# Target image
# ---------------------------------------------------------------------------

# The tag alone is not enough: the repository must be one this cluster can pull
# from, and the image must belong to the same family as the running one.
resolve_target_image() {
  TARGET_IMAGE="${CFG[IMAGE_REPO]}:${CFG[TARGET_TAG]}"
  log "target image     : ${TARGET_IMAGE}"

  local running_repo; running_repo="$(strip_image_tag "$(current_container_image)")"
  if [[ "$running_repo" != "${CFG[IMAGE_REPO]}" ]]; then
    log "repository change: ${running_repo} -> ${CFG[IMAGE_REPO]}"
    log "the image is inspected and confirmed the same family before anything changes"
  fi
}


# The data directory each family uses by default.
family_data_dir() {
  case "$1" in
    bitnami)  printf '/bitnami/mongodb/data/db' ;;
    official) printf '/data/db' ;;
    *)        printf '' ;;
  esac
}

# Is $2 inside the volume mounted at $1?
path_covered_by_mount() {
  local mount="$1" path="$2"
  [[ -n "$mount" && -n "$path" ]] || return 1
  [[ "$path" == "$mount" || "$path" == "$mount"/* ]]
}

# Report the concrete incompatibilities between the running pod spec and an
# image of a different family. Generic warnings are not actionable; what
# matters is which specific settings the target would ignore or misplace.
family_compat_report() {
  local target_family="$1"
  local vct mount tgt_dir port_env cmd blockers=0

  vct="$(sts_volume_claim_name)"
  mount="$(sts_data_mount_path "$vct")"
  tgt_dir="$(family_data_dir "$target_family")"
  port_env="$(sts_env_value MONGODB_PORT_NUMBER)"
  cmd="$(sts_json | jq -r --arg c "${MONGO_CONTAINER:-mongodb}" '
        [ (.spec.template.spec.containers // [])[] | select(.name==$c)
          | ((.command // []) + (.args // []))[] ] | join(" ")' 2>/dev/null || true)"

  err "Specific conflicts with the running pod spec:"
  err ""

  # 1. Persistence -- does the target's data directory land on the volume?
  if path_covered_by_mount "$mount" "$tgt_dir"; then
    err "  OK   persistence: ${target_family} stores data in ${tgt_dir},"
    err "       which is inside the volume mounted at ${mount}."
  else
    err "  STOP persistence: ${target_family} stores data in ${tgt_dir},"
    err "       but the volume is mounted at ${mount:-<unknown>}."
    err "       Data would be written outside the volume and lost on restart."
    blockers=$(( blockers + 1 ))
  fi
  err ""

  # 2. Port -- MONGODB_PORT_NUMBER is Bitnami-only.
  if [[ -n "$port_env" && "$target_family" == "official" ]]; then
    err "  STOP port: MONGODB_PORT_NUMBER=${port_env} is a Bitnami variable."
    err "       The official image ignores it and listens on 27017, while the"
    err "       Service, probes and the replicator sidecar expect ${port_env}."
    err "       Fix by adding --port ${port_env} to the container's args."
    blockers=$(( blockers + 1 ))
  else
    err "  OK   port: no Bitnami-specific port variable in play."
  fi
  err ""

  # 3. Entrypoint -- Bitnami charts often invoke Bitnami scripts.
  if [[ "$cmd" == */opt/bitnami/* ]]; then
    err "  STOP entrypoint: the container runs a Bitnami script:"
    err "       ${cmd}"
    err "       That path does not exist in a ${target_family} image, so the"
    err "       container would fail immediately."
    blockers=$(( blockers + 1 ))
  else
    err "  OK   entrypoint: no Bitnami-specific command or args set."
  fi
  err ""

  # 4. Probes -- Bitnami charts exec the legacy `mongo` shell, which the
  #    official image has not shipped since 6.0 (it provides `mongosh`).
  local probe_cmds
  probe_cmds="$(sts_json | jq -r --arg c "${MONGO_CONTAINER:-mongodb}" '
      [ (.spec.template.spec.containers // [])[] | select(.name==$c)
        | (.readinessProbe, .livenessProbe, .startupProbe)
        | select(. != null) | (.exec.command // [])[] ] | join(" ")' 2>/dev/null || true)"
  if [[ "$target_family" == "official" ]] \
     && printf '%s' "$probe_cmds" | grep -qwE 'mongo|/opt/bitnami/[^ ]*'; then
    err "  STOP probes: the readiness/liveness probes run:"
    err "       ${probe_cmds}"
    err "       The official image has no 'mongo' binary (it ships 'mongosh'),"
    err "       so every probe errors and the pod never becomes Ready."
    blockers=$(( blockers + 1 ))
  else
    err "  OK   probes: no ${cur_family_hint:-Bitnami}-only binary in the probe commands."
  fi
  err ""

  # 5. Sidecars -- other containers may address MongoDB on a fixed port.
  local sidecars
  sidecars="$(sts_json | jq -r --arg c "${MONGO_CONTAINER:-mongodb}" '
      [ (.spec.template.spec.containers // [])[] | select(.name != $c) | .name ] | join(", ")' 2>/dev/null || true)"
  if [[ -n "${sidecars//[[:space:]]/}" && -n "$port_env" && "$target_family" == "official" ]]; then
    err "  WARN sidecars: ${sidecars}"
    err "       These connect to MongoDB on port ${port_env}. If the port moves,"
    err "       each one needs its own configuration updated, not just the chart."
    err ""
  fi

  # 6. File ownership -- the volume belongs to the running family's user.
  local run_uid fs_group
  run_uid="$(sts_json | jq -r '(.spec.template.spec.securityContext.runAsUser
              // (.spec.template.spec.containers[]?.securityContext.runAsUser) // empty)' 2>/dev/null | head -1 || true)"
  fs_group="$(sts_json | jq -r '(.spec.template.spec.securityContext.fsGroup // empty)' 2>/dev/null || true)"
  if [[ -n "${run_uid}${fs_group}" ]]; then
    err "  STOP file ownership: the volume is owned by the ${cur_family} user"
    err "       (runAsUser=${run_uid:-unset} fsGroup=${fs_group:-unset})."
    err "       A ${target_family} image runs as a different user and will get"
    err "       EACCES writing to ${mount:-the data volume}. mongod then never"
    err "       starts, so nothing listens and every probe fails."
    blockers=$(( blockers + 1 ))
  else
    err "  WARN file ownership: no securityContext is set, so the volume's"
    err "       existing ownership decides whether ${target_family} can write it."
  fi
  err ""

  # 7. Auth -- the two families configure it differently.
  if is_true "${CFG[NO_AUTH]}"; then
    err "  OK   auth: running without authentication, which both families allow"
    err "       (the official image simply starts unauthenticated when no"
    err "       MONGO_INITDB_ROOT_* variables are set)."
  else
    err "  WARN auth: ALLOW_EMPTY_PASSWORD / MONGODB_ROOT_PASSWORD are Bitnami"
    err "       variables. The official image uses MONGO_INITDB_ROOT_USERNAME"
    err "       and MONGO_INITDB_ROOT_PASSWORD, and only on first init."
  fi
  err ""

  if (( blockers > 0 )); then
    err "${blockers} blocking conflict(s). These are chart changes, not flags."
  else
    err "No blocking conflicts found, but the families still differ in the"
    err "container user and in how they initialise. Test in a scratch namespace"
    err "before doing this to real data."
  fi
  return 0
}





# Where to look tags up. A private registry often refuses to list its catalogue
# while happily serving pulls, so the tag source can be pointed at a public
# repository of the same lineage. Anything found is still verified against the
# repository the images are actually pulled from.
tag_source_repo() {
  if [[ -n "${CFG[TAG_SOURCE]}" ]]; then
    printf '%s' "${CFG[TAG_SOURCE]}"
  else
    printf '%s' "${CFG[IMAGE_REPO]}"
  fi
}

# Tags from the source repository: registry API first, then Docker Hub.
available_tags() {
  local repo; repo="$(tag_source_repo)"
  local tags upstream prefix
  tags="$(list_tags_registry_v2 "$repo" 2>/dev/null || true)"
  if [[ -z "${tags//[[:space:]]/}" ]]; then
    upstream="$repo"
    if prefix="$(mirror_prefix_from "$repo")"; then upstream="${repo#"${prefix}"/}"; fi
    tags="$(list_tags_for_major "$upstream" "" 2>/dev/null || true)"
  fi
  printf '%s' "$tags"
}


# Tags for one major, asked for as such. Fetching the whole catalogue and
# filtering locally does not work on a large repository: the API returns only
# the first page, which on a busy repo is entirely recent releases.
declare -A TAGS_BY_MAJOR_CACHE=()

tags_for_major() {
  local major="$1" repo tags upstream prefix
  repo="$(tag_source_repo)"

  if [[ -n "${TAGS_BY_MAJOR_CACHE[$major]+isset}" ]]; then
    printf '%s' "${TAGS_BY_MAJOR_CACHE[$major]}"
    return 0
  fi

  # A registry that lists its whole catalogue can be filtered locally.
  tags="$(list_tags_registry_v2 "$repo" 2>/dev/null || true)"
  if [[ -n "${tags//[[:space:]]/}" ]]; then
    tags="$(printf '%s\n' "$tags" | grep -E "^${major//./\\.}\\." || true)"
  else
    upstream="$repo"
    if prefix="$(mirror_prefix_from "$repo")"; then upstream="${repo#"${prefix}"/}"; fi
    tags="$(list_tags_for_major "$upstream" "$major" 2>/dev/null || true)"
  fi

  TAGS_BY_MAJOR_CACHE["$major"]="$tags"
  printf '%s' "$tags"
}

# The newest version the repository actually offers, in the tag convention
# already in use. Without this the operator must know a valid tag before the
# script can do anything, which defeats unattended operation.
resolve_auto_target() {
  [[ "${CFG[TARGET_TAG]}" != "auto" ]] && return 0

  local tags pick cur_major src
  src="$(tag_source_repo)"
  log "target tag       : auto -- asking ${src} what it offers"
  [[ "$src" != "${CFG[IMAGE_REPO]}" ]] \
    && log "                   (tags from ${src}, images pulled from ${CFG[IMAGE_REPO]})"

  tags="$(available_tags)"

  if [[ -z "${tags//[[:space:]]/}" ]]; then
    err "could not determine a target: ${src} would not list its tags"
    err ""
    err "Name a tag explicitly:"
    err "    -t <tag>"
    err "or point tag discovery at a repository that will list them:"
    err "    --tag-source bitnamilegacy/mongodb"
    err "or find what exists:"
    err "    $SCRIPT_NAME -n ${CFG[NAMESPACE]} --list-tags"
    err "    $SCRIPT_NAME -n ${CFG[NAMESPACE]} --try-tags \"tag1,tag2\""
    die_code "$EX_PREFLIGHT" "no target tag could be determined"
  fi

  # Prefer the convention the running image uses, so the lineage stays the same.
  if [[ "$(current_container_image)" == *-debian-* ]]; then
    pick="$(printf '%s\n' "$tags" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+-debian-[0-9]+-r[0-9]+$' | sort -V | tail -1)"
  fi
  [[ -z "${pick:-}" ]] && pick="$(printf '%s\n' "$tags" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
  [[ -z "${pick:-}" ]] && pick="$(printf '%s\n' "$tags" \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)"

  [[ -n "${pick:-}" ]] || die_code "$EX_PREFLIGHT" "no version-like tag found in ${CFG[IMAGE_REPO]}"

  cur_major="$(major_of "$CURRENT_VERSION")"
  if [[ "$(printf '%s\n%s\n' "$pick" "$CURRENT_VERSION" | sort -V | tail -1)" == "$CURRENT_VERSION" ]]; then
    ok "already running ${CURRENT_VERSION}; the newest tag available is ${pick}"
    finalize_report "no-op" "already at the newest available version"
    exit "$EX_OK"
  fi

  CFG[TARGET_TAG]="$pick"
  ORIGIN[TARGET_TAG]="auto-detected"
  ok "target selected  : ${pick} (newest in ${src}, upgrading from ${cur_major})"
}


# Remove a dotted key path from a block-mapping YAML document, then drop any
# parent left empty. Deliberately narrow: mongod configs are simple mappings,
# and a general YAML rewriter would risk reformatting things it should not.
YAML_RM_LEAF='
BEGIN { n = split(path, want, ".") }
{
  line = $0
  match(line, /^ */); ind = RLENGTH
  key = ""
  if (match(line, /^ *[A-Za-z_][A-Za-z0-9_]*:/)) key = substr(line, ind + 1, RLENGTH - ind - 1)
  if (key != "") {
    depth = int(ind / 2) + 1
    stack[depth] = key
    for (d = depth + 1; d <= 32; d++) stack[d] = ""
    ok = (depth == n)
    if (ok) for (i = 1; i <= n; i++) if (stack[i] != want[i]) ok = 0
    if (ok) { skipind = ind; skipping = 1; next }
  }
  if (skipping) {
    if (line ~ /^ *$/) next
    if (ind > skipind) next
    skipping = 0
  }
  print line
}'

YAML_RM_EMPTY='
{ lines[NR] = $0 }
END {
  for (i = 1; i <= NR; i++) {
    line = lines[i]
    match(line, /^ */); ind = RLENGTH
    if (line ~ /^ *[A-Za-z_][A-Za-z0-9_]*: *$/) {
      haschild = 0
      for (j = i + 1; j <= NR; j++) {
        if (lines[j] ~ /^ *$/) continue
        match(lines[j], /^ */); ind2 = RLENGTH
        if (ind2 > ind) haschild = 1
        break
      }
      if (!haschild) continue
    }
    print line
  }
}'

# Strip options the target mongod rejects, in place, in the ConfigMap.
# Every removed option is one that no longer exists in the target release, so
# dropping it restores the release default rather than changing behaviour.
fix_mongod_config() {
  local cm="$1" key="$2" opts="$3"
  local content new opt

  content="$(kubectl -n "${CFG[NAMESPACE]}" get cm "$cm" \
              -o jsonpath="{.data.${key//./\\.}}" 2>/dev/null || true)"
  [[ -n "${content//[[:space:]]/}" ]] || { warn "could not read ${key} from ${cm}"; return 1; }

  new="$content"
  while read -r opt; do
    [[ -n "$opt" ]] || continue
    log "  removing '${opt}'"
    new="$(printf '%s\n' "$new" | awk -v path="$opt" "$YAML_RM_LEAF" | awk "$YAML_RM_EMPTY")"
  done <<<"$opts"

  if [[ "$new" == "$content" ]]; then
    warn "nothing was removed; the option may be formatted unusually"
    return 1
  fi

  log "updated ${key}:"
  printf '%s\n' "$new" | sed 's/^/           /'

  if is_true "${CFG[DRY_RUN]}"; then
    printf '%s  [dry-run] would patch ConfigMap %s%s\n' "$C_YEL" "$cm" "$C_OFF"
    return 0
  fi

  local patch
  patch="$(jq -n --arg k "$key" --arg v "$new" '{data: {($k): $v}}' 2>/dev/null)"
  [[ -n "${patch//[[:space:]]/}" ]] || { err "could not build a ConfigMap patch"; return 1; }

  kubectl -n "${CFG[NAMESPACE]}" patch cm "$cm" --type=merge -p "$patch" >/dev/null \
    || { err "patching ConfigMap ${cm} failed"; return 1; }
  ok "ConfigMap ${cm} updated"
  log "the chart that generates ${cm} needs the same change, or Helm will revert it"
  return 0
}

# mongod rejects options removed in later releases and exits before writing a
# log, which is indistinguishable from a crash. Parse the config with the target
# binary first, so a removed setting is a preflight failure rather than a
# restart loop mid-upgrade.
validate_mongod_config() {
  local target_image="$1"
  is_true "${CFG[DRY_RUN]}" && return 0
  is_true "${CFG[SKIP_CONFIG_CHECK]}" && { warn "skipping the mongod config check"; return 0; }

  local vols
  vols="$(sts_json | jq -c --arg c "${MONGO_CONTAINER:-mongodb}" '
      [ (.spec.template.spec.containers // [])[] | select(.name==$c) | (.volumeMounts // [])[] ] as $mounts
      | [ (.spec.template.spec.volumes // [])[]
          | select(.configMap != null)
          | . as $v
          | ($mounts[] | select(.name == $v.name) | .mountPath) as $mp
          | { name: $v.name, cm: $v.configMap.name, mountPath: $mp } ]' 2>/dev/null || true)"

  local count; count="$(printf '%s' "$vols" | jq -r 'length' 2>/dev/null || echo 0)"
  [[ "${count:-0}" -gt 0 ]] || return 0

  banner "VALIDATING MONGOD CONFIG"

  local i cm mp keys key conf_paths=""
  for (( i = 0; i < count; i++ )); do
    cm="$(printf '%s' "$vols" | jq -r ".[$i].cm")"
    mp="$(printf '%s' "$vols" | jq -r ".[$i].mountPath")"
    [[ -n "$cm" && -n "$mp" && "$mp" != "null" ]] || continue
    keys="$(kubectl -n "${CFG[NAMESPACE]}" get cm "$cm" -o json 2>/dev/null \
             | jq -r '(.data // {}) | keys[]' 2>/dev/null || true)"
    while read -r key; do
      [[ "$key" == *.conf ]] || continue
      conf_paths+="${cm}|${mp}/${key}|${mp}"$'\n'
    done <<<"$keys"
  done

  if [[ -z "${conf_paths//[[:space:]]/}" ]]; then
    log "no mongod .conf file is mounted; nothing to validate"
    return 0
  fi

  local line conf mount vol_cm name manifest out bad=0 retry=0 _attempt
  while IFS='|' read -r vol_cm conf mount; do
    [[ -n "$conf" ]] || continue
   for _attempt in 1 2; do
    log "checking ${conf} against ${target_image}"
    name="$(printf '%s' "mongo-confcheck-$$-${vol_cm}" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' | cut -c1-62)"

    manifest="$(jq -n --arg name "$name" --arg image "$target_image" --arg cm "$vol_cm" \
                  --arg mount "$mount" --arg conf "$conf" \
                  --argjson ps "$(sts_json | jq -c '(.spec.template.spec.imagePullSecrets // [])')" '
      { apiVersion:"v1", kind:"Pod",
        metadata:{ name:$name, labels:{ app:"mongo-config-check" } },
        spec: ( { restartPolicy:"Never", terminationGracePeriodSeconds:0,
                  containers:[ { name:"check", image:$image,
                                 command:["/bin/sh","-c","mongod --config \"$0\" --outputConfig 2>&1 | head -40", $conf],
                                 volumeMounts:[ { name:"conf", mountPath:$mount } ] } ],
                  volumes:[ { name:"conf", configMap:{ name:$cm } } ] }
                + (if ($ps|length) > 0 then { imagePullSecrets:$ps } else {} end) ) }' 2>/dev/null)"
    [[ -n "${manifest//[[:space:]]/}" ]] || { warn "could not build a config-check manifest"; continue; }

    printf '%s' "$manifest" | kubectl -n "${CFG[NAMESPACE]}" apply -f - >/dev/null 2>&1 || true

    local deadline=$(( SECONDS + 180 )) phase
    while (( SECONDS < deadline )); do
      phase="$(kubectl -n "${CFG[NAMESPACE]}" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
      sleep 3
    done
    out="$(kubectl -n "${CFG[NAMESPACE]}" logs "$name" 2>/dev/null || true)"
    kubectl -n "${CFG[NAMESPACE]}" delete pod "$name" --wait=false --grace-period=0 >/dev/null 2>&1 || true

    if printf '%s' "$out" | grep -qi 'unrecognized option\|error parsing\|unknown option'; then
      err "${conf} is not valid for ${target_image}:"
      printf '%s\n' "$out" | grep -iE 'unrecognized option|error parsing|unknown option' \
        | sed 's/^/           /' >&2

      local opts
      opts="$(printf '%s' "$out" | sed -n 's/.*[Uu]nrecognized option: *//p' | tr -d '\r')"

      if [[ -n "${opts//[[:space:]]/}" ]] && is_true "${CFG[AUTO_FIX_CONFIG]}"; then
        err ""
        warn "removing the rejected option(s) automatically (--no-fix-config to disable)"
        local ckey="${conf##*/}"
        if fix_mongod_config "$vol_cm" "$ckey" "$opts"; then
          ok "  ${conf} repaired; it will be re-validated"
          retry=1
        else
          bad=1
        fi
      else
        err ""
        err "Remove the offending setting from ConfigMap '${vol_cm}' and from the"
        err "chart that generates it, then re-run. Options removed in newer"
        err "MongoDB releases cause mongod to exit before it writes any log, which"
        err "looks like an unexplained crash loop."
        bad=1
      fi
    else
      ok "  ${conf} parses cleanly"
      retry=0
    fi
    (( retry )) || break
    retry=0
   done
  done <<<"$conf_paths"

  (( bad == 0 )) || die_code "$EX_PREFLIGHT" "mongod config is incompatible with the target; nothing was modified"
}

# Rewrite probes that exec the removed `mongo` shell so they use `mongosh`,
# preserving every other argument. Applied across all containers, since the
# probe may sit on a sidecar rather than on mongod's own container.
fix_probes() {
  local json patch

  banner "FIXING PROBES"
  json="$(sts_json)"
  [[ -n "${json//[[:space:]]/}" ]] || die_code "$EX_DISCOVERY" "could not read the StatefulSet"

  # Report what is there before changing anything.
  local found
  found="$(printf '%s' "$json" | jq -r '
      (.spec.template.spec.containers // [])[]
      | .name as $n
      | [ {t:"readinessProbe", c:(.readinessProbe.exec.command // [])},
          {t:"livenessProbe",  c:(.livenessProbe.exec.command // [])},
          {t:"startupProbe",   c:(.startupProbe.exec.command // [])} ][]
      | select((.c | length) > 0 and (.c | index("mongo")))
      | "\($n)\t\(.t)\t\(.c | join(" "))"' 2>/dev/null || true)"

  if [[ -z "${found//[[:space:]]/}" ]]; then
    ok "no probe uses the legacy 'mongo' shell; nothing to change"
    if (( FIX_PROBES )); then
      finalize_report "no-op" "probes already compatible"
      exit "$EX_OK"
    fi
    return 0
  fi

  log "probes that exec 'mongo':"
  printf '%s\n' "$found" | sed 's/^/           /'
  log ""

  # Build a strategic-merge patch: same command, mongo -> mongosh.
  patch="$(printf '%s' "$json" | jq -c '
      { spec: { template: { spec: { containers:
        [ (.spec.template.spec.containers // [])[]
          | .name as $n
          | . as $ct
          | { name: $n }
            + ( if (($ct.readinessProbe.exec.command // []) | index("mongo"))
                then { readinessProbe: { exec: { command:
                       [ $ct.readinessProbe.exec.command[] | if . == "mongo" then "mongosh" else . end ] } } }
                else {} end )
            + ( if (($ct.livenessProbe.exec.command // []) | index("mongo"))
                then { livenessProbe: { exec: { command:
                       [ $ct.livenessProbe.exec.command[] | if . == "mongo" then "mongosh" else . end ] } } }
                else {} end )
            + ( if (($ct.startupProbe.exec.command // []) | index("mongo"))
                then { startupProbe: { exec: { command:
                       [ $ct.startupProbe.exec.command[] | if . == "mongo" then "mongosh" else . end ] } } }
                else {} end )
          | select((. | keys | length) > 1)
        ] } } } }' 2>/dev/null || true)"

  [[ -n "${patch//[[:space:]]/}" ]] || die_code "$EX_UPGRADE" "could not build a probe patch"

  log "patch to apply:"
  printf '%s\n' "$patch" | sed 's/^/           /'
  log ""

  if is_true "${CFG[DRY_RUN]}"; then
    printf '%s  [dry-run] would patch the StatefulSet and restart the pods%s\n' "$C_YEL" "$C_OFF"
    if (( FIX_PROBES )); then
      finalize_report "succeeded" "dry run: probes would be rewritten"
      exit "$EX_OK"
    fi
    return 0
  fi

  confirm "Patch sts/${CFG[STATEFULSET]} probes to use mongosh, and restart its pods?"

  kubectl -n "${CFG[NAMESPACE]}" patch statefulset "${CFG[STATEFULSET]}" -p "$patch" >/dev/null \
    || die_code "$EX_UPGRADE" "patching the StatefulSet failed"
  ok "StatefulSet patched"

  # A StatefulSet whose pod is unready will not replace it on its own.
  local p
  while read -r p; do
    [[ -z "$p" ]] && continue
    log "deleting ${p} so it restarts with the new probes"
    kubectl -n "${CFG[NAMESPACE]}" delete pod "$p" --wait=false >/dev/null 2>&1 || true
  done <<<"$(sts_pods)"

  if wait_for_health_soft; then
    ok "pods are Ready with the corrected probes"
  else
    warn "pods did not become Ready; inspect with:"
    warn "    kubectl -n ${CFG[NAMESPACE]} describe pod ${CFG[STATEFULSET]}-0"
  fi

  log ""
  log "Make the same change in the chart, or a later 'helm upgrade ${CFG[RELEASE]}'"
  log "will put the old probes back."
  if (( FIX_PROBES )); then
    finalize_report "succeeded" "probes rewritten to use mongosh"
    exit "$EX_OK"
  fi
  return 0
}

# The legacy `mongo` shell was removed in MongoDB 6.0 -- Bitnami and official
# images alike ship only `mongosh` from that release on. A chart whose probes
# exec `mongo` will therefore never report Ready on 6.0+, no matter which image
# is used, and the rollout stalls with mongod running perfectly underneath.
check_probe_compatibility() {
  local target_major="$1"
  local probe_cmds port

  # Only 6.0 and later are affected.
  [[ "$(printf '%s\n6.0\n' "$target_major" | sort -V | head -1)" == "6.0" ]] || return 0

  probe_cmds="$(sts_json | jq -r --arg c "${MONGO_CONTAINER:-mongodb}" '
      [ (.spec.template.spec.containers // [])[] | select(.name==$c)
        | (.readinessProbe, .livenessProbe, .startupProbe)
        | select(. != null) | (.exec.command // [])[] ] | join(" ")' 2>/dev/null || true)"

  [[ -n "${probe_cmds//[[:space:]]/}" ]] || return 0
  printf '%s' "$probe_cmds" | grep -qw 'mongo' || return 0
  # `mongosh` contains "mongo" but grep -w on the whole string needs care:
  # re-check that a bare `mongo` token is present.
  printf '%s\n' $probe_cmds | grep -qx 'mongo' || return 0

  port="${MONGO_PORT:-27017}"

  err "the container probes exec the legacy 'mongo' shell:"
  err "    ${probe_cmds}"
  err ""
  err "MongoDB removed that binary in 6.0. Every image from 6.0 onwards ships"
  err "'mongosh' instead, so these probes will error and the pod will never"
  err "become Ready -- while mongod itself runs correctly."
  err ""
  err "This blocks any route to ${target_major}, whichever strategy or image is used."
  err ""
  err "Fix the probes first:"
  err "    $SCRIPT_NAME -n ${CFG[NAMESPACE]} --fix-probes"
  err ""
  err "or by hand:"
  err "    kubectl -n ${CFG[NAMESPACE]} patch statefulset ${CFG[STATEFULSET]} -p '{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"${MONGO_CONTAINER:-mongodb}\",\"readinessProbe\":{\"exec\":{\"command\":[\"mongosh\",\"--port\",\"${port}\",\"--eval\",\"db.adminCommand(\\\"ping\\\")\"]}},\"livenessProbe\":{\"exec\":{\"command\":[\"mongosh\",\"--port\",\"${port}\",\"--eval\",\"db.adminCommand(\\\"ping\\\")\"]}}}]}}}}'"
    err ""
  err "and make the same change in the chart so Helm does not revert it."
  err ""
  if is_true "${CFG[AUTO_FIX_PROBES]}"; then
    warn "repairing the probes automatically (--no-fix-probes to disable)"
    fix_probes
    return 0
  fi
  err "To proceed regardless (the rollout will stall): --skip-probe-check"
  is_false "${CFG[SKIP_PROBE_CHECK]}" \
    && die_code "$EX_PREFLIGHT" "probes are incompatible with ${target_major}; nothing was modified"
  warn "continuing despite incompatible probes because --skip-probe-check was given"
}

# Verify each image the run will need. For inplace that is every hop; a tag
# discovered missing halfway leaves MongoDB stopped between majors.
verify_hop_images() {
  local -a hops=("$@")
  local hop image name prc failed=""

  is_true "${CFG[DRY_RUN]}" && return 0
  if is_true "${CFG[SKIP_IMAGE_CHECK]}"; then
    warn "skipping the image availability check"
    return 0
  fi

  banner "VERIFYING IMAGES"
  log "probing with the StatefulSet's own pull secrets and scheduling constraints"

  for hop in "${hops[@]}"; do
    image="${CFG[IMAGE_REPO]}:${RESOLVED_HOP_TAGS[$hop]}"
    name="$(printf '%s' "mongo-imgcheck-$$-${RESOLVED_HOP_TAGS[$hop]//[^a-zA-Z0-9]/-}" | tr 'A-Z' 'a-z' | cut -c1-62)"
    log "checking ${image}"
    prc=0
    probe_image_identify "$image" "$name" || prc=$?
    case "$prc" in
      0) if [[ "$PROBE_FAMILY" != "unknown" ]] \
            && [[ "$(image_family "${CFG[IMAGE_REPO]}" runtime)" != "unknown" ]] \
            && [[ "$PROBE_FAMILY" != "$(image_family "${CFG[IMAGE_REPO]}" runtime)" ]]; then
           err "  ${image} is a ${PROBE_FAMILY} image; the running deployment is $(image_family "${CFG[IMAGE_REPO]}" runtime)"
           failed+=" ${image}"
         else
           ok "  ${image} is pullable (${PROBE_FAMILY})"
         fi ;;
      1) err "  cannot pull ${image} (${PROBE_REASON})"
         [[ -n "$PROBE_MESSAGE" ]] && printf '%s\n' "$PROBE_MESSAGE" | fold -s -w 74 | sed 's/^/             /' >&2
         failed+=" ${image}" ;;
      *) err "  inconclusive for ${image} (${PROBE_REASON})"; failed+=" ${image}" ;;
    esac
  done

  if [[ -n "$failed" ]]; then
    err ""
    err "These images are not usable:"
    local i; for i in $failed; do err "    ${i}"; done
    err ""
    err "Nothing has been changed. An in-place upgrade needs every intermediate"
    err "major, so all of them must exist before it can start."
    err "    $SCRIPT_NAME -n ${CFG[NAMESPACE]} --image-repo ${CFG[IMAGE_REPO]} --list-tags"
    die_code "$EX_PREFLIGHT" "required images unavailable; nothing was modified"
  fi
}

verify_target_image() {
  is_true "${CFG[DRY_RUN]}" && return 0
  if is_true "${CFG[SKIP_IMAGE_CHECK]}"; then
    warn "skipping the image check; family and availability are unverified"
    return 0
  fi

  banner "VERIFYING THE TARGET IMAGE"
  log "probing with the StatefulSet's own pull secrets and scheduling constraints"

  local name safe prc=0
  safe="${CFG[TARGET_TAG]//[^a-zA-Z0-9]/-}"
  name="$(printf '%s' "mongo-imgcheck-$$-${safe}" | tr 'A-Z' 'a-z' | cut -c1-62)"

  probe_image_identify "$TARGET_IMAGE" "$name" || prc=$?
  case "$prc" in
    1) err "cannot pull ${TARGET_IMAGE} (${PROBE_REASON})"
       [[ -n "$PROBE_MESSAGE" ]] && { err ""; err "kubelet said:"
         printf '%s\n' "$PROBE_MESSAGE" | fold -s -w 78 | sed 's/^/           /' >&2; }
       explain_pull_failure "$TARGET_IMAGE"
       err ""
       err "Nothing has been changed. See what the repository holds with:"
       err "    $SCRIPT_NAME -n ${CFG[NAMESPACE]} --image-repo ${CFG[IMAGE_REPO]} --list-tags"
       die_code "$EX_PREFLIGHT" "target image is not pullable; nothing was modified" ;;
    2) err "could not determine whether ${TARGET_IMAGE} is pullable (${PROBE_REASON})"
       err "Treat this as 'unknown', not as 'available'."
       die_code "$EX_PREFLIGHT" "image check inconclusive; nothing was modified" ;;
  esac

  ok "${TARGET_IMAGE} is pullable"
  log "image contents   : ${PROBE_DETAIL}"

  local cur_family; cur_family="$(image_family "${CFG[IMAGE_REPO]}" runtime)"
  log "target family    : ${PROBE_FAMILY}"
  log "running family   : ${cur_family}"

  if [[ "$PROBE_FAMILY" == "unknown" ]]; then
    warn "could not determine the target image's family from its contents"
    warn "proceeding, but confirm the data directory and port match your pod spec"
    return 0
  fi

  if [[ "$cur_family" != "unknown" && "$PROBE_FAMILY" != "$cur_family" ]]; then
    err ""
    err "IMAGE FAMILY MISMATCH: running ${cur_family}, target is ${PROBE_FAMILY}"
    err "This was read from the image itself, not guessed from its name."
    err ""
    family_compat_report "$PROBE_FAMILY"
    err ""
    err "To proceed anyway: --allow-image-family-change"
    is_false "${CFG[ALLOW_IMAGE_FAMILY_CHANGE]}" \
      && die_code "$EX_REFUSED" "image family mismatch; nothing was modified"
    warn "proceeding across image families because --allow-image-family-change was given"
  else
    ok "target image is compatible with the running deployment"
  fi
}

show_available_tags() {
  local repo pull_repo tags major
  repo="$(tag_source_repo)"
  pull_repo="${CFG[IMAGE_REPO]}"

  banner "AVAILABLE TAGS"
  log "tag source : ${repo}"
  [[ "$repo" != "$pull_repo" ]] && log "pulling as : ${pull_repo}:<tag>"

  command -v curl >/dev/null 2>&1 \
    || die_code "$EX_PREFLIGHT" "curl is required to query the registry"

  # Determine credential availability here: list_tags_registry_v2 runs in a
  # command substitution, so anything it sets is lost with the subshell.
  REGISTRY_AUTH_USED=0
  registry_auth_header "${repo%%/*}" >/dev/null 2>&1 && REGISTRY_AUTH_USED=1

  tags="$(list_tags_registry_v2 "$repo" || true)"
  if [[ -n "${tags//[[:space:]]/}" ]]; then
    if (( REGISTRY_AUTH_USED )); then
      ok "read from ${repo%%/*} using the StatefulSet's pull secret"
    else
      ok "read from ${repo%%/*} anonymously"
    fi
  else
    if (( REGISTRY_AUTH_USED )); then
      log "the registry rejected the pull secret's credentials for listing; trying Docker Hub"
    else
      log "no usable credentials found in the pull secrets; trying Docker Hub"
    fi
    local upstream="$repo" prefix
    if prefix="$(mirror_prefix_from "$repo")"; then upstream="${repo#"${prefix}"/}"; fi
    tags="$(list_tags_for_major "$upstream" "" 2>/dev/null || true)"
  fi

  if [[ -z "${tags//[[:space:]]/}" ]]; then
    err "no tags could be listed for ${repo}"
    err ""
    if (( REGISTRY_AUTH_USED )); then
      err "The pull secret's credentials were tried and did not work for the"
      err "tags API. Pull rights do not always include catalog/list rights."
    else
      err "No credentials for ${repo%%/*} were found in the pull secrets."
      if [[ -n "${REGISTRY_AUTH_HOSTS//[[:space:]]/}" ]]; then
        err "The pull secrets cover these registries instead:"
        printf '%s' "$REGISTRY_AUTH_HOSTS" | sed 's/^/           /' >&2
      else
        err "No dockerconfigjson pull secrets are attached to the StatefulSet"
        err "or its ServiceAccount at all. The nodes may pull anonymously, or"
        err "credentials may be configured at the container runtime level --"
        err "either way there is nothing here to authenticate the tags API with."
      fi
    fi
    err ""
    err "Ask the registry directly with your own account:"
    err "    curl -u <user> https://${repo%%/*}/v2/${repo#*/}/tags/list"
    err "    curl -u <user> https://${repo%%/*}/artifactory/api/docker/${repo#*/}/v2/tags/list"
    err ""
    err "Or test a specific tag against the cluster:"
    err "    $SCRIPT_NAME -n ${CFG[NAMESPACE]} --check-image ${repo}:<tag>"
    finalize_report "failed" "could not list tags"
    exit "$EX_PREFLIGHT"
  fi

  local cur_major; cur_major="$(major_of "${CURRENT_VERSION:-0.0.0}")"
  log "currently running ${CURRENT_VERSION} (major ${cur_major})"
  log ""
  for major in $(printf '%s\n' "$tags" \
                  | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\)\..*/\1/p' | sort -Vu); do
    local list n
    list="$(printf '%s\n' "$tags" | grep -E "^${major//./\\.}\." | sort -V)"
    n="$(printf '%s\n' "$list" | grep -c . || true)"
    log "${major}: ${n} tag(s), newest last"
    printf '%s\n' "$list" | tail -8 | sed 's/^/             /'
    printf '%s\n' "$list" | tail -8 | sed 's/^/             /' >> "$LOG_FILE"
  done

  log ""
  log "Pick one, confirm it pulls, then upgrade:"
  log "    $SCRIPT_NAME -n ${CFG[NAMESPACE]} --check-image ${repo}:<tag>"
  log "    $SCRIPT_NAME -n ${CFG[NAMESPACE]} -t <tag> --dry-run"
  finalize_report "succeeded" "listed tags for ${repo}"
  exit "$EX_OK"
}


# When a rollout stalls, say WHICH container is holding it up. A pod is Ready
# only when every container is, so a failing sidecar looks identical to a
# failing database until you look per-container.
report_container_readiness() {
  local pod rows notready
  pod="$(sts_pods | head -1)"
  [[ -n "$pod" ]] || return 0

  rows="$(kubectl -n "${CFG[NAMESPACE]}" get pod "$pod" -o json 2>/dev/null | jq -r '
      (.status.containerStatuses // [])[]
      | "\(.name)\t\(if .ready then "READY" else "NOT READY" end)\trestarts=\(.restartCount)\t\((.state | keys | first) // "?")\t\(.state.waiting.reason // .state.terminated.reason // "")"' 2>/dev/null || true)"

  [[ -n "${rows//[[:space:]]/}" ]] || return 0

  err ""
  err "container status in ${pod}:"
  printf '%s\n' "$rows" | sed 's/^/           /' >&2

  notready="$(printf '%s\n' "$rows" | awk -F'\t' '$2 == "NOT READY" {print $1}')"
  [[ -n "${notready//[[:space:]]/}" ]] || return 0

  local c
  while read -r c; do
    [[ -z "$c" ]] && continue
    err ""
    err "last log lines from '${c}':"
    kubectl -n "${CFG[NAMESPACE]}" logs "$pod" -c "$c" --tail=15 2>/dev/null \
      | sed 's/^/           /' >&2 || true
  done <<<"$notready"

  # A sidecar blocking the rollout is a different problem from a failing database.
  if ! printf '%s\n' "$notready" | grep -qx "${MONGO_CONTAINER:-mongodb}"; then
    err ""
    err "NOTE: '${MONGO_CONTAINER:-mongodb}' is Ready -- the database itself is fine."
    err "The rollout is blocked by another container in the same pod:"
    printf '%s\n' "$notready" | sed 's/^/           /' >&2
    err ""
    err "A sidecar built for an older MongoDB may not work against the new one."
    err "Options: update that sidecar's image, or relax its probes so it cannot"
    err "hold the pod unready while you finish the upgrade."
  fi
}

# When the registry will not list its tags, the remaining option is to ask the
# cluster to pull specific candidates and see which succeed.
try_candidate_tags() {
  local csv="$1"
  local -a cands=()
  IFS=',' read -r -a cands <<<"$csv"

  banner "TRYING CANDIDATE TAGS"
  log "repository : ${CFG[IMAGE_REPO]}"
  log "candidates : ${#cands[@]}"
  log "each probe pulls for real, so this takes a little time"
  log ""

  local tag image name prc found=""
  for tag in "${cands[@]}"; do
    tag="${tag//[[:space:]]/}"
    [[ -n "$tag" ]] || continue
    image="${CFG[IMAGE_REPO]}:${tag}"
    name="$(printf '%s' "mongo-imgcheck-$$-${tag//[^a-zA-Z0-9]/-}" | tr 'A-Z' 'a-z' | cut -c1-62)"
    prc=0
    probe_image "$image" "$name" || prc=$?
    case "$prc" in
      0) ok  "  ${tag}  available"; found+="${tag}"$'\n' ;;
      1) log "  ${tag}  not present" ;;
      *) warn "  ${tag}  inconclusive (${PROBE_REASON})" ;;
    esac
  done

  log ""
  if [[ -n "${found//[[:space:]]/}" ]]; then
    ok "available tags in ${CFG[IMAGE_REPO]}:"
    printf '%s' "$found" | sed 's/^/             /'
    log ""
    log "Upgrade with the one you want:"
    log "    $SCRIPT_NAME -n ${CFG[NAMESPACE]} -t <tag> --dry-run"
    finalize_report "succeeded" "found candidate tags"
    exit "$EX_OK"
  fi

  err "none of the candidates are present in ${CFG[IMAGE_REPO]}"
  err "Ask whoever maintains that registry to mirror one in. A confirmed"
  err "compatible source for this image lineage is portworx/mongodb on Docker Hub."
  finalize_report "failed" "no candidate tags available"
  exit "$EX_PREFLIGHT"
}


# ---------------------------------------------------------------------------
# In-place upgrade: walk the featureCompatibilityVersion ladder
#
# mongod refuses to start against data whose FCV is more than one major version
# behind the binary. Carrying the existing files forward therefore means running
# every major in between, raising the FCV after each so the next binary will
# accept the files.
# ---------------------------------------------------------------------------

LADDER=(4.0 4.2 4.4 5.0 6.0 7.0 8.0)
declare -A RESOLVED_HOP_TAGS=()

ladder_index() {
  local want="$1" i
  for i in "${!LADDER[@]}"; do
    [[ "${LADDER[$i]}" == "$want" ]] && { printf '%s' "$i"; return 0; }
  done
  return 1
}

# Every major the deployment must pass through: current exclusive, target
# inclusive.
compute_path() {
  local from="$1" to="$2"
  local from_idx to_idx base_idx i base

  from_idx="$(ladder_index "$from")" \
    || die_code "$EX_CONFIG" "current major ${from} is not on the supported ladder (${LADDER[*]})"

  if to_idx="$(ladder_index "$to")"; then
    (( to_idx > from_idx )) || die_code "$EX_CONFIG" "target ${to} is not newer than current ${from}"
    for (( i = from_idx + 1; i <= to_idx; i++ )); do printf '%s\n' "${LADDER[$i]}"; done
  else
    base="${to%%.*}.0"
    base_idx="$(ladder_index "$base")" || die_code "$EX_CONFIG" "cannot resolve a path to ${to}"
    for (( i = from_idx + 1; i <= base_idx; i++ )); do printf '%s\n' "${LADDER[$i]}"; done
    printf '%s\n' "$to"
  fi
}

# A tag for each intermediate major. Explicit --hop-tags win; otherwise ask the
# repository what it actually has, preferring the newest patch.
resolve_hop_tags() {
  local target_major="$1"; shift
  local hops=("$@")
  local pair k v m tags pick

  if [[ -n "${CFG[HOP_TAGS]}" ]]; then
    local -a pairs=()
    IFS=',' read -r -a pairs <<<"${CFG[HOP_TAGS]}"
    for pair in "${pairs[@]}"; do
      k="${pair%%=*}"; v="${pair#*=}"
      [[ -n "$k" && -n "$v" && "$k" != "$v" ]] \
        || die_code "$EX_CONFIG" "malformed --hop-tags entry: '${pair}'"
      RESOLVED_HOP_TAGS["${k//[[:space:]]/}"]="${v//[[:space:]]/}"
    done
  fi

  for m in "${hops[@]}"; do
    if [[ "$m" == "$target_major" ]]; then
      RESOLVED_HOP_TAGS["$m"]="${CFG[TARGET_TAG]}"
      continue
    fi
    [[ -n "${RESOLVED_HOP_TAGS[$m]:-}" ]] && continue

    log "  looking up a ${m} tag in $(tag_source_repo)"
    tags="$(tags_for_major "$m")"

    if [[ -n "${tags//[[:space:]]/}" ]]; then
      # Prefer the tag convention already in use, then a bare version.
      pick="$(printf '%s\n' "$tags" | grep -E "^${m//./\\.}\\.[0-9]+-debian-[0-9]+-r[0-9]+$" | sort -V | tail -1)"
      [[ -z "$pick" ]] && pick="$(printf '%s\n' "$tags" | grep -E "^${m//./\\.}\\.[0-9]+$" | sort -V | tail -1)"
      if [[ -n "$pick" ]]; then
        RESOLVED_HOP_TAGS["$m"]="$pick"
        continue
      fi
    fi

    err "no tag found for MongoDB ${m} in ${CFG[IMAGE_REPO]}"
    err ""
    err "An in-place upgrade must run every major between ${CURRENT_VERSION} and"
    err "${CFG[TARGET_TAG]}, so an image is needed for each one."
    err "Supply it explicitly, or find what exists:"
    err "    --hop-tags \"${m}=<tag>\""
    err "    $SCRIPT_NAME -n ${CFG[NAMESPACE]} --tag-source bitnamilegacy/mongodb --list-tags"
    die_code "$EX_PREFLIGHT" "no image available for major ${m}"
  done
}

# Raising the FCV is what makes the next binary willing to open these files.
set_fcv() {
  local pod="$1" fcv="$2" js current res

  current="$(get_fcv "$pod")"
  if [[ "$current" == "$fcv" ]]; then
    ok "FCV already ${fcv}"
    return 0
  fi

  # 'confirm: true' became mandatory in 7.0.
  if [[ "$(printf '%s\n7.0\n' "$fcv" | sort -V | head -1)" == "7.0" ]]; then
    js="JSON.stringify(db.adminCommand({setFeatureCompatibilityVersion:'${fcv}',confirm:true}))"
  else
    js="JSON.stringify(db.adminCommand({setFeatureCompatibilityVersion:'${fcv}'}))"
  fi

  log "setting featureCompatibilityVersion to ${fcv}"
  if is_true "${CFG[DRY_RUN]}"; then
    printf '%s  [dry-run] would run: %s%s\n' "$C_YEL" "$js" "$C_OFF"
    return 0
  fi

  res="$(mongo_eval "$pod" "$js")" || die_code "$EX_UPGRADE" "setFeatureCompatibilityVersion(${fcv}) failed"
  if [[ "$(printf '%s' "$res" | jq -r '.ok // 0' 2>/dev/null)" != "1" ]]; then
    err "server response: ${res}"
    die_code "$EX_UPGRADE" "setFeatureCompatibilityVersion(${fcv}) did not return ok:1"
  fi

  # Every member must agree before the next binary starts, or it will refuse.
  local p got
  while read -r p; do
    [[ -z "$p" ]] && continue
    got="$(get_fcv "$p")"
    [[ "$got" == "$fcv" ]] \
      || die_code "$EX_UPGRADE" "pod ${p} reports FCV '${got}', expected '${fcv}'; a partial FCV upgrade will crash the next binary"
    log "  ${p}: FCV ${got}"
  done <<<"$(sts_pods)"
  ok "FCV is now ${fcv} on all members"
}

do_inplace() {
  local pod="$1"; shift
  local -a hops=("$@")
  local hop tag image image_now prev_major now

  image_now="$(current_container_image)"

  banner "PLAN"
  log "current image    : ${image_now}"
  log "path             : $(major_of "$CURRENT_VERSION") -> $(printf '%s -> ' "${hops[@]}" | sed 's/ -> $//')"
  for hop in "${hops[@]}"; do
    log "  ${hop}  ->  ${CFG[IMAGE_REPO]}:${RESOLVED_HOP_TAGS[$hop]}"
  done
  log "backup archive   : ${BACKUP_PATH:-<none>}"
  log ""
  log "Each hop restarts the StatefulSet and raises the FCV. Once raised, the"
  log "previous binary will no longer open these files: recovery is by restoring"
  log "the backup, not by setting the image back."

  confirm_irreversible \
    "In-place upgrade through ${#hops[@]} major version(s). Each FCV bump cannot be undone in place."

  for hop in "${hops[@]}"; do
    tag="${RESOLVED_HOP_TAGS[$hop]}"
    image="${CFG[IMAGE_REPO]}:${tag}"

    banner "HOP -> MongoDB ${hop}  (${tag})"

    # The FCV must match the running binary before the next one starts.
    if is_false "${CFG[DRY_RUN]}"; then
      pod="$(primary_pod)"
      prev_major="$(major_of "$(get_running_version "$pod")")"
      if [[ "$(get_fcv "$pod")" != "$prev_major" ]]; then
        log "FCV trails the running binary; raising to ${prev_major} first"
        set_fcv "$pod" "$prev_major"
      fi
    fi

    PREV_IMAGE="$(current_container_image)"
    log "setting image to ${image}"
    run kubectl -n "${CFG[NAMESPACE]}" set image \
        "statefulset/${CFG[STATEFULSET]}" "${MONGO_CONTAINER:-mongodb}=${image}"

    if is_false "${CFG[DRY_RUN]}"; then
      if ! wait_for_health_soft; then
        err "the rollout to ${tag} did not become healthy"
        report_container_readiness
        if [[ -n "$PREV_IMAGE" ]]; then
          warn "reverting to ${PREV_IMAGE}"
          kubectl -n "${CFG[NAMESPACE]}" set image \
              "statefulset/${CFG[STATEFULSET]}" "${MONGO_CONTAINER:-mongodb}=${PREV_IMAGE}" >/dev/null 2>&1 || true
          kubectl -n "${CFG[NAMESPACE]}" delete pod "${CFG[STATEFULSET]}-0" --wait=false >/dev/null 2>&1 || true
        fi
        err "the FCV was not raised for ${hop}, so the data is still readable by"
        err "the previous binary. The backup is at ${BACKUP_PATH:-<none>}."
        die_code "$EX_UPGRADE" "hop to ${hop} failed; deployment reverted"
      fi

      pod="$(primary_pod)"
      detect_shell_bin "$pod"
      now="$(get_running_version "$pod")"
      [[ "$(major_of "$now")" == "$(major_of "$hop")" ]] \
        || die_code "$EX_UPGRADE" "expected major ${hop} after rollout, server reports ${now}"
      ok "binaries now running ${now}"
      set_fcv "$pod" "$(major_of "$hop")"
    fi

    ok "hop to ${hop} complete"
  done
}

# ---------------------------------------------------------------------------
# The upgrade
# ---------------------------------------------------------------------------

restore_backup() {
  local pod="$1"
  kexec "$pod" env MTOOLS="${CFG[MONGO_TOOL_ARGS]}" MLOC="$MONGO_LOCATE" \
      MPORT="${MONGO_PORT:-27017}" MUSER="${CFG[MONGO_USER]}" MPASS="$ROOT_PW" \
      NOAUTH="$(is_true "${CFG[NO_AUTH]}" && echo 1 || echo 0)" \
      sh -c 'eval "$MLOC"; MR="$(_locate mongorestore)" || { echo NO_MONGORESTORE >&2; exit 127; }
             if [ "$NOAUTH" = "1" ]; then
               "$MR" --host 127.0.0.1 --port "$MPORT" --gzip --archive \
                     --nsExclude "admin.*" --nsExclude "config.*" --nsExclude "local.*" $MTOOLS
             else
               "$MR" --host 127.0.0.1 --port "$MPORT" --username "$MUSER" --password "$MPASS" \
                     --authenticationDatabase admin --gzip --archive \
                     --nsExclude "admin.*" --nsExclude "config.*" --nsExclude "local.*" $MTOOLS
             fi' < "$BACKUP_PATH"
}

do_upgrade() {
  local pod="$1"
  local vct mount replicas image_now
  local -a pvcs=()

  banner "PLAN"

  vct="$(sts_volume_claim_name)"
  [[ -n "$vct" ]] || die_code "$EX_DISCOVERY" \
    "the StatefulSet has no volumeClaimTemplate; cannot identify the data volume"
  mount="$(sts_data_mount_path "$vct")"
  [[ -n "$mount" ]] || die_code "$EX_DISCOVERY" \
    "could not find where volume '${vct}' is mounted in container '${MONGO_CONTAINER}'"
  mapfile -t pvcs < <(sts_pvc_names "$vct")
  replicas="$(sts_replica_count)"
  image_now="$(current_container_image)"

  log "data volume      : ${vct} mounted at ${mount}"
  log "replicas         : ${replicas}"
  log "volumes to erase : ${pvcs[*]}"
  log "current image    : ${image_now}"
  log "target image     : ${TARGET_IMAGE}"
  log "backup archive   : ${BACKUP_PATH:-<none>}"

  if is_false "${CFG[DRY_RUN]}"; then
    (( BACKUP_OK )) || die_code "$EX_REFUSED" \
      "this erases the data directory and there is no verified backup; refusing"
    [[ -s "$BACKUP_PATH" ]] || die_code "$EX_REFUSED" \
      "the backup archive is empty; refusing to erase"
  fi

  confirm_irreversible \
    "This erases the contents of ${#pvcs[@]} volume(s) and reloads from ${BACKUP_PATH}. The existing data files will be gone."

  # --- stop ---------------------------------------------------------------
  banner "STOPPING MONGODB"
  run kubectl -n "${CFG[NAMESPACE]}" scale "statefulset/${CFG[STATEFULSET]}" --replicas=0
  if is_false "${CFG[DRY_RUN]}"; then
    local deadline=$(( SECONDS + CFG[HEALTH_TIMEOUT] )) left ticks=0
    while (( SECONDS < deadline )); do
      left="$(sts_pods | grep -c . || true)"
      [[ "${left:-0}" == "0" ]] && break
      ticks=$(( ticks + 1 ))
      (( ticks % 6 == 1 )) && log "  waiting for ${left} pod(s) to terminate"
      sleep 5
    done
    left="$(sts_pods | grep -c . || true)"
    [[ "${left:-0}" == "0" ]] \
      || die_code "$EX_UPGRADE" "pods did not stop within ${CFG[HEALTH_TIMEOUT]}s; nothing was erased"
    ok "all pods stopped"
  fi

  # --- erase --------------------------------------------------------------
  banner "ERASING DATA VOLUMES"
  local p
  for p in "${pvcs[@]}"; do
    wipe_pvc "$p" "$mount" "$image_now"
  done

  # --- deploy the target --------------------------------------------------
  banner "DEPLOYING ${CFG[TARGET_TAG]}"
  run kubectl -n "${CFG[NAMESPACE]}" set image \
      "statefulset/${CFG[STATEFULSET]}" "${MONGO_CONTAINER:-mongodb}=${TARGET_IMAGE}"
  run kubectl -n "${CFG[NAMESPACE]}" scale \
      "statefulset/${CFG[STATEFULSET]}" --replicas="$replicas"

  if is_true "${CFG[DRY_RUN]}"; then
    printf '%s  [dry-run] would wait for health, then restore %s%s\n' \
      "$C_YEL" "${BACKUP_PATH:-<archive>}" "$C_OFF"
    return 0
  fi

  if ! wait_for_health_soft; then
    err "the target version did not come up healthy"
    report_container_readiness
    err ""
    err "The data volumes are empty and the archive is at:"
    err "    ${BACKUP_PATH}"
    err "To go back, restore the previous image and reload that archive:"
    err "    kubectl -n ${CFG[NAMESPACE]} set image statefulset/${CFG[STATEFULSET]} \\"
    err "        ${MONGO_CONTAINER:-mongodb}=${image_now}"
    err "    kubectl -n ${CFG[NAMESPACE]} delete pod ${CFG[STATEFULSET]}-0"
    die_code "$EX_UPGRADE" "target version failed to start"
  fi

  pod="$(primary_pod)"
  detect_shell_bin "$pod"
  local now; now="$(get_running_version "$pod")"
  ok "running ${now} on an empty data directory"

  # --- restore ------------------------------------------------------------
  banner "RESTORING DATA"
  restore_backup "$pod" \
    || die_code "$EX_UPGRADE" "mongorestore failed; the archive is still at ${BACKUP_PATH}"
  ok "data restored from ${BACKUP_PATH}"
}

verify_result() {
  local pod="$1"
  banner "VERIFICATION"

  if is_true "${CFG[DRY_RUN]}"; then
    printf '%s  [dry-run] would verify version, health and inventory%s\n' "$C_YEL" "$C_OFF"
    return 0
  fi

  detect_shell_bin "$pod"
  local v f
  v="$(get_running_version "$pod")"
  f="$(get_fcv "$pod")"
  log "server version : ${v}"
  log "FCV            : ${f}"

  mongo_eval "$pod" 'try { rs.status().members.forEach(m => print("  " + m.name + "  " + m.stateStr)) } catch(e) { print("  standalone") }' \
    | tee -a "$LOG_FILE"

  capture_inventory "$pod" "${CFG[WORKDIR]}/inventory-after.txt"

  if [[ ! -f "${CFG[WORKDIR]}/inventory-before.txt" ]]; then
    warn "no baseline inventory was captured; cannot compare"
  elif [[ ! -s "${CFG[WORKDIR]}/inventory-before.txt" ]] \
       && [[ ! -s "${CFG[WORKDIR]}/inventory-after.txt" ]]; then
    ok "no user collections before or after -- nothing to compare"
    log "this database holds only system collections, so the inventory check"
    log "cannot tell you much; it will be meaningful where there is real data"
  elif [[ -s "${CFG[WORKDIR]}/inventory-before.txt" ]]; then
    if diff -u "${CFG[WORKDIR]}/inventory-before.txt" "${CFG[WORKDIR]}/inventory-after.txt" \
         > "${CFG[WORKDIR]}/inventory.diff"; then
      ok "INVENTORY MATCH -- collection counts and index counts are identical"
      rm -f "${CFG[WORKDIR]}/inventory.diff"
    else
      err "INVENTORY MISMATCH -- see ${CFG[WORKDIR]}/inventory.diff"
      sed 's/^/    /' "${CFG[WORKDIR]}/inventory.diff" | head -40 >&2
      err ""
      err "The archive is still at ${BACKUP_PATH} and can be reloaded."
      die_code "$EX_VERIFY" "verification failed"
    fi
  else
    err "the baseline had no collections but the upgraded server does -- unexpected"
    die_code "$EX_VERIFY" "inventory mismatch"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  bootstrap_config "$@"

  mkdir -p "${CFG[WORKDIR]}"
  LOG_FILE="${CFG[WORKDIR]}/upgrade.log"
  : > "$LOG_FILE"

  banner "MongoDB upgrade -- namespace '${CFG[NAMESPACE]}'"
  is_true "${CFG[DRY_RUN]}" && warn "DRY RUN: no changes will be made"
  log "artifacts : ${CFG[WORKDIR]}"
  [[ -n "$CONFIG_FILE" ]] && log "config    : ${CONFIG_FILE}"

  check_prereqs
  discover_statefulset
  discover_release
  detect_sharding
  resolve_password

  local pod; pod="$(primary_pod)"
  [[ -n "$pod" ]] || die_code "$EX_DISCOVERY" "could not identify a MongoDB pod"
  resolve_mongo_container "$pod"

  # Read-only modes that do not need a healthy database.
  if [[ -n "$INSPECT_IMAGE" ]]; then
    detect_shell_bin "$pod" 2>/dev/null || true
    detect_image_repo 2>/dev/null || true
    inspect_image "$INSPECT_IMAGE"
  fi
  if [[ -n "$CHECK_IMAGE" ]]; then
    banner "IMAGE CHECK"
    log "image : ${CHECK_IMAGE}"
    local prc=0
    probe_image "$CHECK_IMAGE" "mongo-imgcheck-$$-manual" || prc=$?
    case "$prc" in
      0) ok "${CHECK_IMAGE} IS pullable by this cluster (${PROBE_REASON})"
         finalize_report "succeeded" "image ${CHECK_IMAGE} is pullable"; exit "$EX_OK" ;;
      1) err "${CHECK_IMAGE} is NOT pullable (${PROBE_REASON})"
         [[ -n "$PROBE_MESSAGE" ]] && { err ""; err "kubelet said:"
           printf '%s\n' "$PROBE_MESSAGE" | fold -s -w 78 | sed 's/^/           /' >&2; }
         explain_pull_failure "$CHECK_IMAGE"
         die_code "$EX_PREFLIGHT" "image not pullable" ;;
      *) err "result for ${CHECK_IMAGE} is INCONCLUSIVE (${PROBE_REASON})"
         err "Treat this as 'unknown', not as 'available'."
         die_code "$EX_PREFLIGHT" "image check inconclusive" ;;
    esac
  fi

  detect_shell_bin "$pod"
  detect_mongo_port
  detect_image_repo

  CURRENT_VERSION="$(get_running_version "$pod")"
  local cur_fcv; cur_fcv="$(get_fcv "$pod")"

  (( FIX_PROBES )) && fix_probes
  resolve_auto_target
  (( LIST_TAGS )) && show_available_tags
  [[ -n "$TRY_TAGS" ]] && try_candidate_tags "$TRY_TAGS"

  banner "DETECTED STATE"
  log "namespace        : ${CFG[NAMESPACE]}"
  log "statefulset      : ${CFG[STATEFULSET]}"
  log "primary pod      : ${pod}"
  log "current version  : ${CURRENT_VERSION}  (major $(major_of "$CURRENT_VERSION"))"
  log "current FCV      : ${cur_fcv:-unknown}"
  log "target tag       : ${CFG[TARGET_TAG]}"
  log "image repository : ${CFG[IMAGE_REPO]}"

  resolve_target_image
  log "strategy         : ${CFG[STRATEGY]}"

  if [[ "$(major_of "$CURRENT_VERSION")" == "$(major_of "${CFG[TARGET_TAG]}")" ]] \
     && [[ "$CURRENT_VERSION" == "${CFG[TARGET_TAG]}"* ]]; then
    ok "already running ${CURRENT_VERSION}; nothing to do"
    finalize_report "no-op" "already at ${CFG[TARGET_TAG]}"
    exit "$EX_OK"
  fi

  log ""
  log "Note: this sets the image directly on the StatefulSet. A later"
  log "'helm upgrade ${CFG[RELEASE]}' would revert it unless the chart values"
  log "are updated to ${CFG[TARGET_TAG]} as well."

  local -a hops=()
  if [[ "${CFG[STRATEGY]}" == "inplace" ]]; then
    mapfile -t hops < <(compute_path "$(major_of "$CURRENT_VERSION")" "$(major_of "${CFG[TARGET_TAG]}")")
    [[ "${#hops[@]}" -gt 0 ]] || die_code "$EX_CONFIG" "computed an empty upgrade path"
    log "majors to traverse: ${hops[*]}"
    resolve_hop_tags "$(major_of "${CFG[TARGET_TAG]}")" "${hops[@]}"
    check_probe_compatibility "${hops[0]}"
    verify_hop_images "${hops[@]}"
    validate_mongod_config "${CFG[IMAGE_REPO]}:${RESOLVED_HOP_TAGS[${hops[-1]}]}"
  else
    log "reinit reloads the data, so no intermediate major versions are needed."
    check_probe_compatibility "$(major_of "${CFG[TARGET_TAG]}")"
    verify_target_image
    validate_mongod_config "$TARGET_IMAGE"
  fi

  banner "BASELINE CAPTURE"
  capture_inventory "$pod" "${CFG[WORKDIR]}/inventory-before.txt"
  take_backup "$pod"

  if [[ "${CFG[STRATEGY]}" == "inplace" ]]; then
    do_inplace "$pod" "${hops[@]}"
  else
    do_upgrade "$pod"
  fi

  local verify_pod
  if is_true "${CFG[DRY_RUN]}"; then verify_pod="$pod"; else verify_pod="$(primary_pod)"; fi
  verify_result "$verify_pod"

  banner "UPGRADE COMPLETE"
  if [[ "${CFG[STRATEGY]}" == "inplace" ]]; then
    log "MongoDB is running ${CFG[TARGET_TAG]}. The existing data files were"
    log "carried forward and the FCV raised at each major version."
  else
    log "MongoDB is running ${CFG[TARGET_TAG]} with the data reloaded from the dump."
  fi
  log "backup retained : ${BACKUP_PATH:-<none>}"
  log "artifacts       : ${CFG[WORKDIR]}"
  finalize_report "succeeded" "upgraded to ${CFG[TARGET_TAG]}"
  ok "done"
  exit "$EX_OK"
}

# Allow sourcing for tests without executing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
