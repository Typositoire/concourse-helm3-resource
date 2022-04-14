#!/bin/bash
set -e

if [ -f "$source/$namespace_overwrite" ]; then
  namespace=$(cat $source/$namespace_overwrite)
elif [ -n "$namespace_overwrite" ]; then
  namespace=$namespace
fi

setup_kubernetes() {
  payload=$1
  source=$2

  mkdir -p /root/.kube
  kubeconfig_path=$(jq -r '.params.kubeconfig_path // ""' < $payload)
  absolute_kubeconfig_path="${source}/${kubeconfig_path}"
  kubeconfig=$(jq -r '.params.kubeconfig // ""' < $payload)
  if [ ! -z "$kubeconfig" ]; then
    echo "$kubeconfig" > /root/.kube/config
    chmod 600 /root/.kube/config
  elif [ -f "$absolute_kubeconfig_path" ]; then
    cp "$absolute_kubeconfig_path" "/root/.kube/config"
  else
    # Setup kubectl
    cluster_url=$(jq -r '.source.cluster_url // ""' < $payload)
    if [ -z "$cluster_url" ]; then
      echo "invalid payload (missing cluster_url)"
      exit 1
    fi
    if [[ "$cluster_url" =~ https.* ]]; then
      insecure_cluster=$(jq -r '.source.insecure_cluster // "false"' < $payload)
      cluster_ca=$(jq -r '.source.cluster_ca // ""' < $payload)
      admin_key=$(jq -r '.source.admin_key // ""' < $payload)
      admin_cert=$(jq -r '.source.admin_cert // ""' < $payload)
      token=$(jq -r '.source.token // ""' < $payload)
      token_path=$(jq -r '.params.token_path // ""' < $payload)

      if [ "$insecure_cluster" == "true" ]; then
        kubectl config set-cluster default --server=$cluster_url --insecure-skip-tls-verify=true
      else
        ca_path="/root/.kube/ca.pem"
        if ! echo "$cluster_ca" | base64 -d > $ca_path; then
          echo "info: assuming unencoded cluster CA cert" >/dev/stderr
          echo "$cluster_ca" > $ca_path
        fi
        kubectl config set-cluster default --server=$cluster_url --certificate-authority=$ca_path
      fi

      if [ -f "$source/$token_path" ]; then
        kubectl config set-credentials admin --token=$(cat $source/$token_path)
      elif [ ! -z "$token" ]; then
        kubectl config set-credentials admin --token=$token
      else
        mkdir -p /root/.kube
        key_path="/root/.kube/key.pem"
        cert_path="/root/.kube/cert.pem"
        echo "$admin_key" | base64 -d > $key_path
        echo "$admin_cert" | base64 -d > $cert_path
        kubectl config set-credentials admin --client-certificate=$cert_path --client-key=$key_path
      fi

      kubectl config set-context default --cluster=default --user=admin
    else
      kubectl config set-cluster default --server=$cluster_url
      kubectl config set-context default --cluster=default
    fi

    kubectl config use-context default
  fi

  kubectl version
}

setup_gcp_kubernetes() {
  payload=$1
  source=$2

  gcloud_service_account_key_file=$(jq -r '.source.gcloud_service_account_key_file // ""' < $payload)
  gcloud_workload_identity_enabled=$(jq -r '.source.gcloud_workload_identity_enabled // "false"' < $payload)
  gcloud_project_name=$(jq -r '.source.gcloud_project_name // ""' < $payload)
  gcloud_k8s_cluster_name=$(jq -r '.source.gcloud_k8s_cluster_name // ""' < $payload)
  gcloud_k8s_zone=$(jq -r '.source.gcloud_k8s_zone // ""' < $payload)

  if [ -z "$gcloud_project_name" ] || [ -z "$gcloud_k8s_cluster_name" ] || [ -z "$gcloud_k8s_zone" ]; then
    echo "invalid payload for gcloud auth, please pass all required params"
    exit 1
  fi

  if [ "$gcloud_workload_identity_enabled" == "false" ]; then
    if [ -z "$gcloud_service_account_key_file" ]; then
      echo "invalid payload for gcloud auth, please pass all required params"
      exit 1
    fi

    if [[ -f $gcloud_service_account_key_file ]]; then
      echo "service acccount $gcloud_service_account_key_file is passed as a file"
      gcloud_path="$gcloud_service_account_key_file"
    else
      echo "$gcloud_service_account_key_file" >> /gcloud.json
      gcloud_path="/gcloud.json"
    fi
    
    gcloud_service_account_name=($(cat $gcloud_path | jq -r ".client_email"))
    gcloud auth activate-service-account ${gcloud_service_account_name} --key-file $gcloud_path
    gcloud config set account ${gcloud_service_account_name}
  else
      echo "Workload Identity is enabled - no need to authenticate with a private key"
  fi
  
  gcloud config set project ${gcloud_project_name}
  gcloud container clusters get-credentials ${gcloud_k8s_cluster_name} --zone ${gcloud_k8s_zone}

}

setup_helm() {
  # $1 is the name of the payload file
  # $2 is the name of the source directory


  history_max=$(jq -r '.source.helm_history_max // "0"' < $1)

  helm_bin="helm"

  $helm_bin version

  helm_setup_purge_all=$(jq -r '.source.helm_setup_purge_all // "false"' <$1)
  if [ "$helm_setup_purge_all" = "true" ]; then
    local release
    for release in $(helm ls -aq --namespace $namespace )
    do
      helm uninstall "$release" --namespace $namespace
    done
  fi
}

wait_for_service_up() {
  SERVICE=$1
  TIMEOUT=$2
  if [ "$TIMEOUT" -le "0" ]; then
    echo "Service $SERVICE was not ready in time"
    exit 1
  fi
  RESULT=`kubectl get endpoints --namespace=$namespace $SERVICE -o jsonpath={.subsets[].addresses[].targetRef.name} 2> /dev/null || true`
  if [ -z "$RESULT" ]; then
    sleep 1
    wait_for_service_up $SERVICE $((--TIMEOUT))
  fi
}

setup_repos() {
  repos=$(jq -c '(try .source.repos[] catch [][])' < $1)
  plugins=$(jq -c '(try .source.plugins[] catch [][])' < $1)
  stable_repo=$(jq -r '.source.stable_repo // "https://charts.helm.sh/stable"' < $1 )

  local IFS=$'\n'

  if [ "$plugins" ]
  then
    for pl in $plugins; do
      plurl=$(echo $pl | jq -cr '.url')
      plversion=$(echo $pl | jq -cr '.version // ""')
      if [ -n "$plversion" ]; then
        $helm_bin plugin install $plurl --version $plversion
      else
        if [ -d $2/$plurl ]; then
          $helm_bin plugin install $2/$plurl
        else
          $helm_bin plugin install $plurl
        fi
      fi
    done
  fi

  if [ "$repos" ]
  then
    for r in $repos; do
      name=$(echo $r | jq -r '.name')
      url=$(echo $r | jq -r '.url')
      username=$(echo $r | jq -r '.username // ""')
      password=$(echo $r | jq -r '.password // ""')

      echo Installing helm repository $name $url
      if [[ -n "$username" && -n "$password" ]]; then
        $helm_bin repo add $name $url --username $username --password $password
      else
        $helm_bin repo add $name $url
      fi
    done

    $helm_bin repo update
  fi

  if [ ! "$stable_repo" == "false" ]; then
    $helm_bin repo add stable $stable_repo
    $helm_bin repo update
  fi
}

setup_resource() {
  tracing_enabled=$(jq -r '.source.tracing_enabled // "false"' < $1)
  if [ "$tracing_enabled" = "true" ]; then
    set -x
  fi

  digitalocean=$(jq -r '.source.digitalocean // "false"' < $1)
  do_cluster_id=$(jq -r '.source.digitalocean.cluster_id // "false"' < $1)
  do_access_token=$(jq -r '.source.digitalocean.access_token // "false"' < $1)
  gcloud_cluster_auth=$(jq -r '.source.gcloud_cluster_auth // "false"' < $1)

  if [ "$do_cluster_id" != "false" ] && [ "$do_access_token" != "false" ]; then
    echo "Initializing digitalocean..."
    setup_doctl $1 $2
  elif [ "$gcloud_cluster_auth" = "true" ]; then
    echo "Initializing kubectl access using gcloud service account file"
    setup_gcp_kubernetes $1 $2
  else
    echo "Initializing kubectl using certificates"
    setup_kubernetes $1 $2
  fi

  echo "Initializing helm..."
  setup_helm $1 $2
}

setup_doctl() {
  doctl_token=$(jq -r '.source.digitalocean.access_token // ""' < $payload)
  doctl_cluster_id=$(jq -r '.source.digitalocean.cluster_id // ""' < $payload)
  doctl auth init -t $doctl_token

  doctl kubernetes cluster kubeconfig save $doctl_cluster_id
}
