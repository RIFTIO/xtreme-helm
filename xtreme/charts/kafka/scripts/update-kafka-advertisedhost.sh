#!/bin/sh
set -e
#export PS4='+ ${BASH_SOURCE}:${LINENO}: '
#set -x

########################################
# DEFAULTS
########################################
DEFAULT_NAMESPACE="default"
DEFAULT_CLUSTER_NAME="zhone-strimzi"
DEFAULT_BOOTSTRAP_SVC="zhone-strimzi-kafka-external-bootstrap"
DEFAULT_INGRESS_SVC="default-haproxy-ingress"
DEFAULT_HELM_RELEASE="xtreme"

########################################
# USER INPUT
########################################
echo "                                "
read -p "Enter Kafka namespace [$DEFAULT_NAMESPACE]: " NAMESPACE
NAMESPACE=${NAMESPACE:-$DEFAULT_NAMESPACE}
read -p "Enter Helm Release Name [$DEFAULT_HELM_RELEASE]: " HELM_RELEASE
HELM_RELEASE=${HELM_RELEASE:-$DEFAULT_HELM_RELEASE}
read -p "Kafka cluster name [$DEFAULT_CLUSTER_NAME]: " CLUSTER_NAME
CLUSTER_NAME=${CLUSTER_NAME:-$DEFAULT_CLUSTER_NAME}

DEFAULT_INGRESS_SVC=${HELM_RELEASE}-"haproxy-ingress"

read -p "Ingress service [$DEFAULT_INGRESS_SVC]: " INGRESS_SVC
INGRESS_SVC=${INGRESS_SVC:-$DEFAULT_INGRESS_SVC}
echo " INGRESS_SVC : $INGRESS_SVC "

KAFKA_CR=$CLUSTER_NAME
HAPROXY_SVC=$INGRESS_SVC

echo "NAMESPACE :$NAMESPACE"
echo "KAFKA_CR :$KAFKA_CR"
echo "HAPROXY_SVC :$HAPROXY_SVC"


echo "Waiting for HAProxy ingress IP..."
while true; do
  echo "Checking service..."
  IP=$(kubectl get svc "$HAPROXY_SVC" -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  echo " in while loop IP: $IP"
  if [ -n "$IP" ]; then
    echo "Ingress IP found: $IP"
    break
  fi
  sleep 5
done

echo "HAPROXY INGRESS IP :$IP"
echo "Checking existing advertisedHost..."
EXISTING=$(kubectl get kafka "$KAFKA_CR" \
  -n "$NAMESPACE" \
  -o jsonpath='{.spec.kafka.listeners[2].configuration.brokers[0].advertisedHost}' \
  2>/dev/null || true)

if [ "$EXISTING" = "$IP" ]; then
  echo "advertisedHost already set correctly: $IP"
  exit 0
fi

echo "Updating external listener advertisedHost..."

kubectl patch kafka "$KAFKA_CR" \
  -n "$NAMESPACE" \
  --type=json \
  -p="[
    {
      \"op\": \"replace\",
      \"path\": \"/spec/kafka/listeners/2/configuration/brokers/0/advertisedHost\",
      \"value\": \"$IP\"
    },
    {
      \"op\": \"replace\",
      \"path\": \"/spec/kafka/listeners/2/configuration/brokers/0/advertisedPort\",
      \"value\": 9094
    }
  ]"

echo "advertisedHost updated successfully."

