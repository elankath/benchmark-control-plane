#!/usr/bin/env zsh
set -eo pipefail

echoErr() { echo "$@" 1>&2; }


go install -buildvcs=true github.com/k3s-io/kine@latest
go install -buildvcs=true github.com/elankath/procmon@v0.1.0
go install -buildvcs=true github.com/elankath/kubestress@v0.1.4
go install -buildvcs=true github.com/elankath/minkapi@v0.1.8
go install -buildvcs=true github.com/elankath/kcpcl@v0.1.8

KSRC="$HOME/go/src/k8s.io/kubernetes/"
PROJ_DIR=$(dirname "$(realpath "$0")")
BIN_KAPI="$PROJ_DIR/bin/kube-apiserver"
BIN_KSCHD="$PROJ_DIR/bin/kube-scheduler"


if [[ ! -d "$KSRC" ]]; then
  echoErr "Err: kubernetes sources should be present at $KSRC"
  exit 1
fi

mkdir -p bin
echo "$PROJ_DIR"
echo "Building kube-apiserver into $BIN_KAPI"
go build -C "$KSRC" -o "$BIN_KAPI" cmd/kube-apiserver/apiserver.go

echo "Building kube-scheduler into $BIN_KSCHD"
go build -C "$KSRC" -o "$BIN_KSCHD" cmd/kube-scheduler/scheduler.go
