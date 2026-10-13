#!/usr/bin/env bats
#
# sqlite-copy: how a listed database is found on the node (claim → volume →
# directory under the host root, against a fake Kubernetes API), that the copy
# of a database a writer keeps changing is one consistent state, single file,
# mode 600, and what fails, with rc 2 and nothing left behind.

bats_require_minimum_version 1.5.0

setup() {
  load helpers/common
  load e2e/helpers/k8s-volumes
  common_setup
  unset SQLITE_BUSY_TIMEOUT KUBELET_DIR
  export HOST_ROOT="$TMP/node" SQLITE_COPY_DIR="$TMP/copies" NODE_NAME=node-a \
         SQLITE_DATABASES_FILE="$TMP/databases.json"
  mkdir -p "$HOST_ROOT" "$SQLITE_COPY_DIR"
  fake_api_start "$TMP/api"
  WRITER_PIDS=()
}

teardown() {
  local pid
  for pid in "${WRITER_PIDS[@]}"; do kill "$pid" 2>/dev/null; done
  fake_api_stop
  chmod -R u+w "$TMP" 2>/dev/null
  common_teardown
}

HELPERS="$BATS_TEST_DIRNAME/e2e/helpers"

# start_writer DB MODE — sqlite-writer.py on DB, back once it has committed.
start_writer() {
  mkdir -p "$(dirname "$1")"
  python3 "$HELPERS/sqlite-writer.py" "$1" "$2" "$1.ready" 3>&- &
  WRITER_PIDS+=($!)
  for _ in $(seq 1 100); do [ -f "$1.ready" ] && return 0; sleep 0.1; done
  fail "the writer on $1 did not start"
}

# local_volume NAMESPACE CLAIM VOLUME [NODE] — a claim bound to a local volume
# on NODE (default this node); prints the volume's directory on the host.
local_volume() {
  local path="/var/lib/rancher/k3s/storage/$3_$1_$2"
  fake_pvc "$1" "$2" "$3"
  fake_pv_local "$3" "$path" "${4:-node-a}"
  mkdir -p "$HOST_ROOT$path"
  echo "$HOST_ROOT$path"
}

# csi_volume NAMESPACE CLAIM VOLUME — a claim bound to a CSI volume, mounted
# by the kubelet for a pod on this node; prints the mount.
csi_volume() {
  local mount="$HOST_ROOT/var/lib/kubelet/pods/0b6f2c1e-uid/volumes/kubernetes.io~csi/$3/mount"
  fake_pvc "$1" "$2" "$3"
  fake_pv_csi "$3"
  mkdir -p "$mount"
  echo "$mount"
}

copies() { (cd "$SQLITE_COPY_DIR" && find . -mindepth 1 -type f | LC_ALL=C sort); }

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

@test "a local volume: the copy of a WAL database under write load is consistent, a single file, mode 600" {
  dir=$(local_volume vault vault-data pvc-1)
  start_writer "$dir/db.sqlite3" wal
  [ -f "$dir/db.sqlite3-wal" ] || fail "no WAL file: $(ls "$dir")"
  # Read-only, as through the pod's /node: not even the -shm file is writable.
  chmod -R a-w "$dir"
  sqlite_databases "$SQLITE_DATABASES_FILE" vault vault-data db.sqlite3
  copy="$SQLITE_COPY_DIR/vault/vault-data/db.sqlite3"
  for round in 1 2 3; do
    run "$BIN/sqlite-copy" save
    [ "$status" -eq 0 ] || fail "round $round: status $status: $output"
    [ "$(copies)" = "./vault/vault-data/db.sqlite3" ] || fail "$(copies)"
    [ "$(mode_of "$copy")" = 600 ] || fail "mode $(mode_of "$copy")"
    run python3 "$HELPERS/sqlite-check.py" "$copy"
    [ "$status" -eq 0 ] || fail "round $round: $output"
    [ "${output#*mode=}" = wal ] || fail "journal mode not kept: $output"
  done
}

@test "a rollback-journal database under write load: the copy is consistent and keeps its journal mode" {
  dir=$(local_volume app app-data pvc-2)
  start_writer "$dir/data/app.db" delete
  sqlite_databases "$SQLITE_DATABASES_FILE" app app-data data/app.db
  for round in 1 2 3; do
    run "$BIN/sqlite-copy"
    [ "$status" -eq 0 ] || fail "round $round: status $status: $output"
    run python3 "$HELPERS/sqlite-check.py" "$SQLITE_COPY_DIR/app/app-data/data/app.db"
    [ "$status" -eq 0 ] || fail "round $round: $output"
    [ "${output#*mode=}" = delete ] || fail "$output"
  done
}

@test "a CSI volume is copied from the kubelet's mount for a pod on this node" {
  mount=$(csi_volume git gitea-data pvc-3)
  start_writer "$mount/gitea.db" wal
  sqlite_databases "$SQLITE_DATABASES_FILE" git gitea-data gitea.db
  run "$BIN/sqlite-copy" save
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [[ "$output" == *"copied $SQLITE_COPY_DIR/git/gitea-data/gitea.db"* ]] || fail "$output"
  python3 "$HELPERS/sqlite-check.py" "$SQLITE_COPY_DIR/git/gitea-data/gitea.db"
}

@test "a volume of another kind is found below its plugin's directory, the kubelet's root directory set" {
  export KUBELET_DIR=/var/lib/k0s/kubelet
  fake_pvc media media-data pvc-4
  printf '{"kind":"PersistentVolume","spec":{"nfs":{"server":"nfs","path":"/export"}}}' \
    >"$FAKE_DIR/objects/api/v1/persistentvolumes/pvc-4.json"
  mount="$HOST_ROOT/var/lib/k0s/kubelet/pods/uid-9/volumes/kubernetes.io~nfs/pvc-4"
  mkdir -p "$mount"
  start_writer "$mount/library.db" wal
  sqlite_databases "$SQLITE_DATABASES_FILE" media media-data library.db
  run "$BIN/sqlite-copy" save
  [ "$status" -eq 0 ] || fail "status $status: $output"
  python3 "$HELPERS/sqlite-check.py" "$SQLITE_COPY_DIR/media/media-data/library.db"
}

@test "a volume on another node, or mounted on none here, is skipped without an error" {
  local_volume vault vault-data pvc-1 node-b >/dev/null
  fake_pvc git gitea-data pvc-3
  fake_pv_csi pvc-3
  fake_pvc media media-data pvc-5
  fake_pv_hostpath pvc-5 /srv/media
  sqlite_databases "$SQLITE_DATABASES_FILE" vault vault-data db.sqlite3 git gitea-data gitea.db media media-data library.db
  run "$BIN/sqlite-copy" save
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [[ "$output" == *"volume pvc-1 is on node node-b, skipped"* ]] || fail "$output"
  [[ "$output" == *"volume pvc-3 is not mounted on this node, skipped"* ]] || fail "$output"
  [[ "$output" == *"volume pvc-5 has no library.db on this node, skipped"* ]] || fail "$output"
  [ -z "$(copies)" ] || fail "$(copies)"
}

@test "a hostPath volume without node affinity is copied on the node that has the database" {
  fake_pvc media media-data pvc-5
  fake_pv_hostpath pvc-5 /srv/media
  start_writer "$HOST_ROOT/srv/media/library.db" delete
  sqlite_databases "$SQLITE_DATABASES_FILE" media media-data library.db
  run "$BIN/sqlite-copy" save
  [ "$status" -eq 0 ] || fail "status $status: $output"
  python3 "$HELPERS/sqlite-check.py" "$SQLITE_COPY_DIR/media/media-data/library.db"
}

@test "the API is asked for the claim and its volume with the ServiceAccount token, and nothing else" {
  dir=$(local_volume vault vault-data pvc-1)
  start_writer "$dir/db.sqlite3" wal
  sqlite_databases "$SQLITE_DATABASES_FILE" vault vault-data db.sqlite3
  run "$BIN/sqlite-copy" save
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(cat "$FAKE_DIR/requests")" = "GET /api/v1/namespaces/vault/persistentvolumeclaims/vault-data
GET /api/v1/persistentvolumes/pvc-1" ] || fail "$(cat "$FAKE_DIR/requests")"
  printf 'other-token' >"$K8S_SA_DIR/token"
  run "$BIN/sqlite-copy" save
  [ "$status" -eq 2 ] || fail "status $status: $output"
  [[ "$output" == *"HTTP 401"* ]] || fail "$output"
  [ -z "$(copies)" ] || fail "$(copies)"
}

@test "a claim that does not exist or is not bound, or a volume that does not exist, fails with 2" {
  fake_pvc app pending "" Pending
  fake_pvc app orphan pvc-gone
  sqlite_databases "$SQLITE_DATABASES_FILE" app missing app.db app pending app.db app orphan app.db
  run "$BIN/sqlite-copy" save
  [ "$status" -eq 2 ] || fail "status $status: $output"
  [[ "$output" == *"claim app/missing not found"* ]] || fail "$output"
  [[ "$output" == *"claim app/pending is not bound"* ]] || fail "$output"
  [[ "$output" == *"volume pvc-gone of claim app/orphan not found"* ]] || fail "$output"
  [[ "$output" == *"3 of 3 databases not copied"* ]] || fail "$output"
}

@test "an API server that does not answer fails with 2" {
  export K8S_API=http://127.0.0.1:1
  sqlite_databases "$SQLITE_DATABASES_FILE" app app-data app.db
  run "$BIN/sqlite-copy" save
  [ "$status" -eq 2 ] || fail "status $status: $output"
}

@test "a database missing on the node that has its volume fails with 2; the others are still copied" {
  dir=$(local_volume vault vault-data pvc-1)
  start_writer "$dir/db.sqlite3" wal
  mount=$(csi_volume git gitea-data pvc-3)
  sqlite_databases "$SQLITE_DATABASES_FILE" git gitea-data gitea.db vault vault-data db.sqlite3
  run "$BIN/sqlite-copy" save
  [ "$status" -eq 2 ] || fail "status $status: $output"
  [[ "$output" == *"gitea.db not found in the volume (/var/lib/kubelet/pods/"* ]] || fail "$output"
  [[ "$output" == *"1 of 2 databases not copied"* ]] || fail "$output"
  [ "$(copies)" = "./vault/vault-data/db.sqlite3" ] || fail "$(copies)"
  [ -d "$mount" ]
}

@test "a file that is no database, or a database locked longer than the busy timeout, fails with 2 and leaves nothing" {
  dir=$(local_volume app app-data pvc-2)
  echo "not a database" >"$dir/notes.db"
  # The application in the middle of a long write: the copy waits for its
  # lock, up to SQLITE_BUSY_TIMEOUT.
  python3 - "$dir/app.db" "$TMP/locked" <<'PY' 3>&- &
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1], isolation_level=None, timeout=60)
c.execute("PRAGMA journal_mode=delete")
c.execute("CREATE TABLE t (x)")
c.execute("BEGIN EXCLUSIVE")
c.execute("INSERT INTO t VALUES (1)")
open(sys.argv[2], "w").close()
time.sleep(30)
PY
  WRITER_PIDS+=($!)
  for _ in $(seq 1 100); do [ -f "$TMP/locked" ] && break; sleep 0.1; done
  [ -f "$TMP/locked" ] || fail "the lock was not taken"
  export SQLITE_BUSY_TIMEOUT=1
  sqlite_databases "$SQLITE_DATABASES_FILE" app app-data notes.db app app-data app.db
  run "$BIN/sqlite-copy" save
  [ "$status" -eq 2 ] || fail "status $status: $output"
  [[ "$output" == *"notes.db: file is not a database"* ]] || fail "$output"
  [[ "$output" == *"app.db: database is locked"* ]] || fail "$output"
  [ -z "$(copies)" ] || fail "$(copies)"
}

@test "a path leading out of the volume is refused with 2" {
  dir=$(local_volume app app-data pvc-2)
  start_writer "$HOST_ROOT/etc/other.db" wal
  ln -s ../../../../../../etc/other.db "$dir/link.db"
  sqlite_databases "$SQLITE_DATABASES_FILE" app app-data link.db app app-data ../other.db app app-data /etc/other.db
  run "$BIN/sqlite-copy" save
  [ "$status" -eq 2 ] || fail "status $status: $output"
  [[ "$output" == *"link.db leads out of its volume"* ]] || fail "$output"
  [[ "$output" == *"path ../other.db must be relative to the volume, without '..'"* ]] || fail "$output"
  [[ "$output" == *"path /etc/other.db must be relative"* ]] || fail "$output"
  [ -z "$(copies)" ] || fail "$(copies)"
}

@test "save replaces the earlier copies; clean removes them and keeps the directory" {
  dir=$(local_volume vault vault-data pvc-1)
  start_writer "$dir/db.sqlite3" wal
  mkdir -p "$SQLITE_COPY_DIR/old/claim"
  echo stale >"$SQLITE_COPY_DIR/old/claim/gone.db"
  sqlite_databases "$SQLITE_DATABASES_FILE" vault vault-data db.sqlite3
  run "$BIN/sqlite-copy" save
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(copies)" = "./vault/vault-data/db.sqlite3" ] || fail "$(copies)"
  run "$BIN/sqlite-copy" clean
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ -d "$SQLITE_COPY_DIR" ] && [ -z "$(ls -A "$SQLITE_COPY_DIR")" ] || fail "$(ls -A "$SQLITE_COPY_DIR")"
}

@test "a list of databases that cannot be read, or an unknown action, fails with 2" {
  rm -f "$SQLITE_DATABASES_FILE"
  run "$BIN/sqlite-copy" save
  [ "$status" -eq 2 ] || fail "status $status: $output"
  echo '{"namespace":"app"}' >"$SQLITE_DATABASES_FILE"
  run "$BIN/sqlite-copy" save
  [ "$status" -eq 2 ] || fail "status $status: $output"
  run "$BIN/sqlite-copy" restore
  [ "$status" -eq 2 ] || fail "status $status: $output"
}
