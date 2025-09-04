#!/bin/bash
# Copyright 2020-2021 RIFT Inc
CORE_DIR=$1

trap 'echo "Received TERM"; kill -TERM $CHILD; wait $CHILD' SIGTERM SIGINT

# start.sh will be available through the lifetime of container. When it exists pod will restart
# If "start_launchpad" is killed via "rwstop" we will go into an infinite sleep loop
# rwstart will enable us to exit the inner infinite sleep loop and resume outer loop
# If launchpad is exited due to any other reason other than rwstop we will hit else break
# and start.sh will eventually exit

while true;
do
  # fluentd fix
  if [ ! -d "/tmp/rift" ]; then
    mkdir -p /tmp/rift
    chmod -R 1777 /tmp/rift
    chmod -s /tmp/rift
  fi

  # launch as a new session - hence new process group
  setsid /usr/rift/bin/start_launchpad &
  CHILD=$!
  wait $CHILD
  if [ -e /tmp/RW.TESTING ]; then
    echo "Enter TESTING mode"
    while [ -e /tmp/RW.TESTING ]; do sleep 5 ; done
  else
    break
  fi
done

# Save the redis configuration as xml
/usr/rift/rift-shell -- /usr/rift/usr/bin/rw_redis_backup.py --save --config

/usr/rift/rift-shell -- /usr/rift/usr/bin/rwlogd-report-cores -s -o ${CORE_DIR}
