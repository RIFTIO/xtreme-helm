#!/usr/bin/env bash
set -euo pipefail

# pool-has-multiple-ips.sh -- decide whether a load balancer address pool
# contains more than one IP address.
#
# Input: the address list as $1, or on stdin if no argument is given.
# One entry per line; each entry is a CIDR (10.0.0.0/28, 2001:db8::/64),
# an IP range (10.0.0.5-10.0.0.9), or a single IP.
#
# Exit status: 0 if the list contains more than one IP, 1 otherwise.
#
# Used by install_xtreme to decide whether alias.yaml/ports.yaml are needed.
# Kept as a standalone script so it can be tested in isolation, e.g.:
#   bin/pool-has-multiple-ips.sh "10.0.0.5-10.0.0.9"    # exit 0
#   echo "10.0.0.5/32" | bin/pool-has-multiple-ips.sh   # exit 1

addresses="${1-$(cat)}"

count=0
while IFS= read -r entry; do
    entry="${entry//[[:space:]]/}"
    if [ -z "$entry" ]; then
        continue
    fi
    case "$entry" in
        */*)
            # CIDR: any prefix shorter than a full host address means multiple IPs
            prefix="${entry##*/}"
            if [[ "$entry" == *:* ]]; then
                max=128
            else
                max=32
            fi
            if [ "$prefix" -lt "$max" ]; then
                exit 0
            fi
            ;;
        *-*)
            # range: different endpoints mean multiple IPs
            start="${entry%%-*}"
            end="${entry##*-}"
            if [ "$start" != "$end" ]; then
                exit 0
            fi
            ;;
    esac
    count=$((count + 1))
    if [ "$count" -gt 1 ]; then
        exit 0
    fi
done <<< "$addresses"
exit 1
