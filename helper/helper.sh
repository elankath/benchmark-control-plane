#!/usr/bin/env zsh
set -eo pipefail

echoErr() { echo "$@" 1>&2; }


helperDir=$(dirname "$(realpath "$0")")
declare caKeyPath caCrtPath apiServerKeyPath apiServerCsrPath apiServerCnfPath apiServerCrtPath clientKeyPath clientCsrPath clientCrtPath saKeyPath kubeconfig
function validateKubeBinariesBuilt() {
  if [ ! -x "$helperDir/../bin/kube-apiserver" ]; then
      echo "Err: kube-apiserver binary not found in bin/. Please run the setup.sh script."
      exit 1
  fi

  if [ ! -x "$helperDir/../bin/kube-scheduler" ]; then
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
  caKeyPath="$helperDir/../gen/ca.key"
  caCrtPath="$helperDir/../gen/ca.crt"
  openssl genrsa -out "$caKeyPath" 2048
  openssl req -x509 -new -nodes -key "$caKeyPath" -subj "/CN=kube-ca" -days 10000 -out "$caCrtPath"

  #Generate server cert for kube-apiserver
  apiServerKeyPath="${helperDir}/../gen/apiserver.key"
  apiServerCsrPath="${helperDir}/../gen/apiserver.csr"
  echo "Generating apiserver key at ${apiServerKeyPath}"
  openssl genrsa -out "${apiServerKeyPath}" 2048
  echo "Generating apiserver csr at ${apiServerCsrPath}"
  openssl req -new -key "$apiServerKeyPath" -subj "/CN=kube-apiserver" -out "$apiServerCsrPath"

apiServerCnfPath="${helperDir}/../gen/apiserver-ext.cfn"
  cat > "${apiServerCnfPath}" <<EOF
[ v3_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = localhost
IP.1 = 127.0.0.1
EOF

  apiServerCrtPath="${helperDir}/../gen/apiserver.crt"
  openssl x509 -req -in "$apiServerCsrPath"  -CA "$caCrtPath"  -CAkey "$caKeyPath"  -CAcreateserial \
    -out  "$apiServerCrtPath" -days 10000 -extensions v3_ext -extfile "$apiServerCnfPath"

  #Generate client cert for kubectl

  clientKeyPath="$helperDir/../gen/client.key"
  clientCsrPath="$helperDir/../gen/client.csr"
  openssl genrsa -out "$clientKeyPath" 2048
  openssl req -new -key "$clientKeyPath" -subj "/CN=admin/O=system:masters" -out "$clientCsrPath"

  clientCrtPath="$helperDir/../gen/client.crt"
  openssl x509 -req -in "$clientCsrPath" -CA "$caCrtPath"  -CAkey "$caKeyPath"  -CAcreateserial \
    -out "$clientCrtPath" -days 10000

  saKeyPath="$helperDir/../gen/sa.key"
  #Generate service account key file
  openssl genrsa -out  "$saKeyPath" 2048
}

function generate_kubeconfig() {
  echo "Creating kubeconfig for the cluster"
  kubeconfig="${helperDir}/../gen/kubeconfig"
  kubectl config set-cluster local \
    --certificate-authority="$caCrtPath" \
    --server=https://127.0.0.1:6443 \
    --kubeconfig="$kubeconfig" \
    --embed-certs=true

  kubectl config set-credentials admin \
    --client-certificate="$clientCrtPath" \
    --client-key="$clientKeyPath"  \
    --kubeconfig="$kubeconfig" \
    --embed-certs=true

  kubectl config set-context local \
    --cluster=local \
    --user=admin \
    --kubeconfig="$kubeconfig"
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
