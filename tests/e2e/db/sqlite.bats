#!/usr/bin/env bats
#
# sqlite-copy against an application that keeps writing (run by run.sh, one
# application image per run): the container `src` writes two databases under
# constant load, one in WAL mode and one with a rollback journal, on a volume
# this container sees read-only below /node, where a node sees a pod's
# volume: as a local volume of the local-path provisioner and as the kubelet's
# mount of a CSI volume. The claims and volumes come from a fake Kubernetes
# API. Every copy has to be one consistent state of its database, through
# Borg and back, and good to run the application on again.

bats_require_minimum_version 1.5.0

load helpers/common
load ../helpers/k8s-volumes

HELPERS=/tests/e2e/helpers
LOCAL=/node/var/lib/rancher/k3s/storage/pvc-local_app_local-data
CSI=/node/var/lib/kubelet/pods/e2e-pod/volumes/kubernetes.io~csi/pvc-csi/mount

setup_file() {
  export E2E_TMP
  E2E_TMP=$(mktemp -d)
  wait_for 60 test -f "$LOCAL/wal/ready" -a -f "$LOCAL/delete/ready"

  fake_api_start "$E2E_TMP/api"
  fake_pvc app local-data pvc-local
  fake_pv_local pvc-local /var/lib/rancher/k3s/storage/pvc-local_app_local-data e2e
  fake_pvc app csi-data pvc-csi
  fake_pv_csi pvc-csi
  export FAKE_API_PID NODE_NAME=e2e HOST_ROOT=/node \
         SQLITE_COPY_DIR="$E2E_TMP/copies" SQLITE_DATABASES_FILE="$E2E_TMP/databases.json"
  sqlite_databases "$SQLITE_DATABASES_FILE" \
    app local-data wal/app.db app local-data delete/app.db \
    app csi-data wal/app.db app csi-data delete/app.db
  mkdir -p "$SQLITE_COPY_DIR"
}

teardown_file() {
  fake_api_stop
  rm -rf "$E2E_TMP"
}

COPIES="local-data/wal/app.db local-data/delete/app.db csi-data/wal/app.db csi-data/delete/app.db"

# last_tx DB — the last transaction the application committed, read from its
# database read-only as the copy reads it.
last_tx() {
  python3 -c 'import sqlite3, sys
print(sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True, timeout=60).execute("SELECT n FROM total").fetchone()[0])' "$1"
}

@test "the application writes while the copies are taken, below /node read-only ($SQLITE_APP_IMAGE)" {
  for db in "$LOCAL/wal/app.db" "$LOCAL/delete/app.db"; do
    a=$(last_tx "$db")
    sleep 1
    b=$(last_tx "$db")
    [ "$b" -gt "$a" ] || fail "$db: no transactions in a second ($a → $b)"
  done
  [ -f "$LOCAL/wal/app.db-wal" ] || fail "no WAL file: $(ls "$LOCAL/wal")"
  run touch "$LOCAL/probe"
  [ "$status" -ne 0 ] || fail "the volume is writable"
}

@test "every copy under write load is one consistent state, in its journal mode, single file, mode 600" {
  for round in $(seq 1 20); do
    run sqlite-copy save
    [ "$status" -eq 0 ] || fail "round $round: status $status: $output"
    [ "$(cd "$SQLITE_COPY_DIR/app" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ')" \
      = "$(printf '%s\n' $COPIES | LC_ALL=C sort | tr '\n' ' ')" ] \
      || fail "round $round: $(cd "$SQLITE_COPY_DIR" && find . -type f)"
    for copy in $COPIES; do
      [ "$(mode_of "$SQLITE_COPY_DIR/app/$copy")" = 600 ] || fail "$copy: mode $(mode_of "$SQLITE_COPY_DIR/app/$copy")"
      cp "$SQLITE_COPY_DIR/app/$copy" "$E2E_TMP/check.db"
      run python3 "$HELPERS/sqlite-check.py" "$E2E_TMP/check.db"
      [ "$status" -eq 0 ] || fail "round $round, $copy: $output"
      [ "${output#*mode=}" = "$(basename "$(dirname "$copy")")" ] || fail "round $round, $copy: $output"
      rm -f "$E2E_TMP"/check.db*
    done
  done
}

@test "a copy holds every transaction committed before it was taken" {
  before_wal=$(last_tx "$LOCAL/wal/app.db")
  before_delete=$(last_tx "$LOCAL/delete/app.db")
  run sqlite-copy save
  [ "$status" -eq 0 ] || fail "status $status: $output"
  for pair in "local-data/wal/app.db $before_wal" "csi-data/wal/app.db $before_wal" \
              "local-data/delete/app.db $before_delete" "csi-data/delete/app.db $before_delete"; do
    set -- $pair
    cp "$SQLITE_COPY_DIR/app/$1" "$E2E_TMP/check.db"
    n=$(python3 "$HELPERS/sqlite-check.py" "$E2E_TMP/check.db" | sed 's/^n=\([0-9]*\).*/\1/')
    rm -f "$E2E_TMP"/check.db*
    [ "$n" -ge "$2" ] || fail "$1: last transaction $n, $2 committed before the copy"
  done
}

@test "the copies come out of the Borg archive unchanged, mode 600, and the application runs on them again" {
  run sqlite-copy save
  [ "$status" -eq 0 ] || fail "status $status: $output"
  borg_create "$E2E_TMP/repo" sqlite "$SQLITE_COPY_DIR" >/dev/null
  borg_extract "$E2E_TMP/repo" sqlite "$E2E_TMP/extracted"
  restored="$E2E_TMP/extracted$SQLITE_COPY_DIR/app"
  for copy in $COPIES; do
    cmp "$SQLITE_COPY_DIR/app/$copy" "$restored/$copy" || fail "$copy differs"
    [ "$(mode_of "$restored/$copy")" = 600 ] || fail "$copy: mode $(mode_of "$restored/$copy")"
  done
  # The restore: the application stopped, its database replaced by the copy
  # (no -wal or -shm of the old one left), the application started again.
  for mode in wal delete; do
    mkdir -p "$E2E_TMP/app-$mode"
    cp "$restored/local-data/$mode/app.db" "$E2E_TMP/app-$mode/app.db"
    n=$(python3 "$HELPERS/sqlite-check.py" "$E2E_TMP/app-$mode/app.db" | sed 's/^n=\([0-9]*\).*/\1/')
    python3 "$HELPERS/sqlite-writer.py" "$E2E_TMP/app-$mode/app.db" "$mode" "$E2E_TMP/app-$mode/ready" 3>&- &
    pid=$!
    wait_for 30 test -f "$E2E_TMP/app-$mode/ready"
    kill "$pid" || fail "the application ended on the restored $mode database"
    wait "$pid" || true
    # Killed in a transaction, it leaves a hot journal that the next writer
    # rolls back, as the application does when it starts again.
    python3 -c 'import sqlite3, sys; sqlite3.connect(sys.argv[1]).execute("SELECT n FROM total").fetchone()' \
      "$E2E_TMP/app-$mode/app.db"
    run python3 "$HELPERS/sqlite-check.py" "$E2E_TMP/app-$mode/app.db"
    [ "$status" -eq 0 ] || fail "$mode after the restart: $output"
    [ "${output%% *}" != "n=$n" ] || fail "$mode: no transaction after the restart"
  done
}

@test "clean removes the copies" {
  run sqlite-copy save
  [ "$status" -eq 0 ] || fail "status $status: $output"
  run sqlite-copy clean
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ -z "$(ls -A "$SQLITE_COPY_DIR")" ] || fail "$(ls -A "$SQLITE_COPY_DIR")"
}
