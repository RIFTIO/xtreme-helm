#!/usr/bin/env bash
set -euo pipefail

YAML="${1:-$(dirname "$0")/alias.yaml}"

if [[ ! -f "$YAML" ]]; then
  echo "ERROR: cannot find $YAML" >&2
  exit 1
fi

# Parse hostAliases blocks: collect (ip, hostname) pairs
# Format in file:
#   - ip: "1.2.3.4"
#     hostnames:
#     - "host.example"
declare -a PAIRS=()
current_ip=""
while IFS= read -r line; do
  if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+ip:[[:space:]]*\"?([^\"[:space:]]+)\"? ]]; then
    current_ip="${BASH_REMATCH[1]}"
  elif [[ -n "$current_ip" && "$line" =~ ^[[:space:]]*-[[:space:]]+\"?([^\"[:space:]]+)\"?$ ]]; then
    hostname="${BASH_REMATCH[1]}"
    PAIRS+=("$current_ip $hostname")
  elif [[ "$line" =~ ^[[:space:]]*ip: ]]; then
    # reset if we hit a new ip: at any indentation (shouldn't happen but be safe)
    current_ip=""
  fi
done < "$YAML"

# Also grab externalAddress and match it against the pairs
external_address=$(grep 'externalAddress:' "$YAML" | awk '{gsub(/"/, "", $2); print $2}')

if [[ ${#PAIRS[@]} -eq 0 ]]; then
  echo "ERROR: no hostAliases entries found in $YAML" >&2
  exit 1
fi

PASS=0
FAIL=0

check_dns() {
  local expected_ip="$1"
  local hostname="$2"

  printf "Checking %-35s -> expected %s ... " "$hostname" "$expected_ip"

  if ! resolved=$(host -t A "$hostname" 2>/dev/null); then
    echo "FAIL (DNS lookup failed — name not found)"
    ((FAIL++))
    return
  fi

  # host output: "hostname has address 1.2.3.4"
  resolved_ip=$(echo "$resolved" | awk '/has address/{print $NF}' | head -1)

  if [[ -z "$resolved_ip" ]]; then
    echo "FAIL (no A record returned)"
    ((FAIL++))
  elif [[ "$resolved_ip" == "$expected_ip" ]]; then
    echo "OK ($resolved_ip)"
    ((PASS++))
  else
    echo "FAIL (got $resolved_ip, expected $expected_ip)"
    ((FAIL++))
  fi
}

for pair in "${PAIRS[@]}"; do
  ip="${pair%% *}"
  host_name="${pair#* }"
  check_dns "$ip" "$host_name"
done

# If externalAddress differs from any hostname already checked, check it too
if [[ -n "$external_address" ]]; then
  already_checked=0
  for pair in "${PAIRS[@]}"; do
    if [[ "${pair#* }" == "$external_address" ]]; then
      already_checked=1
      break
    fi
  done
  if [[ $already_checked -eq 0 ]]; then
    # No expected IP for externalAddress alone — just verify it resolves
    printf "Checking externalAddress %-28s -> resolves? ... " "$external_address"
    if resolved=$(host -t A "$external_address" 2>/dev/null); then
      resolved_ip=$(echo "$resolved" | awk '/has address/{print $NF}' | head -1)
      echo "OK ($resolved_ip)"
      ((PASS++))
    else
      echo "FAIL (DNS lookup failed)"
      ((FAIL++))
    fi
  fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
