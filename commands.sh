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
export USE_CUSTOMER_PROVIDED_CERTIFICATE=`az vm list | jq -r '.[0].tags.usePrivateCertificate'`
export KEYVAULT_NAME=`az vm list | jq -r '.[0].tags.keyVaultName'`

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
retry helm repo add prophecy http://simpledatalabsinc.github.io/prophecy
retry helm repo add elastic https://helm.elastic.co

if [ ${USE_CUSTOMER_PROVIDED_CERTIFICATE} == "False" ]; then
  eval "echo \"$(cat azure-dns-secret-tpl.yaml)\"" > azure-dns-secret.yaml
  eval "echo \"$(cat external-dns-tpl.yaml )\"" > azure-external-dns.yaml
  eval "echo \"$(cat wildcard-cluster-issuer-tpl.yaml )\"" > wildcard-cluster-issuer.yaml
  eval "echo \"$(cat wildcard-certificate-tpl.yaml)\"" >  wildcard-certificate.yaml
fi


retry helm repo add jetstack https://charts.jetstack.io
retry helm repo update

if [ ${USE_CUSTOMER_PROVIDED_CERTIFICATE} == "False" ]; then
  retry helm upgrade -i nginx-ingress stable/nginx-ingress -f values_nginx.yaml --version 1.37.0
  retry helm upgrade -i secret-replicator kiwigrid/secret-replicator --version 0.5.0 --set secretList=prophecy-wildcard-tls-secret
else
  retry helm upgrade -i nginx-ingress stable/nginx-ingress --version 1.37.0 -f values_nginx.yaml --set  controller.service.loadBalancerIP=${LOADBALANCER_IP}  --set controller.service.type=LoadBalancer
fi
retry helm upgrade -i elasticsearch elastic/elasticsearch --namespace elastic --create-namespace
retry helm upgrade -i kibana elastic/kibana --namespace elastic --create-namespace

if [ ${USE_CUSTOMER_PROVIDED_CERTIFICATE} == "False" ]; then
  retry helm upgrade -i cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --version v1.7.0-alpha.0 --set installCRDs=true --set prometheus.enabled=false --set extraArgs={--dns01-recursive-nameservers-only}
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
kubectl create ns dp


if [ ${USE_CUSTOMER_PROVIDED_CERTIFICATE} == "True" ]; then
  kubectl create secret tls prophecy-wildcard-tls-secret -n cp --cert=tls.crt --key=tls.key
  kubectl create secret tls prophecy-wildcard-tls-secret -n dp --cert=tls.crt --key=tls.key
fi

eval "echo \"$(cat image-pull-secret-tpl.yaml)\"" > image-pull-secret.yaml
retry kubectl apply -f image-pull-secret.yaml -n cp
retry kubectl apply -f image-pull-secret.yaml -n dp

eval "echo \"$(cat values_cp_tpl.yaml )\"" > values_cp.yaml
eval "echo \"$(cat values_dp_tpl.yaml )\"" > values_dp.yaml

retry helm upgrade -i cp prophecy/prophecy --version 0.0.1000 -f values_cp.yaml -n cp
retry helm upgrade -i dp prophecy/prophecy-dataplane --version 0.0.1000 -f values_dp.yaml -n dp


retry helm upgrade -i -n cp athena prophecy/athena --version 0.1.0 --set athena.adminPassword=`echo ${ADMIN_PASSWORD}` --set prophecy.rootUrl=`echo prophecy.${ROOT_URL}` --set prophecy.wildcardCertName=prophecy-wildcard-tls-secret

retry helm upgrade -i -n cp backup prophecy/prophecy-backup --version 0.0.1 --set backup.pvc.create=true

retry helm upgrade -i -n dp backup prophecy/prophecy-backup --version 0.0.1 --set backup.pvc.create=true

