#!/bin/bash
# check-kernel-version.sh -- verify no cluster node runs a kernel incompatible with MongoDB
#
# MongoDB 8.0.x (vendored TCMalloc) violates the kernel rseq ABI, which changed
# in Linux 6.19. mongod detects this at startup and refuses to run on kernel
# 6.19 or newer ("Linux kernel versions 6.19 and newer has a known
# incompatibility with this version of MongoDB"). See MongoDB SERVER-121912.
#
# Revisit when MongoDB ships the SERVER-125742 relaxation: kernels >= 7.0.10
# carry the rseq fix, so the bar will become "< 6.19 or >= 7.0.10 with a fixed
# mongo image".
#
# Usage: check-kernel-version.sh

set -euo pipefail

MAX_MAJOR=6
MAX_MINOR=19   # first incompatible: 6.19

nodes=$(kubectl get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.nodeInfo.kernelVersion}{"\n"}{end}' 2>/dev/null) || nodes=""

if [ -z "$nodes" ]; then
    echo "ERROR: could not list cluster nodes" >&2
    exit 1
fi

echo "Node kernel versions (MongoDB requires < ${MAX_MAJOR}.${MAX_MINOR}):" >&2

failed=0
while IFS= read -r line; do
    node="${line%% *}"
    kernel="${line#* }"
    major=$(echo "$kernel" | cut -d. -f1)
    minor=$(echo "$kernel" | cut -d. -f2 | grep -o '^[0-9]*')
    if ! [[ "$major" =~ ^[0-9]+$ ]] || ! [[ "$minor" =~ ^[0-9]+$ ]]; then
        echo "  UNKNOWN: $node has unparseable kernel version: $kernel" >&2
        failed=1
    elif [ "$major" -gt "$MAX_MAJOR" ] || { [ "$major" -eq "$MAX_MAJOR" ] && [ "$minor" -ge "$MAX_MINOR" ]; }; then
        echo "  INCOMPATIBLE: $node runs kernel $kernel" >&2
        failed=1
    else
        echo "  OK: $node runs kernel $kernel" >&2
    fi
done <<< "$nodes"

if [ "$failed" -ne 0 ]; then
    echo "One or more nodes run a kernel MongoDB is incompatible with (>= ${MAX_MAJOR}.${MAX_MINOR})." >&2
    exit 1
fi

exit 0
