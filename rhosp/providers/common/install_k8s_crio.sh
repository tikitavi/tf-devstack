#!/bin/bash -xe

#https://swapnasagarpradhan.medium.com/install-a-kubernetes-cluster-on-rhel8-with-conatinerd-b48b9257877a
#https://thenewstack.io/how-to-install-a-kubernetes-cluster-on-red-hat-centos-8/

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source $my_dir/functions.sh

cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# Setup required sysctl params, these persist across reboots.
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sudo sysctl --system

sudo subscription-manager release --set=8.2

if [ ! -e /etc/yum.repos.d/kubernetes.repo ] ; then
  K8S_REPO=${K8S_REPO:-"https://packages.cloud.google.com/yum/repos/kubernetes-el7-x86_64"}
  K8S_REPO_GPG=${K8S_REPO_GPG-"https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg"}
  gpgcheck=1
  if [ -z "$K8S_REPO_GPG" ] ; then
    gpgcheck=0
  fi
  cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=$K8S_REPO
enabled=1
gpgcheck=$gpgcheck
repo_gpgcheck=$gpgcheck
gpgkey=$K8S_REPO_GPG
EOF
fi

K8S_VERSION=${K8S_VERSION:-'1.18.10'}
CRIO_VERSION=${CRIO_VERSION:-'1.18'}
OS='CentOS_8'
sudo curl -L -o /etc/yum.repos.d/devel:kubic:libcontainers:stable.repo \
  https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$OS/devel:kubic:libcontainers:stable.repo
sudo curl -L -o /etc/yum.repos.d/devel:kubic:libcontainers:stable:cri-o:$CRIO_VERSION.repo \
  https://download.opensuse.org/repositories/devel:kubic:libcontainers:stable:cri-o:$CRIO_VERSION/$OS/devel:kubic:libcontainers:stable:cri-o:$CRIO_VERSION.repo

sudo yum module -y install container-tools
sudo yum install -y kubeadm-$K8S_VERSION kubelet-$K8S_VERSION kubectl-$K8S_VERSION cri-o


sudo mkdir -p /etc/crio/crio.conf.d
cat <<EOF | sudo tee /etc/crio/crio.conf.d/02-cgroup-manager.conf
[crio.runtime]
conmon_cgroup = "pod"
cgroup_manager = "cgroupfs"
EOF

# to avoid bridged cni from crio which is installed by default
cat <<EOF | sudo tee /etc/crio/crio.conf.d/02-cni.conf
[crio.network]
cni_default_network = "10-tf-cni"
network_dir = "/etc/cni/net.d/"
EOF

if [ -n "$CONTAINER_REGISTRY" ] || [ -n "$DEPLOYER_CONTAINER_REGISTRY" ] ; then
  echo "[crio.image]" | sudo tee /etc/crio/crio.conf.d/02-insecure-registries.conf
  insecure_registries="["
  add_comma=""
  registry=$(echo $CONTAINER_REGISTRY | cut -d '/' -f 1)
  if [ -n "$registry" ] && is_registry_insecure $registry ; then
    insecure_registries+=" '$registry' "
    add_comma=","
  fi
  insecure_registries+=$add_comma
  registry=$(echo $DEPLOYER_CONTAINER_REGISTRY | cut -d '/' -f 1)
  if [ -n "$registry" ] && is_registry_insecure $registry ; then
    insecure_registries+=" '$registry' "
  fi
  insecure_registries+="]"
cat <<EOF | sudo tee /etc/crio/crio.conf.d/02-insecure-registries.conf
[crio.image]
insecure_registries = $insecure_registries
EOF
fi

sudo systemctl daemon-reload
sudo systemctl enable --now crio 
echo 'KUBELET_EXTRA_ARGS="--fail-swap-on=false"' | sudo tee /etc/sysconfig/kubelet
# Create default /var/lib/kubelet/config.yaml which may be missing after fresh install
# and kubelet fails to start
if [ ! -e /var/lib/kubelet/config.yaml ] ; then
  sudo kubeadm init phase kubelet-start
fi
sudo systemctl enable --now kubelet


function rand() {
  tr -dc a-z0-9 </dev/urandom | head -c $1
}

K8S_API_ADDRESS=${K8S_API_ADDRESS:-}

opts=''
if [ -z "$K8S_JOIN_TOKEN" ] ; then
  # create new cluster
  opts+='init'
  K8S_API_NETWORK=${K8S_API_NETWORK:-}
  if [ -n "$K8S_API_NETWORK" ] || [ -n "$K8S_API_ADDRESS" ] ; then
    api_addr="$K8S_API_ADDRESS"
    if [ -z "$api_addr" ] ; then
      api_addr=$(ip a | grep -o "inet $K8S_API_NETWORK " | awk '{print($2)}' | cut -d '/' -f 1)
    fi
    if [ -z "$api_addr" ] ; then
      echo "ERROR: no IP configured in network $K8S_API_NETWORK"
      exit 1
    fi
    opts+=" --apiserver-advertise-address ${api_addr//\/.*/}"
  fi
  token=${K8S_INIT_TOKEN:-}
  if [ -z "$token" ] ; then
    token="$(rand 6).$(rand 16)"
    echo "INFO: token to create cluster $token"
  fi
  opts+=" --token $token"

else
  # join existing cluter
  if [ -z "$K8S_API_ADDRESS" ] ; then
      echo "ERROR: K8S_API_ADDRESS must be set for join command"
      exit 1
  fi
  opts+="join $K8S_API_ADDRESS --token $K8S_JOIN_TOKEN"
  if [ -n "$K8S_DISCOVERY_TOKEN_CA_CERT_HASH" ] ; then
    opts+=" --discovery-token-ca-cert-hash $K8S_DISCOVERY_TOKEN_CA_CERT_HASH"
  fi
fi

domain=${K8S_DOMAIN-'auto'}
if [ -n "$domain" ] ; then
  if [[ "$domain" == 'auto' ]] ; then
    domain=$(hostname -d)
  fi
  opts+=" --service-dns-domain $domain"
fi

sudo kubeadm $opts

mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
