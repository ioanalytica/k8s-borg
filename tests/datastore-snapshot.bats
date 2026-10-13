#!/usr/bin/env bats
#
# datastore-snapshot: which datastore it finds under the node's root, what it
# writes for each, and that nothing is left behind when it fails or is cleaned.
# etcdctl and etcdutl are stubs; the SQLite case runs the real online backup of
# a WAL database that a writer holds open, read-only as through the pod's /node.

bats_require_minimum_version 1.5.0

setup() {
  load helpers/common
  common_setup
  unset DATASTORE_ETCD_ENDPOINT HOST_IP K3S_DATA_DIR KUBEADM_DIR DATASTORE_SNAPSHOT_TIMEOUT
  export HOST_ROOT="$TMP/node" DATASTORE_SNAPSHOT_DIR="$TMP/snapshot"
  mkdir -p "$HOST_ROOT" "$DATASTORE_SNAPSHOT_DIR" "$TMP/bin"
  # etcdctl: records its arguments and writes a snapshot where it is told to,
  # or fails with ETCDCTL_RC.
  cat >"$TMP/bin/etcdctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$TMP/etcdctl-argv"
[ "\${ETCDCTL_RC:-0}" = 0 ] || exit "\${ETCDCTL_RC}"
for last; do :; done
echo snapshot >"\$last"
EOF
  printf '#!/bin/sh\necho "status $*"\n' >"$TMP/bin/etcdutl"
  chmod +x "$TMP/bin/etcdctl" "$TMP/bin/etcdutl"
  PATH="$TMP/bin:$PATH"
}

teardown() {
  [ -n "${WRITER_PID:-}" ] && kill "$WRITER_PID" 2>/dev/null
  chmod -R u+w "$TMP" 2>/dev/null
  common_teardown
}

k3s_server() { echo "$HOST_ROOT/var/lib/rancher/k3s/server"; }

make_k3s_etcd() {
  local s; s="$(k3s_server)"
  mkdir -p "$s/db/etcd/member" "$s/tls/etcd"
  touch "$s/tls/etcd/server-ca.crt" "$s/tls/etcd/client.crt" "$s/tls/etcd/client.key"
  echo "K10token::server:secret" >"$s/token"
}

make_kubeadm() {
  local k="$HOST_ROOT/etc/kubernetes"
  mkdir -p "$k/manifests" "$k/pki/etcd"
  touch "$k/manifests/etcd.yaml" "$k/pki/ca.crt" "$k/pki/ca.key" "$k/pki/etcd/ca.crt" \
        "$k/pki/etcd/healthcheck-client.crt" "$k/pki/etcd/healthcheck-client.key"
}

# etcdctl_arg PREFIX — the value of the etcdctl option starting with PREFIX.
etcdctl_arg() { sed -n "s|^$1||p" "$TMP/etcdctl-argv"; }

snapshot_files() { (cd "$DATASTORE_SNAPSHOT_DIR" && find . -mindepth 1 | sort); }

@test "a node without a datastore has nothing to snapshot" {
  run "$BIN/datastore-snapshot"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [[ "$output" == *"no cluster datastore on this node"* ]] || fail "$output"
  [ -z "$(snapshot_files)" ] || fail "$(snapshot_files)"
}

@test "k3s with etcd: etcdctl against the node IP with k3s's client certificate, and the token" {
  make_k3s_etcd
  HOST_IP=10.0.0.5 run "$BIN/datastore-snapshot" save
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(etcdctl_arg --endpoints=)" = "https://10.0.0.5:2379" ] || fail "$(cat "$TMP/etcdctl-argv")"
  [ "$(etcdctl_arg --cacert=)" = "$(k3s_server)/tls/etcd/server-ca.crt" ] || fail "$(cat "$TMP/etcdctl-argv")"
  [ "$(etcdctl_arg --cert=)" = "$(k3s_server)/tls/etcd/client.crt" ] || fail "$(cat "$TMP/etcdctl-argv")"
  [ "$(etcdctl_arg --key=)" = "$(k3s_server)/tls/etcd/client.key" ] || fail "$(cat "$TMP/etcdctl-argv")"
  [ "$(snapshot_files)" = "./k3s
./k3s/etcd-snapshot.db
./k3s/token" ] || fail "$(snapshot_files)"
  cmp -s "$(k3s_server)/token" "$DATASTORE_SNAPSHOT_DIR/k3s/token" || fail "token differs"
}

@test "the snapshot is readable by its owner only" {
  make_k3s_etcd
  run "$BIN/datastore-snapshot"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  for f in k3s k3s/etcd-snapshot.db k3s/token; do
    mode="$(stat -c %a "$DATASTORE_SNAPSHOT_DIR/$f" 2>/dev/null || stat -f %Lp "$DATASTORE_SNAPSHOT_DIR/$f")"
    [[ "$mode" == 600 || "$mode" == 700 ]] || fail "$f has mode $mode"
  done
}

@test "the endpoint: DATASTORE_ETCD_ENDPOINT wins, without a node IP it is localhost" {
  make_k3s_etcd
  HOST_IP=10.0.0.5 DATASTORE_ETCD_ENDPOINT=https://etcd.example:2379 run "$BIN/datastore-snapshot"
  [ "$(etcdctl_arg --endpoints=)" = "https://etcd.example:2379" ] || fail "$(cat "$TMP/etcdctl-argv")"
  run "$BIN/datastore-snapshot"
  [ "$(etcdctl_arg --endpoints=)" = "https://127.0.0.1:2379" ] || fail "$(cat "$TMP/etcdctl-argv")"
}

@test "kubeadm: etcdctl with the healthcheck client certificate, and the PKI" {
  make_kubeadm
  HOST_IP=10.0.0.6 run "$BIN/datastore-snapshot"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(etcdctl_arg --cacert=)" = "$HOST_ROOT/etc/kubernetes/pki/etcd/ca.crt" ] || fail "$(cat "$TMP/etcdctl-argv")"
  [ "$(etcdctl_arg --cert=)" = "$HOST_ROOT/etc/kubernetes/pki/etcd/healthcheck-client.crt" ] || fail "$(cat "$TMP/etcdctl-argv")"
  [ -f "$DATASTORE_SNAPSHOT_DIR/kubeadm/etcd-snapshot.db" ] || fail "$(snapshot_files)"
  [ -f "$DATASTORE_SNAPSHOT_DIR/kubeadm/pki/ca.key" ] || fail "$(snapshot_files)"
  [ -f "$DATASTORE_SNAPSHOT_DIR/kubeadm/pki/etcd/ca.crt" ] || fail "$(snapshot_files)"
}

@test "a custom k3s data directory" {
  mkdir -p "$HOST_ROOT/data/k3s/server/db/etcd/member" "$HOST_ROOT/data/k3s/server/tls/etcd"
  touch "$HOST_ROOT/data/k3s/server/tls/etcd/"{server-ca.crt,client.crt,client.key}
  echo token >"$HOST_ROOT/data/k3s/server/token"
  K3S_DATA_DIR=/data/k3s run "$BIN/datastore-snapshot"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ -f "$DATASTORE_SNAPSHOT_DIR/k3s/etcd-snapshot.db" ] || fail "$(snapshot_files)"
}

@test "k3s with SQLite: a consistent copy of the live WAL database, read-only" {
  s="$(k3s_server)"
  mkdir -p "$s/db"
  echo "K10token::server:secret" >"$s/token"
  # A writer that keeps the database open in WAL mode, as k3s does: the -wal
  # and -shm files exist and hold rows not yet in the main file.
  python3 - "$s/db/state.db" "$TMP/writer-ready" <<'PY' &
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1], isolation_level=None)
c.execute("PRAGMA journal_mode=WAL")
c.execute("PRAGMA wal_autocheckpoint=0")
c.execute("CREATE TABLE kine (id INTEGER PRIMARY KEY, name TEXT)")
for i in range(500):
    c.execute("INSERT INTO kine (name) VALUES (?)", ("/registry/secrets/%d" % i,))
open(sys.argv[2], "w").close()
time.sleep(60)
PY
  WRITER_PID=$!
  for _ in $(seq 1 50); do [ -f "$TMP/writer-ready" ] && break; sleep 0.1; done
  [ -f "$s/db/state.db-wal" ] || fail "no WAL file: $(ls "$s/db")"
  chmod -R a-w "$s/db"
  run "$BIN/datastore-snapshot"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  out="$DATASTORE_SNAPSHOT_DIR/k3s/state.db"
  [ "$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select count(*) from kine").fetchone()[0])' "$out")" = 500 ] \
    || fail "rows missing in the copy"
  [ "$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("pragma journal_mode").fetchone()[0])' "$out")" = delete ] \
    || fail "the copy is not a single file"
  [ "$(snapshot_files)" = "./k3s
./k3s/state.db
./k3s/token" ] || fail "$(snapshot_files)"
}

@test "a SQLite file that is not a database fails, and leaves nothing" {
  mkdir -p "$(k3s_server)/db"
  echo "not a database" >"$(k3s_server)/db/state.db"
  echo token >"$(k3s_server)/token"
  run "$BIN/datastore-snapshot"
  [ "$status" -eq 2 ] || fail "status $status: $output"
  [ -z "$(snapshot_files)" ] || fail "$(snapshot_files)"
}

@test "a failed etcdctl fails with 2 and leaves nothing" {
  make_k3s_etcd
  ETCDCTL_RC=1 run "$BIN/datastore-snapshot"
  [ "$status" -eq 2 ] || fail "status $status: $output"
  [[ "$output" == *"etcdctl snapshot save"*"failed"* ]] || fail "$output"
  [ -z "$(snapshot_files)" ] || fail "$(snapshot_files)"
}

@test "without the k3s token there is no snapshot, since it could not be restored" {
  make_k3s_etcd
  rm "$(k3s_server)/token"
  run "$BIN/datastore-snapshot"
  [ "$status" -eq 2 ] || fail "status $status: $output"
  [ -z "$(snapshot_files)" ] || fail "$(snapshot_files)"
}

@test "a missing client certificate fails before etcdctl runs" {
  make_kubeadm
  rm "$HOST_ROOT/etc/kubernetes/pki/etcd/healthcheck-client.key"
  run "$BIN/datastore-snapshot"
  [ "$status" -eq 2 ] || fail "status $status: $output"
  [[ "$output" == *"/etc/kubernetes/pki/etcd/healthcheck-client.key not found"* ]] || fail "$output"
  [ ! -f "$TMP/etcdctl-argv" ] || fail "etcdctl ran"
}

@test "save replaces an earlier snapshot, clean removes it and nothing else" {
  make_k3s_etcd
  mkdir -p "$DATASTORE_SNAPSHOT_DIR/kubeadm"
  touch "$DATASTORE_SNAPSHOT_DIR/kubeadm/etcd-snapshot.db" "$DATASTORE_SNAPSHOT_DIR/other"
  run "$BIN/datastore-snapshot" save
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ ! -e "$DATASTORE_SNAPSHOT_DIR/kubeadm" ] || fail "the earlier snapshot is still there"
  run "$BIN/datastore-snapshot" clean
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(snapshot_files)" = "./other" ] || fail "$(snapshot_files)"
}

@test "an unknown command is a usage error" {
  run "$BIN/datastore-snapshot" restore
  [ "$status" -eq 2 ] || fail "status $status: $output"
}
