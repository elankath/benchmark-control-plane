#!/usr/bin/env zsh
set -eo pipefail

echoErr() { echo "$@" 1>&2; }


helperDir=$(dirname "$(realpath "$0")")
function validateKubeBinariesBuilt() {
  if [ ! -x ./bin/kube-apiserver ]; then
      echo "Err: kube-apiserver binary not found in bin/. Please run the setup.sh script."
      exit 1
  fi

  if [ ! -x ./bin/kube-scheduler ]; then
      echo "Err: kube-scheduler binary not found in bin/. Please run the setup.sh script."
      exit 1
  fi
}

function validateCommandInPath() {
  local cmd
  cmd="$1"
  if [[ -z "$cmd" ]]; then
    echoErr "Err: validateCommandInPath requires non-empty argument" 1
  fi
  if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Err: $cmd is not installed. Please run the setup.sh script"
      exit 1
  fi
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

function downloadObjectsFromCluster() {
  OBJ_DIR="/tmp/${SHOOT}"
  if [[ -d "${OBJ_DIR}" && -n "$(ls -A -- "${OBJ_DIR}" 2>/dev/null)" ]]; then
    echo "⏩ Already entries in $OBJ_DIR. Assuming objects were downloaded in last run."
    return
  fi
  echo "No entries in $OBJ_DIR. Downloading freshly from $LANDSCAPE:$PROJECT:$SHOOT"
  time kcpcl download -d "${OBJ_DIR}" -k "${VIEWER_KUBECONFIG}"
  echo "✅ Downloaded objects into ${OBJ_DIR}"
}
