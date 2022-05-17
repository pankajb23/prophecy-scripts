#!/bin/bash -x

function fail {
  echo $1 >&2
  exit 1
}

function retry {
  local n=1
  local max=5
  local delay=5
  while true; do
    "$@" && break || {
      if [[ $n -lt $max ]]; then
        ((n++))
        echo "Command failed. Attempt $n/$max:"
        sleep $delay;
      else
        fail "The command has failed after $n attempts."
      fi
    }
  done
}

# login to az cli using managed identity

retry az login --identity

export ADMIN_PASSWORD=`az vm list | jq -r '.[0].tags.secret'`
export CLUSTERNAME=`az vm list | jq -r '.[0].tags.clusterName'`
export CLUSTERGROUP=`az vm list | jq -r '.[0].tags.resourceGroup'`
export CUSTOMER_NAME=`az vm list | jq -r '.[0].tags.clusterName'`
export INITIAL_USER_COUNT=`az vm list | jq -r '.[0].tags.userCount'`
export USE_CUSTOMER_PROVIDED_CERTIFICATE=`az vm list | jq -r '.[0].tags.usePrivateCertificate'`
export KEYVAULT_NAME=`az vm list | jq -r '.[0].tags.keyVaultName'`

# TODO remove hard-coding once we remove 499 plan
export INITIAL_USER_COUNT="10"
if [ ${INITIAL_USER_COUNT} == "" ]; then
  export INITIAL_USER_COUNT="10"
fi

if [ ${USE_CUSTOMER_PROVIDED_CERTIFICATE} == "True" ]; then
  retry az keyvault secret show --vault-name ${KEYVAULT_NAME} --name TLSKey | jq -r .value > /etc/marketplace/tls.key
  retry az keyvault secret show --vault-name ${KEYVAULT_NAME} --name TLSCertificate | jq -r .value > /etc/marketplace/tls.crt
  export LOADBALANCER_IP=`az vm list | jq -r '.[0].tags.loadbalancerIP'`
  export ROOT_URL=`az keyvault secret show --vault-name ${KEYVAULT_NAME} --name RootURL | jq -r .value`
else
  export ROOT_URL=${CUSTOMER_NAME}.cloud.prophecy.io
fi

# get kubernetes credentials
retry az aks get-credentials --name $CLUSTERNAME --resource-group $CLUSTERGROUP

cd /etc/marketplace
source secrets.sh

retry helm repo add stable https://charts.helm.sh/stable
retry helm repo add kiwigrid https://kiwigrid.github.io
retry helm repo add elastic https://helm.elastic.co
retry helm repo add grafana https://grafana.github.io/helm-charts
retry helm repo add prometheus-community https://prometheus-community.github.io/helm-charts

if [ ${USE_CUSTOMER_PROVIDED_CERTIFICATE} == "False" ]; then
  eval "echo \"$(cat azure-dns-secret-tpl.yaml)\"" > azure-dns-secret.yaml
  eval "echo \"$(cat external-dns-tpl.yaml )\"" > azure-external-dns.yaml
  eval "echo \"$(cat wildcard-cluster-issuer-tpl.yaml )\"" > wildcard-cluster-issuer.yaml
  eval "echo \"$(cat wildcard-certificate-tpl.yaml)\"" >  wildcard-certificate.yaml
fi


retry helm repo add jetstack https://charts.jetstack.io
retry helm repo update

if [ ${USE_CUSTOMER_PROVIDED_CERTIFICATE} == "False" ]; then
  retry helm upgrade -i nginx-ingress stable/nginx-ingress -f values_nginx.yaml --version 1.37.0 --force
  retry helm upgrade -i secret-replicator kiwigrid/secret-replicator --version 0.5.0 --set secretList=prophecy-wildcard-tls-secret --force
else
  retry helm upgrade -i nginx-ingress stable/nginx-ingress --version 1.37.0 -f values_nginx.yaml --set  controller.service.loadBalancerIP=${LOADBALANCER_IP}  --set controller.service.type=LoadBalancer --force
fi
retry helm upgrade -i elasticsearch elastic/elasticsearch --namespace elastic --create-namespace --force
retry helm upgrade -i kibana elastic/kibana --namespace elastic --create-namespace --force

if [ ${USE_CUSTOMER_PROVIDED_CERTIFICATE} == "False" ]; then
  retry helm upgrade -i cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --version v1.7.0-alpha.0 --set installCRDs=true --set prometheus.enabled=false --set extraArgs={--dns01-recursive-nameservers-only} --force
  retry kubectl apply -f cluster-issuer.yaml
  retry kubectl apply -f azure-dns-secret.yaml
  retry kubectl apply -f azure-dns-secret.yaml -n cert-manager
  retry kubectl apply -f azure-external-dns.yaml
  retry kubectl apply -f wildcard-cluster-issuer.yaml
  retry kubectl apply -f wildcard-certificate.yaml

  cat << EOF > /etc/marketplace/external-dns.patch
rules:
- apiGroups: ['']
  resources: ["services","endpoints","pods"]
  verbs: ["get","watch","list"]
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get","watch","list"]
- apiGroups: ['']
  resources: ["nodes"]
  verbs: ["list", "watch"]
EOF

  retry kubectl patch clusterrole external-dns --patch-file /etc/marketplace/external-dns.patch
fi

# not adding retry here as create will fail on retry. cannot apply due to CRD size restriction.
kubectl create -f `pwd`/crds

kubectl create ns cp
kubectl label namespace cp owner=prophecy
kubectl create ns dp
kubectl label namespace dp owner=prophecy

kubectl create namespace platform
kubectl label namespace platform owner=prophecy

cat << EOF > /etc/marketplace/values_prometheus.yaml
prometheus:
  prometheusSpec:
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: default
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi
    serviceMonitorSelector: {}
    serviceMonitorNamespaceSelector:
      matchLabels:
        owner: prophecy
EOF

retry helm upgrade -i prometheus prometheus-community/kube-prometheus-stack -n platform -f /etc/marketplace/values_prometheus.yaml --force

# Installing metrics-server
retry kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.6.0/components.yaml

retry helm upgrade -i loki grafana/loki-stack -n platform --set loki.persistence.enabled=true,loki.persistence.storageClassName=default,loki.persistence.size=200Gi --force

if [ ${USE_CUSTOMER_PROVIDED_CERTIFICATE} == "True" ]; then
  kubectl create secret tls prophecy-wildcard-tls-secret -n cp --cert=tls.crt --key=tls.key
  kubectl create secret tls prophecy-wildcard-tls-secret -n dp --cert=tls.crt --key=tls.key
fi

eval "echo \"$(cat image-pull-secret-tpl.yaml)\"" > image-pull-secret.yaml
retry kubectl apply -f image-pull-secret.yaml -n cp
retry kubectl apply -f image-pull-secret.yaml -n dp

eval "echo \"$(cat values_cp_tpl.yaml )\"" > values_cp.yaml
eval "echo \"$(cat values_dp_tpl.yaml )\"" > values_dp.yaml

# Updating env logic
TOTAL_LINES=`wc -l values_cp.yaml | awk '{print $1}'`
head -n 60 values_cp.yaml > values_cp_temp.yaml
echo "    SMTP_ENABLED: \"false\"" >> values_cp_temp.yaml
echo "    METERING_ENABLED: \"true\"" >> values_cp_temp.yaml
echo "    MIXPANEL_ENABLED: \"true\"" >> values_cp_temp.yaml
echo "    SEARCH_ENABLED: \"true\"" >> values_cp_temp.yaml
echo "    ENABLE_SEARCH_BOOTSTRAP: \"true\"" >> values_cp_temp.yaml
tail -n $(($TOTAL_LINES - 60)) values_cp.yaml >> values_cp_temp.yaml
mv values_cp_temp.yaml values_cp.yaml
# Updating env logic

retry curl -o prophecy-0.14.8.tgz https://prophecy-charts.s3.us-west-2.amazonaws.com/stable/prophecy-0.14.8.tgz
retry curl -o prophecy-dataplane-0.14.8.tgz https://prophecy-charts.s3.us-west-2.amazonaws.com/stable/prophecy-dataplane-0.14.8.tgz
retry curl -o athena-0.1.0.tgz https://prophecy-charts.s3.us-west-2.amazonaws.com/stable/athena-0.1.0.tgz
retry curl -o prophecy-backup-0.0.1.tgz https://prophecy-charts.s3.us-west-2.amazonaws.com/stable/prophecy-backup-0.0.1.tgz

retry helm upgrade -i cp ./prophecy-0.14.8.tgz -f values_cp.yaml -n cp --set prophecy.enablePathBasedRouting=true --set monitoring.enabled=true --force
retry helm upgrade -i dp ./prophecy-dataplane-0.14.8.tgz -f values_dp.yaml -n dp --set dataplane.enablePathBasedRouting=true --set monitoring.enabled=true --force


retry helm upgrade -i -n cp athena ./athena-0.1.0.tgz --set athena.tag=0.14.7 --set prophecy.userCount=`echo ${INITIAL_USER_COUNT}` --set athena.adminPassword=`echo ${ADMIN_PASSWORD}` --set prophecy.rootUrl=`echo prophecy.${ROOT_URL}` --set prophecy.wildcardCertName=prophecy-wildcard-tls-secret --force

retry helm upgrade -i -n cp backup ./prophecy-backup-0.0.1.tgz --set backup.pvc.create=true --force

retry helm upgrade -i -n dp backup ./prophecy-backup-0.0.1.tgz --set backup.pvc.create=true --force

# retry helm upgrade -i federator prophecy/openidfederator --version 1.16.0 -n openidfederator

kubectl label servicemonitor cp-metrics -n cp release=prometheus

kubectl label servicemonitor dp-metrics -n dp release=prometheus
