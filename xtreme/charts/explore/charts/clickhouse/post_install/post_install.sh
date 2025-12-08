#!/bin/bash

if [[ $# -ne 4 ]]; then
    echo "Invalid number of arguments"
    exit 1
fi

CH_HOST=$1
CH_PORT=$2
USER=$3
PASSWD=$4

DIR=$(dirname $0)

echo "-- Loading schema Host=$CH_HOST Port=$CH_PORT User=$USER"

count=500
while /bin/true
do
    if [[ $count -eq 1 ]]; then
        echo "-- Error: Unable to connect to clickhouse db. Max attempts reached"
        exit 2
    fi

    echo "-- Connection attempt $count"
    clickhouse-client --host $CH_HOST --port $CH_PORT --user $USER --password $PASSWD --query "SELECT 1"
    [[ $? -eq 0 ]] && break
    sleep 2
    count=$(($count-1))
done
echo "-- Clickhouse db is up"
sleep 10

for sql_file in $(ls $DIR/*.sql); do
    echo "-- Loading file $sql_file"
    clickhouse-client --host $CH_HOST --port $CH_PORT --user $USER --password $PASSWD --queries-file $sql_file
done
echo "-- All DB schemas loaded"
