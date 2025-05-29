#!/usr/bin/env zsh
set -eo pipefail

declare SCRIPT_DIR GEN_DIR SHOOT PROJECT LANDSCAPE STABILIZE_SECS OBJ_DIR SOURCE_CLUSTER_NAME VIEWER_KUBECONFIG SCHEDULER_CONFIG DEST_KUBECONFIG
# Get the script's directory
SCRIPT_DIR=$(dirname "$(realpath "$0")")
GEN_DIR="${SCRIPT_DIR}/gen"

source "$SCRIPT_DIR/helper/helper.sh"


function cleanup() {
    set +e
    signal_received=1
    kill -9 $KAPIPID 2> /dev/null
    kill -9 $KSCHDPID 2> /dev/null
    kill -9 $PROCMONPID 2> /dev/null
    kill -9 $MINKAPIPID 2> /dev/null
    echo "✅ finished cleanup"
}



STABILIZE_SECS="45"
function create_usage() {
  usage=$(printf '%s\n' "
    Usage: $(basename $0) [Options]
    Options:
      -t | --shoot                      <shoot-cluster-name>                (Required) Name of the Source Gardener Shoot Cluster
      -p | --project                    <project-name>                      (Required) Name of the Source Gardener Project
      -l | --landscape                  <landscape-name>                    (Required) Name of the Source Gardener landscape.
      -s | --stabilize                  <num seconds>                       (Optional) Num secs to wait for cluster stabilization. (Default: $STABILIZE_SECS)
    ")
  echo "${usage}"
}

USAGE=$(create_usage)
function parse_flags() {
  while test $# -gt 0; do
    case "$1" in
    --landscape | -l)
      shift
      LANDSCAPE="$1"
      ;;
    --project | -p)
      shift
      PROJECT="$1"
      ;;
    --shoot | -t)
      shift
      SHOOT="$1"
      ;;
    --stabilise | -s)
      shift
      STABILIZE_SECS="$1"
      ;;
    --help | -h)
      shift
      echo "${USAGE}"
      exit 0
      ;;
    esac
    shift
  done
}

function validate_args() {
  if [[ -z "${LANDSCAPE}" ]]; then
    echo -e "Landscape name has not been passed. Please provide landscape name either by specifying --landscape or -l argument"
    exit 1
  fi
  if [[ -z "${PROJECT}" ]]; then
    echo -e "Project name has not been passed. Please provide Project name either by specifying --project or -p argument"
    exit 1
  fi
  if [[ -z "${SHOOT}" ]]; then
    echo -e "Shoot has not been passed. Please provide Shoot either by specifying --shoot or -t argument"
    exit 1
  fi
}

function generateViewerKubeConfigs() {
  echo "Targeting garden cluster..."
  gardenctl target --garden "$LANDSCAPE"

  echo "Setting up kubectl environment..."
  eval "$(gardenctl kubectl-env zsh)"

  echo "✅ kubectl environment is now configured inside this script."

  local projNamespace
  projNamespace="garden-$PROJECT"
  echo "⌛ Generating viewer kubeconfig for shoot: $SHOOT and project namespace: ${projNamespace} ..."
  vkcfg=$(kubectl create \
      -f <(printf '{"spec":{"expirationSeconds":86400}}') \
      --raw "/apis/core.gardener.cloud/v1beta1/namespaces/${projNamespace}/shoots/${SHOOT}/viewerkubeconfig" | \
      jq -r ".status.kubeconfig" | \
      base64 -d)
  SOURCE_CLUSTER_NAME=$(echo "$vkcfg" | yq ".current-context")
  echo "Cluster Name is: $SOURCE_CLUSTER_NAME"
  echo "Gen dir is $GEN_DIR"
  VIEWER_KUBECONFIG="$GEN_DIR/$SOURCE_CLUSTER_NAME.yaml"
  mkdir -p "$GEN_DIR"
  echo "$vkcfg" > "$VIEWER_KUBECONFIG"
  echo "✅ Generated $VIEWER_KUBECONFIG"
}


function genSchedulerConfig() {
  export DEST_KUBECONFIG="/tmp/minkapi.yaml"
  export SCHEDULER_CONFIG="/tmp/minkapi-kube-scheduler-config.yaml"
  envsubst < "templates/kube-scheduler-config.yaml" >  "$SCHEDULER_CONFIG"
  echo "✅ Generated kube-scheduler config at $SCHEDULER_CONFIG"
}


validateCommandInPath "jq"
validateCommandInPath "kcpcl"
validateCommandInPath "envsubst"
validateKubeBinariesBuilt


parse_flags "$@"
validate_args
trap cleanup EXIT INT TERM
echo "Setup signal handler"


generateViewerKubeConfigs
downloadObjectsFromCluster

echo "⌛ Starting minkapi"
minkapi > /tmp/minkapi.log 2>&1 &
MINKAPIPID=$!
echo "waiting for minkapi to start up"
sleep 2
echo "✅ Started minkapi. Logs at /tmp/minkapi.log, pid: $MINKAPIPID"

genSchedulerConfig
echo "⌛ Starting kube-scheduler"
schedLogPath="/tmp/minkapi-kube-scheduler.log"
bin/kube-scheduler \
--config=$SCHEDULER_CONFIG \
--bind-address=127.0.0.1 \
--secure-port=8090 \
--v=4 > "$schedLogPath" 2>&1 &
KSCHDPID=$!
echo "waiting for kube-scheduler to start up"
sleep 5
echo "✅ Started kube-scheduler. Logs path: $schedLogPath, pid: $KSCHDPID"

echo "⌛ Starting procmon"

perfDirName="minkapi-perf"
perfDirPath="/tmp/$perfDirName"
procmon -d "$perfDirPath" -interval 5s -n "$SHOOT" minkapi kube-scheduler &
PROCMONPID=$!
sleep 10
echo "✅ Started procmon. procmon pid is ${PROCMONPID}"

echo "⌛ Starting kcpcl upload to minkapi"
echo "OBJ_DIR is $OBJ_DIR"
time kcpcl upload -d ${OBJ_DIR} -k /tmp/minkapi.yaml | tee "/tmp/upload-$perfDirName.log"
echo "⌛ waiting for STABILIZE_SECS: $STABILIZE_SECS for minkapi cluster to stabilise..."
sleep  $STABILIZE_SECS #TODO: loop over pod-node assignments until no changes for 20seconds

reportDirPath="docs/reports/${perfDirName}"
mkdir -p "$reportDirPath"
if [[ -d "$perfDirPath" ]]; then
  echo "Copying Reports from $perfDirPath to docs/$perfDirName"
  cp -r $perfDirPath/* "${reportDirPath}"
fi
echo "✅ DONE!"
exit 0








