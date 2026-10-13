# shellcheck shell=bash
#
# The Kubernetes objects sqlite-copy resolves, served by fake-k8s-api.py:
# claims, and volumes of the kinds it tells apart (local, hostPath, CSI).
# FAKE_DIR is the server's directory; fake_api_start points sqlite-copy at it.

K8S_HELPERS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# fake_api_start DIR — start the server on DIR, export K8S_API, K8S_SA_DIR and
# FAKE_API_PID.
fake_api_start() {
  export FAKE_DIR=$1
  mkdir -p "$FAKE_DIR/objects/api/v1/persistentvolumes" "$FAKE_DIR/sa"
  printf 'sa-token' >"$FAKE_DIR/sa/token"
  python3 "$K8S_HELPERS/fake-k8s-api.py" 3>&- &
  FAKE_API_PID=$!
  local _
  for _ in $(seq 1 50); do [ -f "$FAKE_DIR/port" ] && break; sleep 0.1; done
  [ -f "$FAKE_DIR/port" ] || { echo "the fake API did not start" >&2; return 1; }
  K8S_API="http://127.0.0.1:$(cat "$FAKE_DIR/port")"
  export K8S_API K8S_SA_DIR="$FAKE_DIR/sa" FAKE_API_PID
}

fake_api_stop() {
  [ -n "${FAKE_API_PID:-}" ] && kill "$FAKE_API_PID" 2>/dev/null
  FAKE_API_PID=
}

# fake_pvc NAMESPACE CLAIM VOLUME [PHASE] — a claim bound to VOLUME (PHASE
# Bound); VOLUME "" for one not bound yet.
fake_pvc() {
  local dir="$FAKE_DIR/objects/api/v1/namespaces/$1/persistentvolumeclaims"
  mkdir -p "$dir"
  printf '{"kind":"PersistentVolumeClaim","metadata":{"name":"%s","namespace":"%s"},"spec":{"volumeName":"%s"},"status":{"phase":"%s"}}' \
    "$2" "$1" "$3" "${4:-Bound}" >"$dir/$2.json"
}

# fake_pv_local VOLUME PATH NODE — a local volume, as the local-path
# provisioner creates them, pinned to NODE by node affinity.
fake_pv_local() {
  printf '{"kind":"PersistentVolume","metadata":{"name":"%s"},"spec":{"local":{"path":"%s"},"nodeAffinity":{"required":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"kubernetes.io/hostname","operator":"In","values":["%s"]}]}]}}}}' \
    "$1" "$2" "$3" >"$FAKE_DIR/objects/api/v1/persistentvolumes/$1.json"
}

# fake_pv_hostpath VOLUME PATH — a hostPath volume without node affinity.
fake_pv_hostpath() {
  printf '{"kind":"PersistentVolume","metadata":{"name":"%s"},"spec":{"hostPath":{"path":"%s"}}}' \
    "$1" "$2" >"$FAKE_DIR/objects/api/v1/persistentvolumes/$1.json"
}

# fake_pv_csi VOLUME — a volume of a CSI driver.
fake_pv_csi() {
  printf '{"kind":"PersistentVolume","metadata":{"name":"%s"},"spec":{"csi":{"driver":"block.csi.example","volumeHandle":"%s"}}}' \
    "$1" "$1" >"$FAKE_DIR/objects/api/v1/persistentvolumes/$1.json"
}

# sqlite_databases FILE NAMESPACE CLAIM PATH […] — the chart's list of
# databases, one triple per database.
sqlite_databases() {
  local file=$1 sep=""
  shift
  {
    printf '['
    while [ $# -ge 3 ]; do
      printf '%s{"namespace":"%s","pvc":"%s","path":"%s"}' "$sep" "$1" "$2" "$3"
      sep=","
      shift 3
    done
    printf ']'
  } >"$file"
}
