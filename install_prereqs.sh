#!/bin/bash


############################################
############ Beginning the work ############
############################################
source mas-script-functions.bash
source mas.properties

if [[ -z "${domain}" ]]; then 
  echo "Resolving domain through Ingress configuration..."
  domain=$(oc get Ingress.config cluster -o jsonpath='{.spec.domain}')
  echo "Domain is ${domain}"
else
  echo "Domain is preset with ${domain}"
fi


echo "Installing MAS 8.7 pre-reqs"
rm -rf tmp
mkdir tmp


echo "Instantiate Service Bindings Operator (SBO)"
cat << EOF > tmp/sbo.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rh-service-binding-operator
  namespace: openshift-operators
spec:
  channel: stable
  name: rh-service-binding-operator
  source: redhat-operators 
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

oc apply -f tmp/sbo.yaml

while [[ $(oc get ClusterServiceVersion -n openshift-operators --no-headers --ignore-not-found | grep service-binding-operator | awk '{printf $1}') == "" ]];do sleep 1; done & showWorking $!
printf '\b'


operator_name=$(oc get ClusterServiceVersion -n openshift-operators --no-headers --ignore-not-found| grep service-binding-operator | awk '{printf $1}')

echo -n "Operator ready              "
while [[ $(oc get ClusterServiceVersion -n openshift-operators ${operator_name} -o jsonpath="{.status.phase}" --ignore-not-found=true ) != "Succeeded" ]];do sleep 5; done & 
showWorking $!
printf '\b'
echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}"

# installation Behavior Analytics Service
cat << EOF > cr.properties
####Change the values of these properties
projectName=${bas_projectName}
storageClassKafka=${bas_storageClassKafka}
storageClassZookeeper=${bas_storageClassZookeeper}
storageClassDB=${bas_storageClassDB}
storageClassArchive=${bas_storageClassArchive}
dbuser=${bas_dbuser}
dbpassword=${bas_dbpassword}
grafanauser=${bas_grafanauser}
grafanapassword=${bas_grafanapassword}
####Keeping the values of below properties to default is advised.
storageSizeKafka=5G
storageSizeZookeeper=5G
storageSizeDB=10G
storageSizeArchive=10G
eventSchedulerFrequency='*/10 * * * *'
prometheusSchedulerFrequency='@daily'
envType=lite
ibmproxyurl='https://iaps.ibm.com'
airgappedEnabled=false
imagePullSecret=bas-images-pull-secret
EOF
# modify cr.properties file to match your settings
# ATTENTION : dbuser and grafanauser values must be in lowercase with alphanumeric values !!!!
./install_bas.sh


echo "Installation of mongodb"
git clone https://github.com/ibm-watson-iot/iot-docs
#wget https://raw.githubusercontent.com/mongodb/mongodb-kubernetes-operator/v0.6.0/config/rbac/kustomization.yaml -O iot-docs/mongodb/config/rbac/kustomization.yaml
#wget https://raw.githubusercontent.com/mongodb/mongodb-kubernetes-operator/v0.6.0/config/rbac/role.yaml -O iot-docs/mongodb/config/rbac/role.yaml
#wget https://raw.githubusercontent.com/mongodb/mongodb-kubernetes-operator/v0.6.0/config/rbac/role_binding.yaml -O iot-docs/mongodb/config/rbac/role_binding.yaml
#wget https://raw.githubusercontent.com/mongodb/mongodb-kubernetes-operator/v0.6.0/config/rbac/service_account.yaml -O iot-docs/mongodb/config/rbac/service_account.yaml
#wget https://raw.githubusercontent.com/mongodb/mongodb-kubernetes-operator/v0.6.0/config/manager/manager.yaml -O iot-docs/mongodb/config/manager/manager.yaml


export MONGO_NAMESPACE
export MONGO_PASSWORD
export MONGODB_STORAGE_CLASS

cd iot-docs/mongodb/certs/
./generateSelfSignedCert.sh

cd ../
./install-mongo-ce.sh

cd ../../

echo "Enabling IBM catalog and initializing ibm common services"
cat << EOF > tmp/enable_ibm_operator_catalog.yaml

---
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-operator-catalog
  namespace: openshift-marketplace
spec:
  displayName: "IBM Operator Catalog"
  publisher: IBM
  sourceType: grpc
  image: icr.io/cpopen/ibm-operator-catalog:latest
  updateStrategy:
    registryPoll:
      interval: 45m
---
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: opencloud-operators
  namespace: openshift-marketplace
spec:
  displayName: IBMCS Operators
  publisher: IBM
  sourceType: grpc
  image: docker.io/ibmcom/ibm-common-service-catalog:latest
  updateStrategy:
    registryPoll:
      interval: 45m
---
apiVersion: v1
kind: Namespace
metadata:
  name: ibm-common-services
---
apiVersion: operators.coreos.com/v1alpha2
kind: OperatorGroup
metadata:
  name: operatorgroup
  namespace: ibm-common-services
spec:
  targetNamespaces:
  - ibm-common-services
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-common-service-operator
  namespace: ibm-common-services
spec:
  channel: v3
  installPlanApproval: Automatic
  name: ibm-common-service-operator
  source: opencloud-operators
  sourceNamespace: openshift-marketplace
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: odlm-scope
  namespace: ibm-common-services
data:
  namespaces: ibm-common-services
EOF

oc apply -f tmp/enable_ibm_operator_catalog.yaml


oc create secret docker-registry ibm-entitlement-key \
  --docker-username=cp \
  --docker-password=$ER_KEY \
  --docker-server=cp.icr.io \
  --namespace=ibm-common-services


#---
#apiVersion: operators.coreos.com/v1alpha1
#kind: Subscription
#metadata:
#  name: operand-deployment-lifecycle-manager
#  namespace: ibm-common-services
#spec:
#  channel: v3
#  name: ibm-odlm
#  source: ibm-operator-catalog
#  sourceNamespace: openshift-marketplace
#  config:
#    env:
#    - name: INSTALL_SCOPE
#      value: namespaced


echo -n "Operator catalog ready              "
while [[ $(oc get CatalogSource ibm-operator-catalog -n openshift-marketplace -o jsonpath="{.status.connectionState.lastObservedState}" --ignore-not-found=true ) != "READY" ]];do sleep 5; done & 
showWorking $!
printf '\b'
echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}"

echo -n "Common Services ready               "
while [[ $(oc get CommonService common-service -n ibm-common-services -o jsonpath="{.status.phase}"  --ignore-not-found=true ) != "Succeeded" ]];do sleep 5; done & 
showWorking $!
printf '\b'
echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}"

echo "Installation of cert manager"

cat << EOF > tmp/ibm-cert-manager.yaml
apiVersion: operator.ibm.com/v1alpha1
kind: OperandRequest
metadata:
  name: cert-manager-common-service
  namespace: ibm-common-services
  labels:
    app.kubernetes.io/instance: operand-deployment-lifecycle-manager
    app.kubernetes.io/managed-by: operand-deployment-lifecycle-manager
    app.kubernetes.io/name: odlm
spec:
  requests:
    - operands:
        - name: ibm-cert-manager-operator
      registry: common-service

EOF
oc apply -f tmp/ibm-cert-manager.yaml
if [[ -f "./install_webhook.sh" ]]; then
  ./install_webhook.sh ibm-common-services
fi




echo "Installing SLS"
# create a project dedicated for SLS
oc new-project ${slsnamespace}
oc project ${slsnamespace}

echo "Instantiate operator"

cat << EOF > tmp/install_sls.yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ibm-sls
  namespace: ${slsnamespace}
spec:
  targetNamespaces:
    - ${slsnamespace}
EOF
oc create -f tmp/install_sls.yaml

echo "Activate subscription"
cat << EOF > tmp/install_sls_subscription.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-sls
  namespace: ${slsnamespace}
  labels:
    operators.coreos.com/ibm-sls.${slsnamespace}: ''
spec:
  channel: 3.x
  installPlanApproval: Automatic
  name: ibm-sls
  source: ibm-operator-catalog
  sourceNamespace: openshift-marketplace
EOF

oc create -f tmp/install_sls_subscription.yaml

while [[ $(oc get ClusterServiceVersion -n ${slsnamespace} --no-headers | grep ibm-sls | awk '{printf $1}') == "" ]];do sleep 1; done & showWorking $!
printf '\b'

operator_name=$(oc get ClusterServiceVersion -n ${slsnamespace} --no-headers | grep ibm-sls | awk '{printf $1}')
while [[ $(oc get ClusterServiceVersion ${operator_name} -n ${slsnamespace} -o jsonpath="{.status.phase}"  --ignore-not-found=true ) != "Succeeded" ]];do sleep 5; done & 
showWorking $!
printf '\b'
echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}"


echo "Create LicenseService instance"
cat << EOF > tmp/sls_mongo_credentials.yaml
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: sls-mongo-credentials
  namespace: ${slsnamespace}
stringData:
  username: 'admin'
  password: '${MONGO_PASSWORD}'
EOF

oc -n ${slsnamespace} create secret docker-registry ibm-entitlement --docker-server=cp.icr.io --docker-username="cp" --docker-password=${ER_KEY}
oc -n ${slsnamespace} apply -f tmp/sls_mongo_credentials.yaml

# retrieve mongo self signed certificates
mongoCACertificate=$(cat iot-docs/mongodb/certs/ca.pem  | sed 's/^/\ \ \ \ \ \ \ \ \ \ /g')
mongoServerCertificate=$(cat iot-docs/mongodb/certs/server.crt | sed -ne '/BEGIN\ CERTIFICATE/,/END\ CERTIFICATE/p'| sed 's/^/\ \ \ \ \ \ \ \ \ \ /g')

cat << EOF > tmp/sls_instance.yaml
apiVersion: sls.ibm.com/v1
kind: LicenseService
metadata:
  namespace: ${slsnamespace}
  name: sls
  labels:
    app.kubernetes.io/instance: ibm-sls
    app.kubernetes.io/managed-by: olm
    app.kubernetes.io/name: ibm-sls
spec:
  license:
    accept: true
  domain: ${domain}
  mongo:
    configDb: admin
    nodes:
    - host: host1.domain.com
      port: 27017
    secretName: sls-mongo-credentials
    authMechanism: DEFAULT
    retryWrites: true
    certificates:
      - alias: mongoca
        crt: |-
${mongoCACertificate}

EOF

oc apply -f tmp/sls_instance.yaml

while [[ $(oc get LicenseService sls -n ${slsnamespace} -o jsonpath="{.status.conditions[?(@.type=='Ready')].status}"  --ignore-not-found=true) != "True" ]];do sleep 5; done & 
showWorking $!
printf '\b'
echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}"

slsHostId=$(oc -n ${slsnamespace} get LicenseService sls -o jsonpath="{.status.licenseId}")
slsHostName=sls.${slsnamespace}.svc
echo "SLS host is : ${slsHostName}"
echo "SLS id is   : $slsHostId"

if [[ "$OSTYPE" == "darwin"* ]]; then
  curl -Ls -o tmp/phantomjs-2.1.1-macosx.zip https://bitbucket.org/ariya/phantomjs/downloads/phantomjs-2.1.1-macosx.zip
  unzip -j tmp/phantomjs-2.1.1-macosx.zip phantomjs-2.1.1-macosx/bin/phantomjs -d tmp/
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
  curl -Ls -o tmp/phantomjs-2.1.1-linux-x86_64.tar.bz2 https://bitbucket.org/ariya/phantomjs/downloads/phantomjs-2.1.1-linux-x86_64.tar.bz2
  bzip2 -d tmp/phantomjs-2.1.1-linux-x86_64.tar.bz2 
  tar zxf tmp/phantomjs-2.1.1-linux-x86_64.tar --strip-components 2 -C tmp/ phantomjs-2.1.1-linux-x86_64/bin/phantomjs
fi
slslicensefile=$(./tmp/phantomjs fetchlicense.js -u ${slsUserName} -p ${slsPassword} -a ${slsNumberAppPoint} -i ${slsHostId} -n ${slsHostName})
slslicensefile=$(echo $slslicensefile| sed '1d' | sed '$d')

echo "Retrieving ssl configuration"
mkdir -p tmp/ibm-sls
oc get secret -n ${slsnamespace} sls-cert-client -o jsonpath='{.data.tls\.key}' | base64 -d > tmp/ibm-sls/tls.key
oc get secret -n ${slsnamespace} sls-cert-client -o jsonpath='{.data.tls\.crt}' | base64 -d > tmp/ibm-sls/tls.crt
oc get secret -n ${slsnamespace} sls-cert-client -o jsonpath='{.data.ca\.crt}' | base64 -d  > tmp/ibm-sls/ca.crt

echo "Uploading license file"
echo $slslicensefile > tmp/license.dat
slsurl=$(oc get LicenseService sls -o jsonpath='{.status.url}' -n ${slsnamespace})
curl -ik --cert tmp/ibm-sls/tls.crt --key tmp/ibm-sls/tls.key --cacert tmp/ibm-sls/ca.crt -X PUT -F 'file=@tmp/license.dat' ${slsurl}/api/entitlement/file

echo_h2 "[8/] Deploying Kafka for MAS"
oc project "${kafkanamespace}" > /dev/null 2>&1
if [[ "$?" == "1" ]]; then
  oc new-project "${kafkanamespace}" --display-name "MAS Kafka" > /dev/null 2>&1
fi

namespace=$(oc config view --minify -o 'jsonpath={..namespace}')

operator_name=$(oc get ClusterServiceVersion strimzi-cluster-operator.v0.28.1 -n ${namespace} -o jsonpath="{.spec.install.spec.deployments[0].name}" --ignore-not-found)
if [[ -z ${operator_name} ]]; then  # We must deploy operatorgroup, operator and cluster as no strimzi operator in this namespace have been found

echo "  Installing operator"
echo "	Operator will be by default set up to manual on channel 8.x"

cat << EOF > tmp/strimzi_operatorgroup.yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kafka-operatorgroup
  namespace: ${namespace}
spec:
  targetNamespaces:
    - ${namespace}
EOF

oc apply -f tmp/strimzi_operatorgroup.yaml > /dev/null 2>&1
echo "	Operator group created"

cat << EOF > tmp/strimzi_operator.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: strimzi-kafka-operator
  namespace: ${namespace}
spec:
  channel: strimzi-0.28.x
  installPlanApproval: Manual
  name: strimzi-kafka-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
EOF

oc apply -f tmp/strimzi_operator.yaml > /dev/null 2>&1
echo "	Operator created"

while [[ $(oc get Subscription strimzi-kafka-operator -n ${namespace} --ignore-not-found=true -o jsonpath='{.status.state}') != "UpgradePending" ]];do sleep 5; done & 
showWorking $!
printf '\b'

echo "	Approving manual installation"
# Find install plan
installplan=$(oc get subscription strimzi-kafka-operator -o jsonpath="{.status.installplan.name}" -n ${namespace})
echo "	installplan: $installplan"

# Approve install plan
oc patch installplan ${installplan} -n ${namespace} --type merge --patch '{"spec":{"approved":true}}' > /dev/null 2>&1

while [[ $(oc get ClusterServiceVersion -n ${namespace} --no-headers | grep strimzi-cluster-operator | awk '{printf $1}') == "" ]];do sleep 1; done & showWorking $!
printf '\b'

operator_name=$(oc get ClusterServiceVersion strimzi-cluster-operator.v0.28.0 -n ${namespace} -o jsonpath="{.spec.install.spec.deployments[0].name}")


echo -n "	Operator ready              "
while [[ $(oc get deployment/${operator_name} --ignore-not-found=true -o jsonpath='{.status.readyReplicas}' -n ${namespace}) != "1" ]];do sleep 5; done & 
showWorking $!
printf '\b'
echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}"

fi

echo_h2 " Instanciating kafka cluster"

cat << EOF > tmp/kafka_instance.yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  namespace: ${namespace}
  name: ${kafkaclustername}
spec:
  kafka:
    config:
      auto.create.topics.enable: "false"
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
      transaction.state.log.min.isr: 2
      log.message.format.version: '2.7'
      inter.broker.protocol.version: '2.7'
    version: 2.7.0
    authorization:
      type: simple
    storage:
      volumes:
        - id: 0
          size: 100Gi
          deleteClaim: true
          class: ${kafkastorageclass}
          type: persistent-claim
      type: jbod
    replicas: 3
    jvmOptions:
      '-Xms': 3072m
      '-Xmx': 3072m
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
        authentication:
          type: scram-sha-512
      - name: tls
        port: 9093
        type: internal
        tls: true
        authentication:
          type: scram-sha-512
  entityOperator:
    topicOperator: {}
    userOperator: {}
  zookeeper:
    storage:
      class: ${kafkastorageclass}
      deleteClaim: true
      size: 10Gi
      type: persistent-claim
    replicas: 3
    jvmOptions:
      '-Xms': 768m
      '-Xmx': 768m
EOF

oc apply -f tmp/kafka_instance.yaml > /dev/null 2>&1

echo -n "	Kafka ready              "
while [[ $(oc get Kafka ${kafkaclustername} --ignore-not-found=true -o jsonpath="{.status.conditions[?(@.type=='Ready')].status}" -n ${namespace}) != "True" ]];do sleep 5; done & 
showWorking $!
printf '\b'
echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}"