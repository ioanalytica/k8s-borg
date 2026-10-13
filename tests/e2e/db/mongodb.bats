#!/usr/bin/env bats
#
# backup-mongodb, backup-cluster-mongodb and restore-mongodb against real
# MongoDB servers (run by run.sh, one server version per run): the seeded
# replica set `src` is dumped with a credentials file in the chart's format,
# archived and extracted with Borg, and restored into the empty replica set
# `dst` and into `src` itself; every restore is compared with a fingerprint
# of the source taken at dump time. `dst2` is a standalone server, dumped
# without an oplog.

bats_require_minimum_version 1.5.0

load helpers/common
load helpers/mongodb

setup_file() {
  export E2E_TMP
  E2E_TMP=$(mktemp -d)
  for host in src dst dst2; do
    wait_for 120 mo ready "$host"
  done
  mo initiate src
  mo initiate dst

  mo seed src
  mo fingerprint src >"$E2E_TMP/src.fingerprint"
  mo fingerprint src appdb >"$E2E_TMP/appdb.fingerprint"

  # The chart mounts one credentials file per instance at /root/.mongodb;
  # the restores use files of the same name (the same instance) for the
  # other servers.
  write_conf /root/.mongodb/e2e.conf src
  write_conf "$E2E_TMP/dst/e2e.conf" dst

  export DUMPS="$E2E_TMP/dumps"
  DB_BACKUP_LOCATION=$DUMPS backup-cluster-mongodb >"$E2E_TMP/backup.log" 2>&1 \
    || { cat "$E2E_TMP/backup.log" >&2; return 1; }

  export REPO="$E2E_TMP/repo"
  borg_create "$REPO" first "$DUMPS" >/dev/null
  borg_extract "$REPO" first "$E2E_TMP/extracted"
  export RESTORED="$E2E_TMP/extracted$DUMPS"
}

teardown_file() {
  rm -rf "$E2E_TMP" /root/.mongodb
}

@test "backup-mongodb writes one uncompressed archive with the oplog, mode 600" {
  assert_dump_dir "$DUMPS/e2e" e2e.archive
  [ "$(mongodb-admin archive-oplog "$DUMPS/e2e/e2e.archive")" = yes ]
  [ "$(mongodb-admin archive-databases "$DUMPS/e2e/e2e.archive" | tr '\n' ' ')" = "admin appdb shop " ]
  grep -q 'replset' "$E2E_TMP/backup.log" || fail "$(cat "$E2E_TMP/backup.log")"
  # Uncompressed: the documents are in the archive as they are.
  grep -q 'Grüße aus Köln' "$DUMPS/e2e/e2e.archive"
}

@test "the archive comes out of the Borg archive unchanged, still mode 600" {
  cmp "$DUMPS/e2e/e2e.archive" "$RESTORED/e2e/e2e.archive"
  assert_dump_dir "$RESTORED/e2e" e2e.archive
}

@test "restore-mongodb --all restores the instance into an empty replica set" {
  run --separate-stderr env DB_BACKUP_LOCATION="$RESTORED" restore-mongodb "$E2E_TMP/dst/e2e.conf" --all
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  [[ "$output" == *"replaying its oplog"* ]] || fail "$output"
  mo fingerprint dst >"$E2E_TMP/dst.fingerprint"
  assert_same "$E2E_TMP/src.fingerprint" "$E2E_TMP/dst.fingerprint"
  # The restored users and roles are in force, not just in the collections.
  [ "$(mo login dst app app-pw appdb appdb)" = 2003 ]
  [ "$(mo login dst reader reader-pw admin appdb)" = 2003 ]
}

@test "restore-mongodb DATABASE replaces the database with its dump" {
  mo run src appdb 'db.items.insert_one({"_id": 99999, "name": "after the dump"}); db.items.drop_index("n_id"); db.extra.insert_one({}); db.drop_collection("item_names")'
  run --separate-stderr env DB_BACKUP_LOCATION="$RESTORED" restore-mongodb /root/.mongodb/e2e.conf appdb
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  mo fingerprint src appdb >"$E2E_TMP/appdb.restored"
  assert_same "$E2E_TMP/appdb.fingerprint" "$E2E_TMP/appdb.restored"
}

@test "restore-mongodb DATABASE --as NAME restores into NAME and leaves DATABASE alone, also over an existing NAME" {
  mo run src appdb 'db.only_in_the_original.insert_one({})'
  for _ in 1 2; do
    run --separate-stderr env DB_BACKUP_LOCATION="$RESTORED" restore-mongodb /root/.mongodb/e2e.conf appdb --as appdb_copy
    [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
    mo fingerprint src appdb_copy >"$E2E_TMP/copy.fingerprint"
    assert_same "$E2E_TMP/appdb.fingerprint" "$E2E_TMP/copy.fingerprint"
  done
  [ "$(mo run src appdb 'print(db.only_in_the_original.count_documents({}))')" = 1 ]
  # The copy's view reads the copy's collection.
  mo run src appdb_copy 'db.items.insert_one({"_id": 88888, "name": "in the copy"})'
  [ "$(mo run src appdb_copy 'print(db.item_names.count_documents({"name": "in the copy"}))')" = 1 ]
  [ "$(mo run src appdb 'print(db.items.count_documents({"name": "in the copy"}))')" = 0 ]
  mo run src appdb 'c.drop_database("appdb_copy"); db.drop_collection("only_in_the_original")'
}

@test "the backup role dumps everything, the users included; the restore role restores a database" {
  write_conf "$E2E_TMP/backup-user/e2e.conf" src e2e_backup backup-pw
  run --separate-stderr env DB_BACKUP_LOCATION="$E2E_TMP/user-dumps" backup-mongodb "$E2E_TMP/backup-user/e2e.conf"
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  assert_dump_dir "$E2E_TMP/user-dumps/e2e" e2e.archive
  [[ "$stderr" == *"done dumping admin.system.users"* ]] || fail "$stderr"

  mo run src appdb 'db.items.delete_many({})'
  write_conf "$E2E_TMP/restore-user/e2e.conf" src e2e_restore restore-pw
  run --separate-stderr env DB_BACKUP_LOCATION="$E2E_TMP/user-dumps" restore-mongodb "$E2E_TMP/restore-user/e2e.conf" appdb
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  [ "$(mo run src appdb 'print(db.items.count_documents({}))')" = 2003 ]
}

@test "a standalone server is dumped without an oplog and restored" {
  mo run dst2 'c.solo.items.insert_many([{"_id": i} for i in range(10)])'
  write_conf "$E2E_TMP/solo/e2e.conf" dst2
  run --separate-stderr env DB_BACKUP_LOCATION="$E2E_TMP/solo-dumps" backup-mongodb "$E2E_TMP/solo/e2e.conf"
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  [[ "$output" == *"(standalone)"* ]] || fail "$output"
  [ "$(mongodb-admin archive-oplog "$E2E_TMP/solo-dumps/e2e/e2e.archive")" = no ]
  mo run dst2 'c.solo.items.delete_many({})'
  run --separate-stderr env DB_BACKUP_LOCATION="$E2E_TMP/solo-dumps" restore-mongodb "$E2E_TMP/solo/e2e.conf" --all
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  [ "$(mo run dst2 'print(c.solo.items.count_documents({}))')" = 10 ]
}

@test "the Community operator's connection string, with admin in its path, dumps every database" {
  # The auth database in the path, as the operator writes it (the password
  # stays a field of its own here).
  write_conf "$E2E_TMP/operator/e2e.conf" src
  sed -i "s|src:27017/?authSource=admin|src:27017/admin?replicaSet=rs0|" "$E2E_TMP/operator/e2e.conf"
  grep -q "src:27017/admin?replicaSet=rs0" "$E2E_TMP/operator/e2e.conf"
  run --separate-stderr env DB_BACKUP_LOCATION="$E2E_TMP/operator-dumps" backup-mongodb "$E2E_TMP/operator/e2e.conf"
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  [ "$(mongodb-admin archive-databases "$E2E_TMP/operator-dumps/e2e/e2e.archive" | tr '\n' ' ')" = "admin appdb shop " ]
}

@test "restore-mongodb refuses what it cannot do, with rc 2, before anything is dropped" {
  export DB_BACKUP_LOCATION="$RESTORED"
  run --separate-stderr restore-mongodb /root/.mongodb/e2e.conf admin
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"restored with --all only"* ]] || fail "$stderr"
  run --separate-stderr restore-mongodb /root/.mongodb/e2e.conf apdb --as appdb
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"holds no database apdb (it holds: admin appdb shop)"* ]] || fail "$stderr"
  [ "$(mo run src appdb 'print(db.items.count_documents({}))')" = 2003 ] || fail "appdb was touched"
  run restore-mongodb
  [ "$status" -eq 2 ]
  run restore-mongodb /root/.mongodb/e2e.conf
  [ "$status" -eq 2 ]
  run restore-mongodb /root/.mongodb/e2e.conf --all appdb
  [ "$status" -eq 2 ]
  run restore-mongodb /root/.mongodb/e2e.conf appdb --as
  [ "$status" -eq 2 ]
  run restore-mongodb /root/.mongodb/e2e.conf appdb --as a.b
  [ "$status" -eq 2 ]
  run restore-mongodb /root/.mongodb/e2e.conf appdb --no-oplog
  [ "$status" -eq 2 ]
  run --separate-stderr env DB_BACKUP_LOCATION="$E2E_TMP/nowhere" restore-mongodb /root/.mongodb/e2e.conf --all
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"not found"* ]] || fail "$stderr"
}

@test "a failing restore ends with rc >= 2" {
  mkdir -p "$E2E_TMP/broken/e2e"
  echo "not an archive" >"$E2E_TMP/broken/e2e/e2e.archive"
  run env DB_BACKUP_LOCATION="$E2E_TMP/broken" restore-mongodb /root/.mongodb/e2e.conf --all
  [ "$status" -ge 2 ] || fail "rc=$status"
  write_conf "$E2E_TMP/badpw/e2e.conf" src root wrong
  run env DB_BACKUP_LOCATION="$RESTORED" restore-mongodb "$E2E_TMP/badpw/e2e.conf" shop
  [ "$status" -ge 2 ] || fail "rc=$status"
}

@test "backup-cluster-databases dumps only the engines in BORG_DB_ENGINES" {
  run env DB_BACKUP_LOCATION="$E2E_TMP/engines-none" BORG_DB_ENGINES="" backup-cluster-databases
  [ "$status" -eq 0 ] || fail "rc=$status: $output"
  [ ! -e "$E2E_TMP/engines-none" ] || fail "dumped: $(ls -R "$E2E_TMP/engines-none")"

  run env DB_BACKUP_LOCATION="$E2E_TMP/engines-mongodb" BORG_DB_ENGINES="mongodb" backup-cluster-databases
  [ "$status" -eq 0 ] || fail "rc=$status: $output"
  assert_dump_dir "$E2E_TMP/engines-mongodb/e2e" e2e.archive
}

@test "a failing dump fails with rc >= 2 and leaves the previous archive alone" {
  mkdir -p "$E2E_TMP/fail-dumps/e2e"
  echo previous >"$E2E_TMP/fail-dumps/e2e/e2e.archive"
  chmod 600 "$E2E_TMP/fail-dumps/e2e/e2e.archive"

  # A wrong password, a server that is not there, a user without the right
  # to dump.
  write_conf "$E2E_TMP/badpw/e2e.conf" src root wrong
  run env DB_BACKUP_LOCATION="$E2E_TMP/fail-dumps" backup-mongodb "$E2E_TMP/badpw/e2e.conf"
  [ "$status" -ge 2 ] || fail "rc=$status"
  write_conf "$E2E_TMP/nohost/e2e.conf" no-such-host
  run env DB_BACKUP_LOCATION="$E2E_TMP/fail-dumps" backup-mongodb "$E2E_TMP/nohost/e2e.conf"
  [ "$status" -ge 2 ] || fail "rc=$status"
  write_conf "$E2E_TMP/reader/e2e.conf" src reader reader-pw
  run env DB_BACKUP_LOCATION="$E2E_TMP/fail-dumps" backup-mongodb "$E2E_TMP/reader/e2e.conf"
  [ "$status" -ge 2 ] || fail "rc=$status"

  [ "$(cat "$E2E_TMP/fail-dumps/e2e/e2e.archive")" = previous ]
  assert_dump_dir "$E2E_TMP/fail-dumps/e2e" e2e.archive

  # backup-cluster-mongodb stops at the failing instance with its rc.
  cp "$E2E_TMP/reader/e2e.conf" /root/.mongodb/a-reader.conf
  run env DB_BACKUP_LOCATION="$E2E_TMP/fail-dumps" backup-cluster-mongodb
  rm -f /root/.mongodb/a-reader.conf
  [ "$status" -ge 2 ] || fail "rc=$status"
}

@test "Borg deduplicates the archives: an unchanged and a slightly changed instance add little" {
  local first unchanged changed
  # A repository of its own: the tests before changed src since the first
  # archive.
  DB_BACKUP_LOCATION=$DUMPS backup-cluster-mongodb >/dev/null 2>&1
  first=$(borg_create "$E2E_TMP/dedup-repo" first "$DUMPS")

  DB_BACKUP_LOCATION=$DUMPS backup-cluster-mongodb >/dev/null 2>&1
  unchanged=$(borg_create "$E2E_TMP/dedup-repo" unchanged "$DUMPS")

  # 100 documents changed in one place, 100 added.
  mo run src appdb 'db.bulk.update_many({"_id": {"$gte": 100000, "$lt": 100100}}, [{"$set": {"filler": {"$toUpper": "$filler"}}}]); db.bulk.insert_many([{"_id": 300000 + i, "filler": str(i)} for i in range(100)])'
  DB_BACKUP_LOCATION=$DUMPS backup-cluster-mongodb >/dev/null 2>&1
  changed=$(borg_create "$E2E_TMP/dedup-repo" changed "$DUMPS")

  echo "# archive $(wc -c <"$DUMPS/e2e/e2e.archive") bytes; added to the repository: first archive $first, unchanged $unchanged, changed $changed" >&3
  [ "$unchanged" -lt $((first / 2)) ] || fail "unchanged: $unchanged bytes new, the first archive added $first"
  [ "$changed" -lt $((first / 2)) ] || fail "changed: $changed bytes new, the first archive added $first"
}
