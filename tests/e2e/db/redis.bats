#!/usr/bin/env bats
#
# backup-redis and backup-cluster-redis against real Redis and Valkey servers
# (run by run.sh, one server version per run): the seeded standalone server
# `src` and the cluster of three primaries c1–c3 (TLS only, the nodes known
# by the hostnames they announce, which the certificate carries and no IP
# address) are dumped with config files
# in the chart's format and the ACL user chart/README.md documents, archived
# and extracted with Borg, and restored as chart/README.md describes it — the
# RDB file as dump.rdb of a server started on it (`dst`). Every restore is
# compared with a fingerprint of the source taken at dump time.

bats_require_minimum_version 1.5.0

load helpers/common
load helpers/redis

setup_file() {
  export E2E_TMP
  E2E_TMP=$(mktemp -d)
  for host in src dst c1 c2 c3; do
    wait_for 60 rd_ready "$host"
  done

  rd_seed src
  rd_cluster
  for host in src c1 c2 c3; do
    rd_backup_user "$host"
  done
  rd_fingerprint src >"$E2E_TMP/src.fingerprint"
  rd_cluster_fingerprint >"$E2E_TMP/cluster.fingerprint"

  # The chart mounts one config file per instance at /root/.redis; the
  # cluster is reached through any one of its nodes.
  write_conf /root/.redis/e2e.conf src
  write_conf /root/.redis/e2e-cluster.conf c2 tls=true cacert=/tls/ca.crt

  export DUMPS="$E2E_TMP/dumps"
  DB_BACKUP_LOCATION=$DUMPS backup-cluster-redis >"$E2E_TMP/backup.log" 2>&1 \
    || { cat "$E2E_TMP/backup.log" >&2; return 1; }

  export REPO="$E2E_TMP/repo"
  borg_create "$REPO" first "$DUMPS" >/dev/null
  borg_extract "$REPO" first "$E2E_TMP/extracted"
  export RESTORED="$E2E_TMP/extracted$DUMPS"
}

teardown_file() {
  rm -rf "$E2E_TMP" /root/.redis
}

@test "backup-redis writes one RDB file of the standalone server, mode 600" {
  assert_dump_dir "$DUMPS/e2e" e2e.rdb
  local magic
  magic=$(head -c 9 "$DUMPS/e2e/e2e.rdb")
  if rd_valkey9; then
    # The server's own format: the version redis-rdb-sync announced.
    [ "$magic" = VALKEY080 ] || fail "magic $magic"
  else
    [[ $magic == REDIS* ]] || fail "magic $magic"
  fi
}

@test "a cluster: one RDB file per primary, named after its slots, and CLUSTER NODES" {
  assert_dump_dir "$DUMPS/e2e-cluster" e2e-cluster-cluster-nodes.txt \
    e2e-cluster-slots-0-5460.rdb e2e-cluster-slots-5461-10922.rdb e2e-cluster-slots-10923-16383.rdb
  [ "$(grep -c master "$DUMPS/e2e-cluster/e2e-cluster-cluster-nodes.txt")" -eq 3 ]
}

@test "the dumps come out of the Borg archive unchanged, still mode 600" {
  for file in "$DUMPS"/*/*; do
    cmp "$file" "$RESTORED/${file#"$DUMPS"/}"
  done
  assert_dump_dir "$RESTORED/e2e" e2e.rdb
}

@test "the RDB file as dump.rdb of a server started on it: the instance, every database, the TTLs" {
  rd_restore "$RESTORED/e2e/e2e.rdb"
  rd_fingerprint dst >"$E2E_TMP/dst.fingerprint"
  assert_same "$E2E_TMP/src.fingerprint" "$E2E_TMP/dst.fingerprint"
  [ "$(rd dst TTL ttl)" -gt 80000 ] || fail "TTL $(rd dst TTL ttl)"
  if rd_valkey9; then
    # The field a keeps its TTL, b has none.
    [[ "$(rd dst HTTL hft FIELDS 2 a b | tr '\n' ' ')" =~ ^[0-9]{5}\ -1\ $ ]] \
      || fail "HTTL $(rd dst HTTL hft FIELDS 2 a b | tr '\n' ' ')"
  fi
}

@test "the primaries' RDB files restored one after another hold the whole cluster" {
  local file
  : >"$E2E_TMP/restored-cluster.fingerprint"
  for file in "$RESTORED"/e2e-cluster/*.rdb; do
    rd_restore "$file"
    rd_fingerprint dst 0 >>"$E2E_TMP/restored-cluster.fingerprint"
  done
  LC_ALL=C sort -o "$E2E_TMP/restored-cluster.fingerprint" "$E2E_TMP/restored-cluster.fingerprint"
  assert_same "$E2E_TMP/cluster.fingerprint" "$E2E_TMP/restored-cluster.fingerprint"
  [ "$(wc -l <"$E2E_TMP/cluster.fingerprint")" -eq 3000 ]
}

@test "a dump that fails ends with rc >= 2 and leaves the previous dump alone" {
  local before
  before=$(md5sum "$DUMPS"/e2e/*)
  rd src ACL SETUSER nosync on '>nosync' +info >/dev/null
  write_conf "$E2E_TMP/fail/e2e.conf" src
  sed -i 's/^user=.*/user=nosync/; s/^password=.*/password=nosync/' "$E2E_TMP/fail/e2e.conf"
  for conf in "$E2E_TMP/fail/e2e.conf" "$E2E_TMP/wrong/e2e.conf" "$E2E_TMP/nohost/e2e.conf"; do
    case "$conf" in
      */wrong/*)  write_conf "$conf" src; sed -i 's/^password=.*/password=wrong/' "$conf" ;;
      */nohost/*) write_conf "$conf" no-such-host ;;
    esac
    run --separate-stderr env DB_BACKUP_LOCATION="$DUMPS" backup-redis "$conf"
    [ "$status" -ge 2 ] || fail "$conf: rc=$status"
    [ "$(md5sum "$DUMPS"/e2e/*)" = "$before" ] || fail "$conf: the previous dump changed"
  done
}

@test "TLS: a node reached by a name its certificate does not carry fails with rc 2; insecure=true dumps" {
  local ip
  ip=$(getent hosts c2 | awk '{print $1}')
  write_conf "$E2E_TMP/by-ip/e2e-cluster.conf" "$ip" tls=true cacert=/tls/ca.crt
  run --separate-stderr env DB_BACKUP_LOCATION="$E2E_TMP/by-ip-dumps" backup-redis "$E2E_TMP/by-ip/e2e-cluster.conf"
  [ "$status" -ge 2 ] || fail "rc=$status"
  [[ $stderr == *"$ip"* ]] || fail "$stderr"
  write_conf "$E2E_TMP/insecure/e2e-cluster.conf" "$ip" insecure=true
  run --separate-stderr env DB_BACKUP_LOCATION="$E2E_TMP/insecure-dumps" backup-redis "$E2E_TMP/insecure/e2e-cluster.conf"
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  [ "$(ls "$E2E_TMP"/insecure-dumps/e2e-cluster/*.rdb | wc -l)" -eq 3 ]
}

@test "backup-cluster-databases dumps Redis only when BORG_DB_ENGINES names it" {
  run env DB_BACKUP_LOCATION="$E2E_TMP/engines-off" BORG_DB_ENGINES="" backup-cluster-databases
  [ "$status" -eq 0 ] && [ ! -e "$E2E_TMP/engines-off" ] || fail "rc=$status, $(ls "$E2E_TMP/engines-off" 2>&1)"
  run env DB_BACKUP_LOCATION="$E2E_TMP/engines-on" BORG_DB_ENGINES=redis backup-cluster-databases
  [ "$status" -eq 0 ] || fail "rc=$status: $output"
  assert_dump_dir "$E2E_TMP/engines-on/e2e" e2e.rdb
}

@test "Borg deduplicates the dumps: an unchanged instance and a changed key add little" {
  local first unchanged changed
  # About 50 MB: Borg's chunks are about 2 MiB, and up to 8 MiB.
  rd_bulk src 20001 100000
  DB_BACKUP_LOCATION=$DUMPS backup-redis /root/.redis/e2e.conf >/dev/null
  first=$(borg_create "$E2E_TMP/dedup-repo" first "$DUMPS/e2e")

  DB_BACKUP_LOCATION=$DUMPS backup-redis /root/.redis/e2e.conf >/dev/null
  unchanged=$(borg_create "$E2E_TMP/dedup-repo" unchanged "$DUMPS/e2e")

  rd src SET bulk:60000 changed >/dev/null
  DB_BACKUP_LOCATION=$DUMPS backup-redis /root/.redis/e2e.conf >/dev/null
  changed=$(borg_create "$E2E_TMP/dedup-repo" changed "$DUMPS/e2e")

  # Two snapshots of an unchanged server differ in a few bytes of the header
  # and the checksum at the end: the first and the last chunk are new. The
  # keys are in the server's hash order, so changes land all over the file,
  # each one making its chunk new (measured with three: 11–52 %). One changed
  # key: three chunks at most, below half of the first archive also with
  # chunks of 8 MiB. Measured: unchanged 4–14 %, one changed key 9–23 %.
  echo "# dump $(wc -c <"$DUMPS/e2e/e2e.rdb") bytes; added to the repository: first archive $first, unchanged $unchanged, changed $changed" >&3
  [ "$unchanged" -lt $((first / 4)) ] || fail "unchanged: $unchanged bytes new, the first archive added $first"
  [ "$changed" -lt $((first / 2)) ] || fail "changed: $changed bytes new, the first archive added $first"
}
