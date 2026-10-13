#!/usr/bin/env bats
#
# backup-mysql, backup-cluster-mysql and restore-mysql against real MySQL and
# Percona servers with GTIDs on (run by run.sh, one server version per run):
# the seeded instance on `src` is dumped with the chart's defaults file,
# archived and extracted with Borg, and restored into the empty server `dst`
# and into `src` itself; every restore is compared with a fingerprint of the
# source taken at dump time.

bats_require_minimum_version 1.5.0

load helpers/common
load helpers/mysql

ALL_DUMPS="appdb.sql mysql.sql shop.sql e2e-full-dump.sql"

setup_file() {
  export E2E_TMP
  E2E_TMP=$(mktemp -d)
  my_setup_admin
  for host in src dst dst2; do
    wait_for 180 my_ready "$host"
  done

  my_seed src
  my_fingerprint src >"$E2E_TMP/src.fingerprint"
  my_db_fingerprint src appdb >"$E2E_TMP/appdb.fingerprint"

  # The chart mounts one defaults file per instance at /root/.mysql; the
  # restores use files of the same name (the same instance) for the other
  # servers.
  write_conf /root/.mysql/e2e.conf src
  write_conf "$E2E_TMP/dst/e2e.conf" dst
  write_conf "$E2E_TMP/dst2/e2e.conf" dst2

  export DUMPS="$E2E_TMP/dumps"
  DB_BACKUP_LOCATION=$DUMPS backup-cluster-mysql >"$E2E_TMP/backup.log" 2>&1 \
    || { cat "$E2E_TMP/backup.log" >&2; return 1; }

  export REPO="$E2E_TMP/repo"
  borg_create "$REPO" first "$DUMPS" >/dev/null
  borg_extract "$REPO" first "$E2E_TMP/extracted"
  export RESTORED="$E2E_TMP/extracted$DUMPS"
}

teardown_file() {
  rm -rf "$E2E_TMP" /root/.mysql
}

@test "backup-mysql writes one uncompressed MySQL dump per database and one of the instance, mode 600" {
  # shellcheck disable=SC2086
  assert_dump_dir "$DUMPS/e2e" $ALL_DUMPS
  for dump in "$DUMPS"/e2e/*.sql; do
    head -c 200 "$dump" | grep -q -- '-- MySQL dump' || fail "$dump is no mysqldump dump"
  done
}

@test "the dump of a single database carries its routines, triggers and events" {
  grep -q 'PROCEDURE `add_item`' "$DUMPS/e2e/appdb.sql"
  grep -q 'FUNCTION `item_count`' "$DUMPS/e2e/appdb.sql"
  grep -Eq 'TRIGGER `?items_ai' "$DUMPS/e2e/appdb.sql"
  grep -q 'EVENT `purge_audit`' "$DUMPS/e2e/appdb.sql"
}

@test "the dumps carry no GTIDs and no values of generated columns" {
  ! grep -l 'GTID_PURGED' "$DUMPS"/e2e/*.sql || fail "GTID_PURGED in a dump"
  # The column list of the INSERTs leaves out total and label.
  grep -q 'INSERT INTO `items` (`id`, `name`, `price`, `qty`, `doc`, `note`, `payload`)' "$DUMPS/e2e/appdb.sql" \
    || fail "$(grep -m1 'INSERT INTO `items`' "$DUMPS/e2e/appdb.sql" | cut -c1-200)"
}

@test "the dumps come out of the Borg archive unchanged, still mode 600" {
  for file in "$DUMPS"/e2e/*; do
    cmp "$file" "$RESTORED/e2e/${file##*/}"
  done
  # shellcheck disable=SC2086
  assert_dump_dir "$RESTORED/e2e" $ALL_DUMPS
}

@test "restore-mysql --all restores the instance into an empty server" {
  run --separate-stderr env DB_BACKUP_LOCATION="$RESTORED" restore-mysql "$E2E_TMP/dst/e2e.conf" --all
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  my_fingerprint dst >"$E2E_TMP/dst.fingerprint"
  assert_same "$E2E_TMP/src.fingerprint" "$E2E_TMP/dst.fingerprint"
  # The restored users, grants and default roles are in force, not just in
  # the tables.
  write_conf "$E2E_TMP/app.cnf" dst app app-pw
  [ "$("$MYSQL" --defaults-file="$E2E_TMP/app.cnf" -N -B appdb -e 'SELECT COUNT(*) FROM items')" = 2003 ]
  [ "$("$MYSQL" --defaults-file="$E2E_TMP/app.cnf" -N -B -e 'SELECT COUNT(*) FROM shop.products')" = 2 ]
  # The server keeps its own GTIDs: none of the source's came along.
  src_uuid=$(my src -e 'SELECT @@server_uuid')
  [[ "$(my dst -e 'SELECT @@gtid_executed')" != *"$src_uuid"* ]] || fail "dst has the source's GTIDs"
}

@test "restore-mysql DATABASE replaces the database with its dump, into a server with GTIDs" {
  my src appdb -e "INSERT INTO items (name) VALUES ('after the dump'); DROP TRIGGER items_ai; DROP EVENT purge_audit; CREATE TABLE extra (id INT PRIMARY KEY);"
  run --separate-stderr env DB_BACKUP_LOCATION="$RESTORED" restore-mysql /root/.mysql/e2e.conf appdb
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  my_db_fingerprint src appdb >"$E2E_TMP/appdb.restored"
  assert_same "$E2E_TMP/appdb.fingerprint" "$E2E_TMP/appdb.restored"
}

@test "restore-mysql restores one database after another into a fresh server" {
  for db in appdb shop; do
    run --separate-stderr env DB_BACKUP_LOCATION="$RESTORED" restore-mysql "$E2E_TMP/dst2/e2e.conf" "$db"
    [ "$status" -eq 0 ] || fail "$db: rc=$status: $stderr"
  done
  my_db_fingerprint dst2 appdb >"$E2E_TMP/appdb.dst2"
  assert_same "$E2E_TMP/appdb.fingerprint" "$E2E_TMP/appdb.dst2"
  [ "$(my dst2 shop -e 'SELECT COUNT(*) FROM products')" = 2 ]
}

@test "restore-mysql DATABASE --as NAME restores into NAME and leaves DATABASE alone, also over an existing NAME" {
  my src appdb -e "CREATE TABLE only_in_the_original (id INT PRIMARY KEY)"
  for _ in 1 2; do
    run --separate-stderr env DB_BACKUP_LOCATION="$RESTORED" restore-mysql /root/.mysql/e2e.conf appdb --as appdb_copy
    [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
    my_db_fingerprint src appdb_copy >"$E2E_TMP/copy.fingerprint"
    assert_same "$E2E_TMP/appdb.fingerprint" "$E2E_TMP/copy.fingerprint"
  done
  [ "$(my src appdb -e "SHOW TABLES LIKE 'only_in_the_original'")" = only_in_the_original ]
  # The copy's view, trigger and generated columns work on the copy's tables.
  my src appdb_copy -e "INSERT INTO items (name, price, qty) VALUES ('in the copy', 2.50, 4)"
  [ "$(my src appdb_copy -e "SELECT COUNT(*) FROM audit WHERE item_id = (SELECT id FROM items WHERE name = 'in the copy')")" = 1 ]
  [ "$(my src appdb_copy -e "SELECT total FROM item_names WHERE name = 'in the copy'")" = 10.00 ]
  [ "$(my src appdb -e "SELECT COUNT(*) FROM items WHERE name = 'in the copy'")" = 0 ]
  my src -e "DROP DATABASE appdb_copy; DROP TABLE appdb.only_in_the_original"
}

@test "restore-mysql refuses the mysql schema without --all, and what it cannot do, with rc 2" {
  export DB_BACKUP_LOCATION="$RESTORED"
  run --separate-stderr restore-mysql /root/.mysql/e2e.conf mysql
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"restored with --all"* ]] || fail "$stderr"
  run restore-mysql
  [ "$status" -eq 2 ]
  run restore-mysql /root/.mysql/e2e.conf --all --as other
  [ "$status" -eq 2 ]
  run --separate-stderr restore-mysql /root/.mysql/e2e.conf nosuchdb
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"nosuchdb.sql not found"* ]] || fail "$stderr"
}

@test "a failing restore ends with rc >= 2, reported once" {
  mkdir -p "$E2E_TMP/broken/e2e"
  echo "THIS IS NOT SQL;" >"$E2E_TMP/broken/e2e/appdb.sql"
  run --separate-stderr env DB_BACKUP_LOCATION="$E2E_TMP/broken" restore-mysql "$E2E_TMP/dst2/e2e.conf" appdb
  [ "$status" -ge 2 ] || fail "rc=$status"
  run --separate-stderr env DB_BACKUP_LOCATION="$E2E_TMP/broken" restore-mysql "$E2E_TMP/dst2/e2e.conf" appdb --as other
  [ "$status" -ge 2 ] || fail "rc=$status"
  [ "$(grep -c 'restore failed' <<<"$stderr")" = 1 ] || fail "$stderr"
  write_conf "$E2E_TMP/badpw/e2e.conf" dst2 root wrong
  run env DB_BACKUP_LOCATION="$RESTORED" restore-mysql "$E2E_TMP/badpw/e2e.conf" appdb
  [ "$status" -ge 2 ] || fail "rc=$status"
}

@test "a backup user with global read privileges dumps every database and the instance" {
  my src -e "CREATE USER 'e2e_backup'@'%' IDENTIFIED BY 'backup';
             GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, SHOW DATABASES, PROCESS ON *.* TO 'e2e_backup'@'%';"
  write_conf "$E2E_TMP/backup-user/e2e.conf" src e2e_backup backup
  run --separate-stderr env DB_BACKUP_LOCATION="$E2E_TMP/user-dumps" backup-mysql "$E2E_TMP/backup-user/e2e.conf"
  my src -e "DROP USER 'e2e_backup'@'%'"
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  # shellcheck disable=SC2086
  assert_dump_dir "$E2E_TMP/user-dumps/e2e" $ALL_DUMPS
  grep -q 'PROCEDURE `add_item`' "$E2E_TMP/user-dumps/e2e/appdb.sql"
  grep -q 'EVENT `purge_audit`' "$E2E_TMP/user-dumps/e2e/appdb.sql"
}

@test "without TLS (the resolver's options for tls: false) a caching_sha2_password user logs in and dumps" {
  # A user of its own: its password is in no server cache yet, so the login
  # takes the full exchange, which without TLS needs the server's public key.
  my src -e "CREATE USER 'e2e_plain'@'%' IDENTIFIED WITH caching_sha2_password BY 'plain';
             GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, SHOW DATABASES, PROCESS ON *.* TO 'e2e_plain'@'%';"
  write_conf "$E2E_TMP/plain/e2e.conf" src e2e_plain plain ssl-mode=DISABLED get-server-public-key
  run --separate-stderr env DB_BACKUP_LOCATION="$E2E_TMP/plain-dumps" backup-mysql "$E2E_TMP/plain/e2e.conf"
  cipher=$("$MYSQL" --defaults-file="$E2E_TMP/plain/e2e.conf" -N -B -e "SHOW SESSION STATUS LIKE 'Ssl_cipher'" | cut -f2)
  my src -e "DROP USER 'e2e_plain'@'%'"
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  [ -z "$cipher" ] || fail "connected with TLS: $cipher"
  # shellcheck disable=SC2086
  assert_dump_dir "$E2E_TMP/plain-dumps/e2e" $ALL_DUMPS
}

@test "backup-mariadb and restore-mariadb refuse a MySQL server with rc 2, naming databases.mysql" {
  # Without skip-ssl the MariaDB client already fails at MySQL's self-signed
  # certificate; with it (a MariaDB instance with tls: false), it would dump.
  write_conf "$E2E_TMP/as-mariadb/e2e.conf" src root "$DB_PASSWORD" skip-ssl
  run --separate-stderr env DB_BACKUP_LOCATION="$E2E_TMP/wrong-engine" backup-mariadb "$E2E_TMP/as-mariadb/e2e.conf"
  [ "$status" -eq 2 ] || fail "rc=$status: $stderr"
  [[ "$stderr" == *"not MariaDB: configure the instance under databases.mysql"* ]] || fail "$stderr"
  [ ! -e "$E2E_TMP/wrong-engine/e2e" ] || fail "dumped: $(ls "$E2E_TMP/wrong-engine/e2e")"
  run --separate-stderr env DB_BACKUP_LOCATION="$RESTORED" restore-mariadb "$E2E_TMP/as-mariadb/e2e.conf" appdb
  [ "$status" -eq 2 ] || fail "rc=$status: $stderr"
  [[ "$stderr" == *"databases.mysql"* ]] || fail "$stderr"
}

@test "backup-cluster-databases dumps only the engines in BORG_DB_ENGINES" {
  run env DB_BACKUP_LOCATION="$E2E_TMP/engines-mariadb" BORG_DB_ENGINES="mariadb" backup-cluster-databases
  [ "$status" -eq 0 ] || fail "rc=$status: $output"
  [ ! -e "$E2E_TMP/engines-mariadb" ] || fail "dumped: $(ls -R "$E2E_TMP/engines-mariadb")"

  run env DB_BACKUP_LOCATION="$E2E_TMP/engines-mysql" BORG_DB_ENGINES="mysql" backup-cluster-databases
  [ "$status" -eq 0 ] || fail "rc=$status: $output"
  # shellcheck disable=SC2086
  assert_dump_dir "$E2E_TMP/engines-mysql/e2e" $ALL_DUMPS
}

@test "a failing dump fails with rc >= 2, reported once, and leaves the previous dumps alone" {
  mkdir -p "$E2E_TMP/fail-dumps/e2e"
  echo previous >"$E2E_TMP/fail-dumps/e2e/shop.sql"

  # A user that sees every database, but may read appdb only: the dump of
  # the next one fails.
  my src -e "CREATE USER 'e2e_limited'@'%' IDENTIFIED BY 'limited';
             GRANT SHOW DATABASES, PROCESS ON *.* TO 'e2e_limited'@'%';
             GRANT SELECT, SHOW VIEW, TRIGGER, EVENT ON appdb.* TO 'e2e_limited'@'%';"
  write_conf "$E2E_TMP/limited/e2e.conf" src e2e_limited limited
  run --separate-stderr env DB_BACKUP_LOCATION="$E2E_TMP/fail-dumps" backup-mysql "$E2E_TMP/limited/e2e.conf"
  [ "$status" -ge 2 ] || fail "rc=$status: $stderr"
  [ "$(cat "$E2E_TMP/fail-dumps/e2e/shop.sql")" = previous ]

  # A wrong password (reported once, also from inside a $(…)), a server that
  # is not there.
  write_conf "$E2E_TMP/badpw/e2e.conf" src root wrong
  run --separate-stderr env DB_BACKUP_LOCATION="$E2E_TMP/fail-dumps" backup-mysql "$E2E_TMP/badpw/e2e.conf"
  [ "$status" -ge 2 ] || fail "rc=$status"
  [ "$(grep -c 'backup failed' <<<"$stderr")" = 1 ] || fail "$stderr"
  write_conf "$E2E_TMP/nohost/e2e.conf" no-such-host
  run env DB_BACKUP_LOCATION="$E2E_TMP/fail-dumps" backup-mysql "$E2E_TMP/nohost/e2e.conf"
  [ "$status" -ge 2 ] || fail "rc=$status"

  # backup-cluster-mysql stops at the failing instance with its rc.
  cp "$E2E_TMP/limited/e2e.conf" /root/.mysql/a-limited.conf
  run env DB_BACKUP_LOCATION="$E2E_TMP/fail-dumps" backup-cluster-mysql
  rm -f /root/.mysql/a-limited.conf
  [ "$status" -ge 2 ] || fail "rc=$status"
  my src -e "DROP USER 'e2e_limited'@'%'"
}

@test "Borg deduplicates the dumps: an unchanged and a slightly changed instance add little" {
  local first unchanged changed
  # A repository of its own: the tests before changed src since the first
  # archive.
  DB_BACKUP_LOCATION=$DUMPS backup-cluster-mysql >/dev/null
  first=$(borg_create "$E2E_TMP/dedup-repo" first "$DUMPS")

  DB_BACKUP_LOCATION=$DUMPS backup-cluster-mysql >/dev/null
  unchanged=$(borg_create "$E2E_TMP/dedup-repo" unchanged "$DUMPS")

  # 100 rows updated in one place, 100 added.
  my src appdb -e "UPDATE bulk SET filler = UPPER(filler) WHERE id BETWEEN 100001 AND 100100;
                   INSERT INTO bulk WITH RECURSIVE seq (n) AS (SELECT 200001 UNION ALL SELECT n + 1 FROM seq WHERE n < 200100)
                     SELECT n, MD5(n) FROM seq;"
  DB_BACKUP_LOCATION=$DUMPS backup-cluster-mysql >/dev/null
  changed=$(borg_create "$E2E_TMP/dedup-repo" changed "$DUMPS")

  echo "# dumps $(cat "$DUMPS"/*/* | wc -c) bytes; added to the repository: first archive $first, unchanged $unchanged, changed $changed" >&3
  [ "$unchanged" -lt $((first / 2)) ] || fail "unchanged: $unchanged bytes new, the first archive added $first"
  [ "$changed" -lt $((first / 2)) ] || fail "changed: $changed bytes new, the first archive added $first"
}
