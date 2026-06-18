#!/bin/bash
# check-storage-classes.sh -- verify all storageClassNames used by the chart exist in the cluster
# Usage: check-storage-classes.sh <release> <chart> [helm flags...]

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: check-storage-classes.sh <release> <chart> [helm flags...]" >&2
    exit 1
fi

release=$1
chart=$2
shift 2

# Render the chart and extract unique non-null storageClassNames
storage_classes=$(helm template "$release" "$chart" "$@" 2>/dev/null \
    | awk '/storageClassName/ {print $2}' \
    | grep -v '^null$' \
    | grep -v '^""$' \
    | grep -v "^''$" \
    | tr -d '"'"'" \
    | sort -u)

if [ -z "$storage_classes" ]; then
    echo "INFO: No storageClassNames found in rendered chart — skipping check." >&2
    exit 0
fi

echo "StorageClasses referenced in chart:" >&2

failed=0
while IFS= read -r sc; do
    if kubectl get storageclass "$sc" >/dev/null 2>&1; then
        echo "  OK: $sc" >&2
    else
        echo "  MISSING: $sc" >&2
        failed=1
    fi
done <<< "$storage_classes"

if [ "$failed" -ne 0 ]; then
    echo "One or more storageClasses not found in cluster." >&2
    exit 1
fi

exit 0
