#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$my_dir/../common/common.sh"
source "$my_dir/providers/common/common.sh"
source "$my_dir/providers/common/functions.sh"

if [[ "$ENABLE_TLS" == 'local' ]] ; then
  if [[ -z "$SSL_CAKEY" || -z "$SSL_CACERT" ]] ; then
    CA_ROOT_CERT=$WORKSPACE/ca.crt.pem CA_ROOT_KEY=$WORKSPACE/ca.key.pem $my_dir/providers/common/create_ca_certs.sh
    export SSL_CAKEY="$(cat $WORKSPACE/ca.key.pem)"
    export SSL_CACERT="$(cat $WORKSPACE/ca.crt.pem)"
  else
    echo "INFO: skip local CA generation as it is already provided"
  fi
fi

$my_dir/providers/${PROVIDER}/create_env.sh
