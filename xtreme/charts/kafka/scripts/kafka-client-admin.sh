#!/bin/bash


set -e
set -euo pipefail
#export PS4='+ ${BASH_SOURCE}:${LINENO}: '
#set -x

########################
# Helpers
########################

die(){ echo "ERROR: $*" >&2; exit 1; }
info(){ echo -e "\n\033[1;34mINFO:\033[0m $*\n"; }
warn(){ echo -e "\n\033[1;33mWARN:\033[0m $*\n"; }
confirm(){ read -r -p "$* [y/N]: " _resp; [[ "$_resp" =~ ^[Yy] ]] ; }

kubectl_ns() { kubectl -n "$NAMESPACE" "$@"; }


# Function to show install instructions
function show_install_instructions() {
  echo
  echo "❌ Java and keytool are not available on this system."
  echo "➡️  Please install Java 11 or later and re-run this script."
  echo
  case $OS_TYPE in
    rhel)
      echo "   RHEL/CentOS/Rocky:"
      echo "     sudo yum install java-11-openjdk-headless"
      ;;
    debian)
      echo "   Ubuntu/Debian:"
      echo "     sudo apt-get update -y"
      echo "     sudo apt-get install -y openjdk-11-jre-headless"
      ;;
    *)
      echo "   Unsupported OS. Please install Java 11+ manually."
      ;;
  esac
  echo
  exit 1

}


# Function to install Java 17
function install_java() {
  info "⚠️ Java/keytool not found. Attempting to install OpenJDK 17 JRE..."

  if [ "$OS_TYPE" = "rhel" ]; then
    sudo yum install -y java-17-openjdk-headless
  elif [ "$OS_TYPE" = "debian" ]; then
    sudo apt-get update -y
    sudo apt-get install -y openjdk-17-jre-headless
  else
    info "❌ Unsupported OS. Please install Java 17 manually and re-run the script."
    exit 1
  fi

  # Verify installation
  if ! command -v java >/dev/null 2>&1 || ! command -v keytool >/dev/null 2>&1; then
    info "❌ Java/keytool installation failed. Please install manually and re-run the script."
    exit 1
  fi

  info "✅ Java 17 and keytool installed successfully"
}

function verifyServices() {

info "🔍 Verifying ingress  services..."

if ! kubectl get svc "$INGRESS_SVC" -n "$NAMESPACE" >/dev/null 2>&1; then  
  info "❌ Ingress service not found"
  exit 1
else
  info "✅ Ingress service $INGRESS_SVC found successfuly in the cluster "
fi  

#if ! kubectl_ns get svc "$BROKER_SVC" >/dev/null 2>&1; then
#   info "❌ Broker $BROKER_SVC service not found"
#   exit 1
#else
#   info "✅Broker service $BROKER_SVC found successfuly in the cluster"
#fi     

}

function createCertificates(){
 info "creating cluster ca  certificates "	
 #CLUSTER CA Certificate
  kubectl get secret $CLUSTER_CA_SECRET \
  -n $NAMESPACE \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > cluster-ca.crt

  info "creating clients ca certificates "

 #CLIENTS CA Certifcates
  kubectl get secret $CLIENTS_CA_SECRET \
  -n $NAMESPACE \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > clients-ca.crt

  #creating keystore client trust store 
  info "creating keystore for cluster-ca "

  if keytool -list \
     -keystore client.truststore.jks \
     -storepass changeit \
     -alias strimzi-cluster-ca >/dev/null 2>&1; then

     echo "Alias exists – deleting"
     keytool -delete \
       -alias strimzi-cluster-ca \
       -keystore client.truststore.jks \
       -storepass changeit
  else
    echo "Alias does not exist – skipping delete"
  fi

  keytool -importcert \
  -alias strimzi-cluster-ca \
  -file cluster-ca.crt \
  -keystore client.truststore.jks \
  -storepass changeit \
  -noprompt

  info "certificates creation successful"


}
########################################
# DEFAULTS
########################################
DEFAULT_CLUSTER_NAME="zhone-strimzi"
DEFAULT_BOOTSTRAP_SVC="zhone-strimzi-kafka-external-bootstrap"
DEFAULT_INGRESS_SVC="default-haproxy-ingress"
DEFAULT_HELM_RELEASE="xtreme"
#DEFAULT_BROKER_SVC="zhone-strimzi-kafka-broker-1"
KAFKA_VERSION="4.1.1"
KAFKA_PORT="9094"
WORKDIR="$HOME/kafka-client"
KAFKA_HOME="$WORKDIR/kafka_2.13-${KAFKA_VERSION}"
PASSWORD="changeit"

KAFKA_USER_SECRET="admin"
CLIENTS_CA_SECRET="zhone-strimzi-clients-ca-cert"
CLUSTER_CA_SECRET="zhone-strimzi-cluster-ca-cert"

########################################
#  start 
########################################

########################################
# PRE-REQUISITE CHECK: JAVA / KEYTOOL
########################################
set -e

info "🔍 Checking Java / keytool pre-requisites..."

# Detect OS
OS_TYPE=""
if [ -f /etc/redhat-release ]; then
  OS_TYPE="rhel"
elif [ -f /etc/debian_version ]; then
  OS_TYPE="debian"
else
  OS_TYPE="unknown"
fi

info " OS TYPE : $OS_TYPE"

info "##################################################"
info " Pre-requisites verification and installation "
info "#################################################"
# Check java and keytool
if ! command -v java >/dev/null 2>&1 || ! command -v keytool >/dev/null 2>&1; then
  install_java
else
  info "✅ Java and keytool are already installed"
fi


info "✅ Java and keytool are available"
java -version 2>&1 | head -n 1


########################################
# PREPARE WORKDIR
########################################
if [ ! -d "$WORKDIR" ]; then
  info "📁 Creating work directory: $WORKDIR"
  mkdir -p "$WORKDIR"
fi

cd "$WORKDIR"

########################################
# INSTALL KAFKA CLIENT
########################################
if [ ! -d "$KAFKA_HOME" ]; then
  info "⬇️  Installing Kafka client ${KAFKA_VERSION}..."
  wget -q https://downloads.apache.org/kafka/${KAFKA_VERSION}/kafka_2.13-${KAFKA_VERSION}.tgz
  tar -xzf kafka_2.13-${KAFKA_VERSION}.tgz
else
  info "✅ Kafka client already installed"
fi




########################################
# USER INPUT
########################################
echo "                                "
read -p "Enter Kafka namespace: " NAMESPACE
read -p "Enter Helm Release Name [$DEFAULT_HELM_RELEASE]: " HELM_RELEASE
HELM_RELEASE=${HELM_RELEASE:-$DEFAULT_HELM_RELEASE}
read -p "Kafka cluster name [$DEFAULT_CLUSTER_NAME]: " CLUSTER_NAME
CLUSTER_NAME=${CLUSTER_NAME:-$DEFAULT_CLUSTER_NAME}

DEFAULT_INGRESS_SVC=${HELM_RELEASE}-"haproxy-ingress"

read -p "Ingress service [$DEFAULT_INGRESS_SVC]: " INGRESS_SVC
INGRESS_SVC=${INGRESS_SVC:-$DEFAULT_INGRESS_SVC}
echo " INGRESS_SVC : $INGRESS_SVC "


########################################
# VERIFY SERVICES
########################################

verifyServices

# Prefer IP (MetalLB / bare metal)

INGRESS_HOST=$(kubectl get svc "$INGRESS_SVC" -n "$NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Fallback to hostname (cloud LB)
if [ -z "$INGRESS_HOST" ]; then
  INGRESS_HOST=$(kubectl get svc "$INGRESS_SVC" -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
fi

info "INGRESS_HOST  as: ${INGRESS_HOST:-<empty>}"

if [ -z "$INGRESS_HOST" ]; then
  info "❌ No external LoadBalancer address found for service $INGRESS_SVC"
  info "➡️  Ensure Ingress external listener is of type LoadBalancer"

  ALT_INGRESS_SVC=${NAMESPACE}-"haproxy-ingress"
  TEMP_INGRESS_HOST=$(kubectl get svc "$ALT_INGRESS_SVC" -n "$NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

  if [ -z "$TEMP_INGRESS_HOST" ]; then
	  TEMP_INGRESS_HOST=$(kubectl get svc "$ALT_INGRESS_SVC" -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
  fi

  if [ -z "$TEMP_INGRESS_HOST" ]; then
	  info "❌ No external LoadBalancer address found for service $TEMP_INGRESS_SVC"
          info "➡️  Ensure Ingress external listener is of type LoadBalancer"
	  exit 1
  fi

  INGRESS_HOST=TEMP_INGRESS_HOST
  INGRESS_SVC=ALT_INGRESS_SVC
    
fi

BOOTSTRAP_SERVER="${INGRESS_HOST}:${KAFKA_PORT}"

info "BOOTSTRAP_SERVER : $BOOTSTRAP_SERVER"

#if [[ "$BOOTSTRAP_SERVER" == *.svc.cluster.local* ]]; then
#  info "❌ Internal Kubernetes DNS detected. External access will fail."
#  exit 1
#fi

info "✅ External bootstrap server found as: $BOOTSTRAP_SERVER"

cd "$WORKDIR"


# CREATING CERTIFICATES
#
createCertificates


KAFKA_USER=admin
KAFKA_USER_SECRET=kafka-user-admin-secret
PASSWORD=$(kubectl get secret "$KAFKA_USER_SECRET" -n "$NAMESPACE" \
  -o jsonpath='{.data.password}' | base64 -d)

if [ -z "$PASSWORD" ]; then
  echo "❌ Failed to retrieve Kafka user password"
  exit 1
fi

########################################
# CLIENT PROPERTIES
########################################

info " Creating client.properties file"

if [ -f client.properties ]; then
   rm client.properties
fi   

if [ ! -f client.properties ]; then
cat > client.properties <<EOF

security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="$KAFKA_USER" password="$PASSWORD";
ssl.truststore.location=$WORKDIR/client.truststore.jks
ssl.truststore.password=changeit
ssl.endpoint.identification.algorithm=

EOF

fi
info " Creating client.properties file completed successfully"

#ssl.truststore.location=$WORKDIR/admin.keystore.jks
#ssl.truststore.password=changeit


#sed "s|__PASSWORD__|$PASSWORD|g" > client.properties

########################################
# MENU
########################################
info "##################################"
info "       KAFKA OPERATIONS MENU      "
info "#################################"
while true; do
  echo
  echo "1) List topics"
  echo "2) Create topic"
  echo "3) Describe topic"
  echo "4) Produce"
  echo "5) Consume"
  echo "6) Delete topic"
  echo "7) List Consumer Groups"
  echo "8) Describe Consumer Group"
  echo "9) Get Cluster Metadata"

  echo "0) Exit"
  read -p "Choose: " C

  case $C in
  #  1) $KAFKA_HOME/bin/kafka-topics.sh --bootstrap-server "$BOOTSTRAP_SERVER" --command-config $WORKDIR/client.properties --list ;;
    1) $KAFKA_HOME/bin/kafka-topics.sh --bootstrap-server "$BOOTSTRAP_SERVER" --command-config $WORKDIR/client.properties  --list ;;
    2) read -p "Topic: " T; $KAFKA_HOME/bin/kafka-topics.sh --bootstrap-server "$BOOTSTRAP_SERVER" --command-config $WORKDIR/client.properties --create --topic "$T" --partitions 1 --replication-factor 1 ;;
    3) read -p "Topic: " T; $KAFKA_HOME/bin/kafka-topics.sh --bootstrap-server "$BOOTSTRAP_SERVER" --command-config $WORKDIR/client.properties --describe --topic "$T" ;;
    4) read -p "Topic: " T; $KAFKA_HOME/bin/kafka-console-producer.sh --bootstrap-server "$BOOTSTRAP_SERVER"  --producer.config  $WORKDIR/client.properties --topic "$T" ;;
    5) read -p "Topic: " T; $KAFKA_HOME/bin/kafka-console-consumer.sh --bootstrap-server "$BOOTSTRAP_SERVER" --consumer.config  $WORKDIR/client.properties --topic "$T" --from-beginning ;;
    6) read -p "Topic: " T; $KAFKA_HOME/bin/kafka-topics.sh --bootstrap-server "$BOOTSTRAP_SERVER" --command-config $WORKDIR/client.properties --delete --topic "$T" ;;
    7) $KAFKA_HOME/bin/kafka-consumer-groups.sh --bootstrap-server "$BOOTSTRAP_SERVER" --command-config $WORKDIR/client.properties --list ;;
    8) read -p "Group: " G; $KAFKA_HOME/bin/kafka-consumer-groups.sh  --bootstrap-server "$BOOTSTRAP_SERVER" --command-config $WORKDIR/client.properties --describe --group "$G" ;;
    9) $KAFKA_HOME/bin/kafka-broker-api-versions.sh --bootstrap-server "$BOOTSTRAP_SERVER" --command-config $WORKDIR/client.properties ;;
    0) exit 0 ;;
#    2) read -p "Topic: " T; $KAFKA_HOME/bin/kafka-topics.sh --bootstrap-server "$BOOTSTRAP_SERVER" --command-config $WORKDIR/client.properties --create --topic "$T" --partitions 1 --replication-factor 1 ;;
#    3) read -p "Topic: " T; $KAFKA_HOME/bin/kafka-topics.sh --bootstrap-server "$BOOTSTRAP_SERVER" --command-config $WORKDIR/client.properties --describe --topic "$T" ;;
#    4) read -p "Topic: " T; $KAFKA_HOME/bin/kafka-console-producer.sh --bootstrap-server "$BOOTSTRAP_SERVER" --producer.config $WORKDIR/client.properties --topic "$T" ;;
#    5) read -p "Topic: " T; $KAFKA_HOME/bin/kafka-console-consumer.sh --bootstrap-server "$BOOTSTRAP_SERVER" --consumer.config $WORKDIR/client.properties --topic "$T" --from-beginning ;;
#    0) exit 0 ;;

  esac
done
