#!/usr/bin/env bats
#
# backup-mariadb, backup-cluster-mariadb and restore-mariadb against real
# MariaDB servers (run by run.sh, one server version per run): the seeded
# instance on `src` is dumped with the chart's defaults file, archived and
# extracted with Borg, and restored into the empty server `dst` and into
# `src` itself; every restore is compared with a fingerprint of the source
# taken at dump time.

bats_require_minimum_version 1.5.0

load helpers/common
load helpers/mariadb

ALL_DUMPS="appdb.sql mysql.sql shop.sql e2e-full-dump.sql"

setup_file() {
  export E2E_TMP
  E2E_TMP=$(mktemp -d)
  my_setup_admin
  for host in src dst dst2; do
    wait_for 120 my_ready "$host"
  done

  my_seed src
  my_fingerprint src >"$E2E_TMP/src.fingerprint"
  my_db_fingerprint src appdb >"$E2E_TMP/appdb.fingerprint"

  # The chart mounts one defaults file per instance at /root/.mariadb; the
  # restores use files of the same name (the same instance) for the other
  # servers.
  write_conf /root/.mariadb/e2e.conf src
  write_conf "$E2E_TMP/dst/e2e.conf" dst
  write_conf "$E2E_TMP/dst2/e2e.conf" dst2

  export DUMPS="$E2E_TMP/dumps"
  DB_BACKUP_LOCATION=$DUMPS backup-cluster-mariadb >"$E2E_TMP/backup.log" 2>&1 \
    || { cat "$E2E_TMP/backup.log" >&2; return 1; }

  export REPO="$E2E_TMP/repo"
  borg_create "$REPO" first "$DUMPS" >/dev/null
  borg_extract "$REPO" first "$E2E_TMP/extracted"
  export RESTORED="$E2E_TMP/extracted$DUMPS"
}

teardown_file() {
  rm -rf "$E2E_TMP" /root/.mariadb
}

@test "backup-mariadb writes one uncompressed dump per database and one of the instance, mode 600" {
  # shellcheck disable=SC2086
  assert_dump_dir "$DUMPS/e2e" $ALL_DUMPS
  for dump in "$DUMPS"/e2e/*.sql; do
    head -c 200 "$dump" | grep -q -- '-- MariaDB dump' || fail "$dump is no plain SQL dump"
  done
}

@test "the dump of a single database carries its routines, triggers and events" {
  grep -q 'PROCEDURE `add_item`' "$DUMPS/e2e/appdb.sql"
  grep -q 'FUNCTION `item_count`' "$DUMPS/e2e/appdb.sql"
  grep -Eq 'TRIGGER `?items_ai' "$DUMPS/e2e/appdb.sql"
  grep -q 'EVENT `purge_audit`' "$DUMPS/e2e/appdb.sql"
}

@test "the dumps come out of the Borg archive unchanged, still mode 600" {
  for file in "$DUMPS"/e2e/*; do
    cmp "$file" "$RESTORED/e2e/${file##*/}"
  done
  # shellcheck disable=SC2086
  assert_dump_dir "$RESTORED/e2e" $ALL_DUMPS
}

@test "restore-mariadb --all restores the instance into an empty server" {
  run --separate-stderr env DB_BACKUP_LOCATION="$RESTORED" restore-mariadb "$E2E_TMP/dst/e2e.conf" --all
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  my_fingerprint dst >"$E2E_TMP/dst.fingerprint"
  assert_same "$E2E_TMP/src.fingerprint" "$E2E_TMP/dst.fingerprint"
  # The restored users and grants are in force, not just in the tables.
  write_conf "$E2E_TMP/app.cnf" dst app app-pw
  [ "$(mariadb --defaults-file="$E2E_TMP/app.cnf" -N -B appdb -e 'SELECT COUNT(*) FROM items')" = 2003 ]
}

@test "restore-mariadb DATABASE replaces the database with its dump" {
  my src appdb -e "INSERT INTO items (name) VALUES ('after the dump'); DROP TRIGGER items_ai; DROP EVENT purge_audit; CREATE TABLE extra (id INT);"
  run --separate-stderr env DB_BACKUP_LOCATION="$RESTORED" restore-mariadb /root/.mariadb/e2e.conf appdb
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  my_db_fingerprint src appdb >"$E2E_TMP/appdb.restored"
  assert_same "$E2E_TMP/appdb.fingerprint" "$E2E_TMP/appdb.restored"
}

@test "restore-mariadb DATABASE --as NAME restores into NAME and leaves DATABASE alone, also over an existing NAME" {
  my src appdb -e "CREATE TABLE only_in_the_original (id INT)"
  for _ in 1 2; do
    run --separate-stderr env DB_BACKUP_LOCATION="$RESTORED" restore-mariadb /root/.mariadb/e2e.conf appdb --as appdb_copy
    [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
    my_db_fingerprint src appdb_copy >"$E2E_TMP/copy.fingerprint"
    assert_same "$E2E_TMP/appdb.fingerprint" "$E2E_TMP/copy.fingerprint"
  done
  [ "$(my src appdb -e "SHOW TABLES LIKE 'only_in_the_original'")" = only_in_the_original ]
  # The copy's view and trigger work on the copy's tables.
  my src appdb_copy -e "INSERT INTO items (name) VALUES ('in the copy')"
  [ "$(my src appdb_copy -e "SELECT COUNT(*) FROM audit WHERE item_id = (SELECT id FROM items WHERE name = 'in the copy')")" = 1 ]
  [ "$(my src appdb_copy -e "SELECT COUNT(*) FROM item_names WHERE name = 'in the copy'")" = 1 ]
  [ "$(my src appdb -e "SELECT COUNT(*) FROM items WHERE name = 'in the copy'")" = 0 ]
  my src -e "DROP DATABASE appdb_copy; DROP TABLE appdb.only_in_the_original"
}

@test "restore-mariadb refuses the mysql schema without --all, and what it cannot do, with rc 2" {
  export DB_BACKUP_LOCATION="$RESTORED"
  run --separate-stderr restore-mariadb /root/.mariadb/e2e.conf mysql
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"restored with --all"* ]] || fail "$stderr"
  run restore-mariadb
  [ "$status" -eq 2 ]
  run restore-mariadb /root/.mariadb/e2e.conf
  [ "$status" -eq 2 ]
  run restore-mariadb /root/.mariadb/e2e.conf --all appdb
  [ "$status" -eq 2 ]
  run restore-mariadb /root/.mariadb/e2e.conf --all --as other
  [ "$status" -eq 2 ]
  run restore-mariadb /root/.mariadb/e2e.conf appdb --as
  [ "$status" -eq 2 ]
  run restore-mariadb /root/.mariadb/e2e.conf appdb --bogus
  [ "$status" -eq 2 ]
  run --separate-stderr restore-mariadb /root/.mariadb/e2e.conf nosuchdb
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"nosuchdb.sql not found"* ]] || fail "$stderr"

  # A compressed dump of a release before: named, with what to do.
  mkdir -p "$E2E_TMP/old/e2e"
  : >"$E2E_TMP/old/e2e/appdb.sql.gz"
  run --separate-stderr env DB_BACKUP_LOCATION="$E2E_TMP/old" restore-mariadb /root/.mariadb/e2e.conf appdb
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"appdb.sql.gz"*"gunzip -k"* ]] || fail "$stderr"
}

@test "a failing restore ends with rc >= 2" {
  mkdir -p "$E2E_TMP/broken/e2e"
  echo "THIS IS NOT SQL;" >"$E2E_TMP/broken/e2e/appdb.sql"
  run env DB_BACKUP_LOCATION="$E2E_TMP/broken" restore-mariadb "$E2E_TMP/dst2/e2e.conf" appdb
  [ "$status" -ge 2 ] || fail "rc=$status"
  write_conf "$E2E_TMP/badpw/e2e.conf" dst2 root wrong
  run env DB_BACKUP_LOCATION="$RESTORED" restore-mariadb "$E2E_TMP/badpw/e2e.conf" appdb
  [ "$status" -ge 2 ] || fail "rc=$status"
}

@test "a backup user with global read privileges dumps every database and the instance" {
  my src -e "CREATE USER 'e2e_backup'@'%' IDENTIFIED BY 'backup';
             GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, SHOW DATABASES ON *.* TO 'e2e_backup'@'%';"
  write_conf "$E2E_TMP/backup-user/e2e.conf" src e2e_backup backup
  run --separate-stderr env DB_BACKUP_LOCATION="$E2E_TMP/user-dumps" backup-mariadb "$E2E_TMP/backup-user/e2e.conf"
  my src -e "DROP USER 'e2e_backup'@'%'"
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  # shellcheck disable=SC2086
  assert_dump_dir "$E2E_TMP/user-dumps/e2e" $ALL_DUMPS
  grep -q 'PROCEDURE `add_item`' "$E2E_TMP/user-dumps/e2e/appdb.sql"
  grep -q 'EVENT `purge_audit`' "$E2E_TMP/user-dumps/e2e/appdb.sql"
}

@test "a failing dump fails with rc >= 2 and leaves the previous dumps alone" {
  mkdir -p "$E2E_TMP/fail-dumps/e2e"
  echo previous >"$E2E_TMP/fail-dumps/e2e/shop.sql"
  echo previous >"$E2E_TMP/fail-dumps/e2e/shop.sql.gz"

  # A user that sees every database, but may read appdb only: the dump of
  # the next one fails.
  my src -e "CREATE USER 'e2e_limited'@'%' IDENTIFIED BY 'limited';
             GRANT SHOW DATABASES ON *.* TO 'e2e_limited'@'%';
             GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES ON appdb.* TO 'e2e_limited'@'%';"
  write_conf "$E2E_TMP/limited/e2e.conf" src e2e_limited limited
  run --separate-stderr env DB_BACKUP_LOCATION="$E2E_TMP/fail-dumps" backup-mariadb "$E2E_TMP/limited/e2e.conf"
  [ "$status" -ge 2 ] || fail "rc=$status: $stderr"
  [ "$(cat "$E2E_TMP/fail-dumps/e2e/shop.sql")" = previous ]
  [ "$(cat "$E2E_TMP/fail-dumps/e2e/shop.sql.gz")" = previous ]

  # A wrong password, a server that is not there.
  write_conf "$E2E_TMP/badpw/e2e.conf" src root wrong
  run env DB_BACKUP_LOCATION="$E2E_TMP/fail-dumps" backup-mariadb "$E2E_TMP/badpw/e2e.conf"
  [ "$status" -ge 2 ] || fail "rc=$status"
  write_conf "$E2E_TMP/nohost/e2e.conf" no-such-host
  run env DB_BACKUP_LOCATION="$E2E_TMP/fail-dumps" backup-mariadb "$E2E_TMP/nohost/e2e.conf"
  [ "$status" -ge 2 ] || fail "rc=$status"

  # backup-cluster-mariadb stops at the failing instance with its rc.
  cp "$E2E_TMP/limited/e2e.conf" /root/.mariadb/a-limited.conf
  run env DB_BACKUP_LOCATION="$E2E_TMP/fail-dumps" backup-cluster-mariadb
  rm -f /root/.mariadb/a-limited.conf
  [ "$status" -ge 2 ] || fail "rc=$status"
  my src -e "DROP USER 'e2e_limited'@'%'"
}

@test "a successful dump removes the compressed dumps of earlier releases and nothing else" {
  mkdir -p "$E2E_TMP/old-dumps/e2e"
  for file in appdb.sql.gz e2e-full-dump.sql.gz gone.sql.gz appdb.sql.tmp notes.txt; do
    echo old >"$E2E_TMP/old-dumps/e2e/$file"
  done
  chmod 600 "$E2E_TMP/old-dumps/e2e/notes.txt"
  run env DB_BACKUP_LOCATION="$E2E_TMP/old-dumps" backup-mariadb /root/.mariadb/e2e.conf
  [ "$status" -eq 0 ] || fail "rc=$status: $output"
  # shellcheck disable=SC2086
  assert_dump_dir "$E2E_TMP/old-dumps/e2e" $ALL_DUMPS notes.txt
}

@test "Borg deduplicates the dumps: an unchanged and a slightly changed instance add little" {
  local first unchanged changed
  # A repository of its own: the tests before changed src since the first
  # archive.
  DB_BACKUP_LOCATION=$DUMPS backup-cluster-mariadb >/dev/null
  first=$(borg_create "$E2E_TMP/dedup-repo" first "$DUMPS")

  DB_BACKUP_LOCATION=$DUMPS backup-cluster-mariadb >/dev/null
  unchanged=$(borg_create "$E2E_TMP/dedup-repo" unchanged "$DUMPS")

  # 100 rows updated in one place, 100 added.
  my src appdb -e "UPDATE bulk SET filler = UPPER(filler) WHERE id BETWEEN 100001 AND 100100;
                   INSERT INTO bulk SELECT seq, MD5(seq) FROM seq_200001_to_200100;"
  DB_BACKUP_LOCATION=$DUMPS backup-cluster-mariadb >/dev/null
  changed=$(borg_create "$E2E_TMP/dedup-repo" changed "$DUMPS")

  # Measured: unchanged 0–2 %, changed 20–40 % of the first archive (Borg's
  # chunks are about 2 MiB). The gzipped dumps before added 100 % (PostgreSQL)
  # and 74 % (MariaDB, changed) — compressed, a dump is new from its first
  # changed byte on.
  echo "# dumps $(cat "$DUMPS"/*/* | wc -c) bytes; added to the repository: first archive $first, unchanged $unchanged, changed $changed" >&3
  [ "$unchanged" -lt $((first / 2)) ] || fail "unchanged: $unchanged bytes new, the first archive added $first"
  [ "$changed" -lt $((first / 2)) ] || fail "changed: $changed bytes new, the first archive added $first"
}
