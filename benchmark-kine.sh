#!/usr/bin/env zsh
set -eo pipefail

echoErr() { echo "$@" 1>&2; }

signal_received=0

function cleanup() {
    set +e
    echo "Received signal $1"
    signal_received=1
    kill -9 $KINEPID
    kill -9 $KAPIPID
    kill -9 $KSCHDPID
    kill -9 $PROCMONPID
}

function generate_certs() {
  echo "Generating certificates for the kube-apiserver"

  mkdir -p gen

  # Generate CA cert and key
  openssl genrsa -out gen/ca.key 2048
  openssl req -x509 -new -nodes -key gen/ca.key -subj "/CN=kube-ca" -days 10000 -out gen/ca.crt

  #Generate server cert for kube-apiserver
  openssl genrsa -out gen/apiserver.key 2048
  openssl req -new -key gen/apiserver.key -subj "/CN=kube-apiserver" -out gen/apiserver.csr

  cat > gen/apiserver-ext.cnf <<EOF
[ v3_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = localhost
IP.1 = 127.0.0.1
EOF

  openssl x509 -req -in gen/apiserver.csr -CA gen/ca.crt -CAkey gen/ca.key -CAcreateserial \
    -out gen/apiserver.crt -days 10000 -extensions v3_ext -extfile gen/apiserver-ext.cnf

  #Generate client cert for kubectl

  openssl genrsa -out gen/client.key 2048
  openssl req -new -key gen/client.key -subj "/CN=admin/O=system:masters" -out gen/client.csr

  openssl x509 -req -in gen/client.csr -CA gen/ca.crt -CAkey gen/ca.key -CAcreateserial \
    -out gen/client.crt -days 10000

  #Generate service account key file
  openssl genrsa -out gen/sa.key 2048
}

function generate_kubeconfig() {
  echo "Creating kubeconfig for the cluster"
  kubectl config set-cluster local \
    --certificate-authority=gen/ca.crt \
    --server=https://127.0.0.1:6443 \
    --kubeconfig=gen/kubeconfig \
    --embed-certs=true

  kubectl config set-credentials admin \
    --client-certificate=gen/client.crt \
    --client-key=gen/client.key \
    --kubeconfig=gen/kubeconfig \
    --embed-certs=true

  kubectl config set-context local \
    --cluster=local \
    --user=admin \
    --kubeconfig=gen/kubeconfig
}

if ! command -v kine >/dev/null 2>&1; then
    echo "Err: kine is not installed. Please run the setup.sh script"
    exit 1
fi

if [ ! -x bin/kube-apiserver ]; then
    echo "Err: kube-apiserver binary not found in bin/. Please run the setup.sh script."
    exit 1
fi

if [ ! -x bin/kube-scheduler ]; then
    echo "Err: kube-scheduler binary not found in bin/. Please run the setup.sh script."
    exit 1
fi

rm -rf db/
mkdir db

trap cleanup EXIT INT TERM
echo "Setup signal handler"


echo "Starting kine"
kine > /tmp/kine.log 2>&1 &
KINEPID=$!
echo "Started kine. Logs at /tmp/kine.log"

echo "kine pid is $KINEPID"

echo "waiting for kine to start up"
sleep 5

generate_certs
generate_kubeconfig

echo "Starting kube-apiserver"
#TODO: Get proper IP for advertise-address
bin/kube-apiserver \
--etcd-servers=http://127.0.0.1:2379 \
--client-ca-file=gen/ca.crt \
--tls-cert-file=gen/apiserver.crt \
--tls-private-key-file=gen/apiserver.key \
--authorization-mode=Node,RBAC \
--service-cluster-ip-range=10.0.0.0/24 \
--advertise-address=10.60.68.45 \
--secure-port=6443 \
--service-account-key-file=gen/sa.key \
--service-account-signing-key-file=gen/sa.key \
--service-account-issuer=https://kubernetes.default.svc \
--v=6 > /tmp/kube-apiserver.log 2>&1 &
KAPIPID=$!
echo "Started kube-apiserver. Logs at /tmp/kube-apiserver.log"

echo "waiting for kube-apiserver to start up"
sleep 5

echo "Starting kube-scheduler"
bin/kube-scheduler \
--kubeconfig=gen/kubeconfig \
--leader-elect=false \
--bind-address=127.0.0.1 \
--kube-api-content-type="application/json" \
--secure-port=8090 \
--v=6 > /tmp/kube-scheduler.log 2>&1 &
KSCHDPID=$!
echo "Started kube-scheduler. Logs at /tmp/kube-scheduler.log"

echo "waiting for kube-scheduler to start up"
sleep 5

procmon -d /tmp/10k/kine-cp -interval 5s -n kine-cp kine kube-apiserver kube-scheduler &
PROCMONPID=$!
echo "waiting for procmon to start up"
sleep 12

echo "Starting kubestress"
time kubestress load -k gen/kubeconfig -n 10000 -s a
echo "waiting for cluster to stabilise"
sleep 30

#while [[ $signal_received -eq 0  ]]; do
#  sleep 5
#done


## Load zselect module
#zmodload zsh/zselect
#
## Block until a signal is received
##zselect -s INT $KINEPID
#
## Open dummy file descriptor
#exec 3>/dev/null
#
## zselect stuff
#zselect -s INT USR1 3
#
## Close dummy file descriptor
#exec 3>&-
