#!/bin/bash

set -euo pipefail

NS="demo"
values_file="values-aeo.yaml"

help() {
    cat >&2 <<EOF
USAGE: check_upgrade_from [--ns namespace] [--values path]

Verifies that the upgradeFrom value in the values file matches the version
currently running in the cluster. Run this before an upgrade to confirm the
values file is targeting the right source version.

--ns namespace   namespace to check (default: demo)
--values path    values file to inspect (default: values-aeo.yaml)
EOF
    exit 1
}

while [[ $# -gt 0 && "$1" =~ ^-- ]]; do
    case $1 in
        --ns)     NS=$2; shift;;
        --values) values_file=$2; shift;;
        *) help;;
    esac
    shift
done
if [ $# -gt 0 ]; then
    help
fi

if [ ! -f "$values_file" ]; then
    echo "ERROR: values file not found: $values_file" >&2
    exit 1
fi

upgrade_from=$(grep 'upgradeFrom:' "$values_file" | head -1 | awk '{print $2}')
if [ -z "$upgrade_from" ]; then
    echo "ERROR: upgradeFrom not found in $values_file" >&2
    exit 1
fi

running_version=$(kubectl -n "$NS" describe pod rw-launchpad-0 2>/dev/null \
    | awk '/RIFT_IMAGE_VERSION/ { print $2 }' | head -1)
if [ -z "$running_version" ]; then
    echo "ERROR: could not determine running version (is rw-launchpad-0 up in namespace $NS?)" >&2
    exit 1
fi

echo "Namespace:    $NS"
echo "Values file:  $values_file"
echo "upgradeFrom:  $upgrade_from"
echo "Running:      $running_version"

if [ "$upgrade_from" = "$running_version" ]; then
    echo "OK: upgradeFrom matches the running version"
else
    echo "MISMATCH: upgradeFrom ($upgrade_from) does not match running version ($running_version)" >&2
    exit 1
fi
