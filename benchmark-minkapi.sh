#!/usr/bin/env zsh
set -eo pipefail

echoErr() { echo "$@" 1>&2; }

signal_received=0

function cleanup() {
    set +e
    echo "Received signal $1"
    signal_received=1
    kill -9 $MINKAPIPID
    kill -9 $KSCHDPID
    kill -9 $PROCMONPID
}

if ! command -v minkapi; then
    echo "Err: minkapi not found in PATH. Please run the setup.sh script."
    exit 1
fi

if [ ! -x bin/kube-scheduler ]; then
    echo "Err: kube-scheduler binary not found in bin/. Please run the setup.sh script."
    exit 1
fi

trap cleanup EXIT INT TERM
echo "Setup signal handler"


echo "Starting minkapi"
minkapi > /tmp/minkapi.log 2>&1 &
MINKAPIPID=$!
echo "Started minkapi. Logs at /tmp/minkapi.log"
echo "minkapi pid is $MINKAPIPID"

echo "waiting for minkapi to start up"
sleep 2


echo "Starting kube-scheduler"
bin/kube-scheduler \
--kubeconfig=/tmp/minkapi.yaml \
--leader-elect=false \
--bind-address=127.0.0.1 \
--kube-api-content-type="application/json" \
--secure-port=8090 \
--v=6 > /tmp/kube-scheduler.log 2>&1 &
KSCHDPID=$!
echo "Started kube-scheduler. Logs at /tmp/kube-scheduler.log"
echo "kube-scheduler pid is $KSCHDPID"

echo "waiting for kube-scheduler to start up"
sleep 5

procmon -d /tmp/10k/minkapi-cp -interval 5s -n minkapi-cp minkapi kube-scheduler &
PROCMONPID=$!
echo "waiting for procmon to start up"
echo "procmon pid is $PROCMONPID"
sleep 12

echo "Starting kubestress"
time kubestress load -k /tmp/minkapi.yaml -n 10000 -s a
echo "waiting for cluster to stabilise"
sleep 30

#while [[ $signal_received -eq 0  ]]; do
#  sleep 5
#done


## Load zselect module
#zmodload zsh/zselect
#
## Block until a signal is received
##zselect -s INT $MINKAPIPID
#
## Open dummy file descriptor
#exec 3>/dev/null
#
## zselect stuff
#zselect -s INT USR1 3
#
## Close dummy file descriptor
#exec 3>&-
