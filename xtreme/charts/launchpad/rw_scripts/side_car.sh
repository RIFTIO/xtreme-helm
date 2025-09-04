#!/bin/bash
# Copyright 2021 DZS Inc

trap 'echo "Received TERM"; kill -TERM $CHILD; wait $CHILD' SIGTERM SIGINT

# Check if developer license install was requested
if [ -n "$DEVELOPER_LICENSE" ]; then
  # wait till port number 8443 is up. We can then be sure that
  # agent can process config requests
  echo "Developer license needs to be installed. Wait for LP to be ready"
  while netstat -lnt | awk '$4 ~ /:8443$/ {exit 1}'
  do 
    echo "Waiting for LP to be ready"
    sleep 10
  done
  echo "Applying developer license configuration"
  sleep 10
  python3 /rwlicense localhost --internal-install -v
fi

# Do nothing. Used as an SDK for primitive script exec
while true
do
  sleep 300
done
