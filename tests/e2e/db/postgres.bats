#!/usr/bin/env bats
#
# backup-postgres, backup-cluster-postgres and restore-postgres against real
# PostgreSQL servers (run by run.sh, one server version per run): the seeded
# instance on `src` is dumped with the chart's credentials file, archived and
# extracted with Borg, and restored into the empty servers `dst` and `dst2`
# and into `src` itself; every restore is compared with a fingerprint of the
# source taken at dump time.

bats_require_minimum_version 1.5.0

load helpers/common
load helpers/postgres

setup_file() {
  export E2E_TMP
  E2E_TMP=$(mktemp -d)
  pg_setup_admin
  for host in src dst dst2; do
    wait_for 90 pg_ready "$host"
  done

  pg_seed src
  pg_fingerprint src >"$E2E_TMP/src.fingerprint"
  pg_db_fingerprint src appdb >"$E2E_TMP/appdb.fingerprint"

  # The chart mounts one credentials file per instance at /root/.postgres. The
  # restore of the whole instance into `dst` connects with a file named after
  # that server and reads the instance's dumps with --from; the other
  # restores use files of the instance's name for the other servers.
  write_conf /root/.postgres/e2e.conf src
  write_conf "$E2E_TMP/conf/dst.conf" dst
  write_conf "$E2E_TMP/dst2/e2e.conf" dst2

  export DUMPS="$E2E_TMP/dumps"
  DB_BACKUP_LOCATION=$DUMPS backup-cluster-postgres >"$E2E_TMP/backup.log" 2>&1 \
    || { cat "$E2E_TMP/backup.log" >&2; return 1; }

  export REPO="$E2E_TMP/repo"
  borg_create "$REPO" first "$DUMPS" >/dev/null
  borg_extract "$REPO" first "$E2E_TMP/extracted"
  export RESTORED="$E2E_TMP/extracted$DUMPS"
}

teardown_file() {
  rm -rf "$E2E_TMP" /root/.postgres
}

@test "backup-postgres writes globals.sql and one uncompressed dump per database, mode 600, template0 aside" {
  assert_dump_dir "$DUMPS/e2e" globals.sql appdb.dump postgres.dump straße.dump template1.dump
  for dump in "$DUMPS"/e2e/*.dump; do
    pg_restore -l "$dump" | grep -Eq '^; +Compression: (none|0)$' || fail "$dump is compressed"
  done
  grep -q '^CREATE ROLE app_owner;' "$DUMPS/e2e/globals.sql"
  # PostgreSQL 13 hashes passwords with md5 by default.
  grep -Eq "^ALTER ROLE app_owner WITH .* PASSWORD '(SCRAM-SHA-256|md5)" "$DUMPS/e2e/globals.sql"
}

@test "the dumps come out of the Borg archive unchanged, still mode 600" {
  for file in "$DUMPS"/e2e/*; do
    cmp "$file" "$RESTORED/e2e/${file##*/}"
  done
  assert_dump_dir "$RESTORED/e2e" globals.sql appdb.dump postgres.dump straße.dump template1.dump
}

@test "restore-postgres --all --from restores the instance into an empty server" {
  run --separate-stderr env DB_BACKUP_LOCATION="$RESTORED" restore-postgres "$E2E_TMP/conf/dst.conf" --all --from e2e
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  pg_fingerprint dst >"$E2E_TMP/dst.fingerprint"
  assert_same "$E2E_TMP/src.fingerprint" "$E2E_TMP/dst.fingerprint"
}

@test "after --all, template1 hands its content to a new database again" {
  pg dst postgres -c 'CREATE DATABASE from_template'
  [ "$(pg dst from_template -c 'SELECT note FROM public.template_marker')" = "inherited by every new database" ]
  [ "$(pg dst from_template -c "SELECT extname FROM pg_extension WHERE extname = 'hstore'")" = hstore ]
  pg dst postgres -c 'DROP DATABASE from_template'
}

@test "restore-postgres DATABASE -j 2 replaces the database with its dump, sessions ended" {
  pg src appdb -c "INSERT INTO app.items (name) VALUES ('after the dump'); DROP VIEW app.item_names;"
  # An open session must not stop the restore.
  PGPASSFILE="$E2E_TMP/admin.pgpass" psql -h src -U postgres -d appdb -c 'SELECT pg_sleep(60)' >/dev/null 2>&1 3>&- &
  sleep 1
  run --separate-stderr env DB_BACKUP_LOCATION="$RESTORED" restore-postgres /root/.postgres/e2e.conf appdb -j 2
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  pg_db_fingerprint src appdb >"$E2E_TMP/appdb.restored"
  assert_same "$E2E_TMP/appdb.fingerprint" "$E2E_TMP/appdb.restored"
  pg_fingerprint src >"$E2E_TMP/src.restored"
  assert_same "$E2E_TMP/src.fingerprint" "$E2E_TMP/src.restored"
}

@test "restore-postgres DATABASE --as NAME restores into NAME and leaves DATABASE alone, also over an existing NAME" {
  # A change only the original has, outside what the fingerprint compares.
  pg src appdb -c "COMMENT ON TABLE app.items IS 'only in the original'"
  for _ in 1 2; do
    run --separate-stderr env DB_BACKUP_LOCATION="$RESTORED" restore-postgres /root/.postgres/e2e.conf appdb --as appdb_copy
    [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
    pg_db_fingerprint src appdb_copy >"$E2E_TMP/copy.fingerprint"
    assert_same "$E2E_TMP/appdb.fingerprint" "$E2E_TMP/copy.fingerprint"
  done
  [ "$(pg src appdb -c "SELECT obj_description('app.items'::regclass, 'pg_class')")" = "only in the original" ]
  [ -z "$(pg src appdb_copy -c "SELECT obj_description('app.items'::regclass, 'pg_class')")" ]
  pg src appdb -c "COMMENT ON TABLE app.items IS NULL"
  pg src postgres -c 'DROP DATABASE appdb_copy'
}

@test "restore-postgres DATABASE restores postgres and template1 as well" {
  for db in postgres template1; do
    run --separate-stderr env DB_BACKUP_LOCATION="$RESTORED" restore-postgres /root/.postgres/e2e.conf "$db"
    [ "$status" -eq 0 ] || fail "$db: rc=$status: $stderr"
  done
  pg_fingerprint src >"$E2E_TMP/src.restored"
  assert_same "$E2E_TMP/src.fingerprint" "$E2E_TMP/src.restored"
}

@test "restore-postgres DATABASE --use-list restores the entries of the list, the database created again" {
  # The list pg_restore -C -l writes, without the content of app.bulk.
  pg_restore -C -l "$RESTORED/e2e/appdb.dump" | grep -v ' TABLE DATA app bulk ' >"$E2E_TMP/appdb.list"
  pg src appdb -c "CREATE TABLE app.only_before_the_restore (id int)"
  run --separate-stderr env DB_BACKUP_LOCATION="$RESTORED" restore-postgres /root/.postgres/e2e.conf appdb --use-list "$E2E_TMP/appdb.list"
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  [ "$(pg src appdb -c 'SELECT count(*) FROM app.bulk')" = 0 ]
  [ "$(pg src appdb -c 'SELECT count(*) FROM app.items')" = 2003 ]
  [ -z "$(pg src appdb -c "SELECT to_regclass('app.only_before_the_restore')")" ]
  # The database's own entries come with a list of pg_restore -C -l.
  [ "$(pg src postgres -c "SELECT shobj_description(oid, 'pg_database') FROM pg_database WHERE datname = 'appdb'")" = "e2e: Grüße" ]
  [ "$(pg src postgres -c "SELECT datacl IS NOT NULL FROM pg_database WHERE datname = 'appdb'")" = t ]

  # --as ignores them.
  run --separate-stderr env DB_BACKUP_LOCATION="$RESTORED" restore-postgres /root/.postgres/e2e.conf appdb --as appdb_list --use-list "$E2E_TMP/appdb.list"
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  [ "$(pg src appdb_list -c 'SELECT count(*) FROM app.items')" = 2003 ]
  [ "$(pg src appdb_list -c 'SELECT count(*) FROM app.bulk')" = 0 ]
  pg src postgres -c 'DROP DATABASE appdb_list'

  run --separate-stderr env DB_BACKUP_LOCATION="$RESTORED" restore-postgres /root/.postgres/e2e.conf appdb
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  pg_db_fingerprint src appdb >"$E2E_TMP/appdb.restored"
  assert_same "$E2E_TMP/appdb.fingerprint" "$E2E_TMP/appdb.restored"
}

@test "restore-postgres --globals restores the roles alone" {
  run --separate-stderr env DB_BACKUP_LOCATION="$RESTORED" restore-postgres "$E2E_TMP/dst2/e2e.conf" --globals
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  pg_fingerprint src | grep -E '^(role|member)\|' >"$E2E_TMP/a"
  pg_fingerprint dst2 | grep -E '^(role|member)\|' >"$E2E_TMP/b"
  assert_same "$E2E_TMP/a" "$E2E_TMP/b"
  [ "$(pg dst2 postgres -c "SELECT count(*) FROM pg_database WHERE datname IN ('appdb', 'straße')")" = 0 ]
}

@test "a failing restore ends with rc >= 2" {
  # A database dump whose roles the server does not have: pg_restore reports
  # the errors and goes on, the script fails.
  pg dst2 postgres -c 'DROP ROLE app_owner' 2>/dev/null || true
  run --separate-stderr env DB_BACKUP_LOCATION="$RESTORED" restore-postgres "$E2E_TMP/dst2/e2e.conf" appdb
  [ "$status" -ge 2 ] || fail "rc=$status"
  [[ "$stderr" == *'role "app_owner" does not exist'* ]] || fail "$stderr"

  # Not a dump at all.
  mkdir -p "$E2E_TMP/broken/e2e"
  echo "not a dump" >"$E2E_TMP/broken/e2e/appdb.dump"
  run --separate-stderr env DB_BACKUP_LOCATION="$E2E_TMP/broken" restore-postgres "$E2E_TMP/dst2/e2e.conf" appdb
  [ "$status" -ge 2 ] || fail "rc=$status"
}

@test "restore-postgres refuses what it cannot do with rc 2" {
  export DB_BACKUP_LOCATION="$RESTORED"
  run restore-postgres
  [ "$status" -eq 2 ]
  run restore-postgres /root/.postgres/e2e.conf
  [ "$status" -eq 2 ]
  run restore-postgres /root/.postgres/e2e.conf --all --globals
  [ "$status" -eq 2 ]
  run restore-postgres /root/.postgres/e2e.conf --all --as other
  [ "$status" -eq 2 ]
  run restore-postgres /root/.postgres/e2e.conf appdb --as
  [ "$status" -eq 2 ]
  run restore-postgres /root/.postgres/e2e.conf appdb -j x
  [ "$status" -eq 2 ]
  run --separate-stderr restore-postgres /root/.postgres/e2e.conf nosuchdb
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"nosuchdb.dump not found"* ]] || fail "$stderr"

  # A compressed dump of a release before: named, with what to do.
  mkdir -p "$E2E_TMP/old/e2e"
  : >"$E2E_TMP/old/e2e/appdb.dump.gz"
  run --separate-stderr env DB_BACKUP_LOCATION="$E2E_TMP/old" restore-postgres /root/.postgres/e2e.conf appdb
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"appdb.dump.gz"*"gunzip -k"* ]] || fail "$stderr"
}

@test "a backup user without superuser rights: globals without passwords, rc 1, every database dumped" {
  [ "$(pg_major src)" -ge 14 ] || skip "pg_read_all_data needs PostgreSQL 14"
  # pg_read_all_data reads every table, but neither CONNECT, a database's
  # own privilege (appdb grants it to app_reader alone), nor large objects.
  pg src postgres -c "CREATE ROLE e2e_backup LOGIN PASSWORD 'backup:pw' IN ROLE pg_read_all_data, app_reader"
  pg src appdb >/dev/null <<'SQL'
SELECT format('GRANT SELECT ON LARGE OBJECT %s TO e2e_backup', oid) FROM pg_largeobject_metadata
\gexec
SQL
  write_conf "$E2E_TMP/nosu/e2e.conf" src e2e_backup 'backup:pw'

  run --separate-stderr env DB_BACKUP_LOCATION="$E2E_TMP/nosu-dumps" backup-postgres "$E2E_TMP/nosu/e2e.conf"
  [ "$status" -eq 1 ] || fail "rc=$status: $stderr"
  [[ "$stderr" == *"Warning: e2e_backup is no superuser"* ]] || fail "$stderr"
  assert_dump_dir "$E2E_TMP/nosu-dumps/e2e" globals.sql appdb.dump postgres.dump straße.dump template1.dump
  grep -q '^CREATE ROLE app_owner;' "$E2E_TMP/nosu-dumps/e2e/globals.sql"
  ! grep -q 'PASSWORD' "$E2E_TMP/nosu-dumps/e2e/globals.sql"

  # backup-cluster-postgres passes the warning on and dumps the other
  # instances all the same.
  cp "$E2E_TMP/nosu/e2e.conf" /root/.postgres/a-nosu.conf
  run --separate-stderr env DB_BACKUP_LOCATION="$E2E_TMP/cluster-dumps" backup-cluster-postgres
  rm -f /root/.postgres/a-nosu.conf
  [ "$status" -eq 1 ] || fail "rc=$status: $stderr"
  [ -f "$E2E_TMP/cluster-dumps/a-nosu/appdb.dump" ]
  [ -f "$E2E_TMP/cluster-dumps/e2e/appdb.dump" ]
}

@test "backup-cluster-databases dumps only the engines in BORG_DB_ENGINES" {
  run env DB_BACKUP_LOCATION="$E2E_TMP/engines-none" BORG_DB_ENGINES="" backup-cluster-databases
  [ "$status" -eq 0 ] || fail "rc=$status: $output"
  [ ! -e "$E2E_TMP/engines-none" ] || fail "dumped: $(ls -R "$E2E_TMP/engines-none")"

  run env DB_BACKUP_LOCATION="$E2E_TMP/engines-postgres" BORG_DB_ENGINES="postgres" backup-cluster-databases
  [ "$status" -eq 0 ] || fail "rc=$status: $output"
  assert_dump_dir "$E2E_TMP/engines-postgres/e2e" globals.sql appdb.dump postgres.dump straße.dump template1.dump
}

@test "a failing dump fails with rc >= 2 and leaves the previous dumps alone" {
  mkdir -p "$E2E_TMP/fail-dumps/e2e"
  echo previous >"$E2E_TMP/fail-dumps/e2e/appdb.dump"
  echo previous >"$E2E_TMP/fail-dumps/e2e/appdb.dump.gz"

  # A user that may connect, but not read appdb's tables: pg_dump fails on
  # the first database.
  pg src postgres -c "CREATE ROLE e2e_nobody LOGIN PASSWORD 'nobody'" 2>/dev/null || true
  write_conf "$E2E_TMP/nobody/e2e.conf" src e2e_nobody nobody
  run --separate-stderr env DB_BACKUP_LOCATION="$E2E_TMP/fail-dumps" backup-postgres "$E2E_TMP/nobody/e2e.conf"
  [ "$status" -ge 2 ] || fail "rc=$status: $stderr"
  [ "$(cat "$E2E_TMP/fail-dumps/e2e/appdb.dump")" = previous ]
  [ "$(cat "$E2E_TMP/fail-dumps/e2e/appdb.dump.gz")" = previous ]

  # A wrong password, a server that is not there.
  write_conf "$E2E_TMP/badpw/e2e.conf" src postgres wrong
  run env DB_BACKUP_LOCATION="$E2E_TMP/fail-dumps" backup-postgres "$E2E_TMP/badpw/e2e.conf"
  [ "$status" -ge 2 ] || fail "rc=$status"
  write_conf "$E2E_TMP/nohost/e2e.conf" no-such-host
  run env DB_BACKUP_LOCATION="$E2E_TMP/fail-dumps" backup-postgres "$E2E_TMP/nohost/e2e.conf"
  [ "$status" -ge 2 ] || fail "rc=$status"

  # backup-cluster-postgres stops at the failing instance with its rc.
  cp "$E2E_TMP/nobody/e2e.conf" /root/.postgres/a-nobody.conf
  run env DB_BACKUP_LOCATION="$E2E_TMP/fail-dumps" backup-cluster-postgres
  rm -f /root/.postgres/a-nobody.conf
  [ "$status" -ge 2 ] || fail "rc=$status"
}

@test "a successful dump removes the compressed dumps of earlier releases and nothing else" {
  mkdir -p "$E2E_TMP/old-dumps/e2e"
  for file in appdb.sql.gz appdb.dump.gz gone.dump.gz appdb.dump.tmp notes.txt; do
    echo old >"$E2E_TMP/old-dumps/e2e/$file"
  done
  chmod 600 "$E2E_TMP/old-dumps/e2e/notes.txt"
  run env DB_BACKUP_LOCATION="$E2E_TMP/old-dumps" backup-postgres /root/.postgres/e2e.conf
  [ "$status" -eq 0 ] || fail "rc=$status: $output"
  assert_dump_dir "$E2E_TMP/old-dumps/e2e" globals.sql appdb.dump postgres.dump straße.dump template1.dump notes.txt
}

@test "Borg deduplicates the dumps: an unchanged and a slightly changed instance add little" {
  local first unchanged changed
  # A repository of its own: the tests before changed src since the first
  # archive.
  DB_BACKUP_LOCATION=$DUMPS backup-cluster-postgres >/dev/null
  first=$(borg_create "$E2E_TMP/dedup-repo" first "$DUMPS")

  DB_BACKUP_LOCATION=$DUMPS backup-cluster-postgres >/dev/null
  unchanged=$(borg_create "$E2E_TMP/dedup-repo" unchanged "$DUMPS")

  # 100 rows updated in one place, 100 added.
  pg src appdb -c "UPDATE app.bulk SET filler = upper(filler) WHERE id BETWEEN 100001 AND 100100;
                   INSERT INTO app.bulk SELECT g, md5(g::text) FROM generate_series(200001, 200100) g;"
  DB_BACKUP_LOCATION=$DUMPS backup-cluster-postgres >/dev/null
  changed=$(borg_create "$E2E_TMP/dedup-repo" changed "$DUMPS")

  # Measured: unchanged 0–2 %, changed 20–40 % of the first archive (Borg's
  # chunks are about 2 MiB). The gzipped dumps before added 100 % (PostgreSQL)
  # and 74 % (MariaDB, changed) — compressed, a dump is new from its first
  # changed byte on.
  echo "# dumps $(cat "$DUMPS"/*/* | wc -c) bytes; added to the repository: first archive $first, unchanged $unchanged, changed $changed" >&3
  [ "$unchanged" -lt $((first / 2)) ] || fail "unchanged: $unchanged bytes new, the first archive added $first"
  [ "$changed" -lt $((first / 2)) ] || fail "changed: $changed bytes new, the first archive added $first"
}

@test "a database that does not allow connections is skipped and named in the log" {
  pg src postgres -c "CREATE DATABASE closed" -c "ALTER DATABASE closed ALLOW_CONNECTIONS false"
  run env DB_BACKUP_LOCATION="$E2E_TMP/closed-dumps" backup-postgres /root/.postgres/e2e.conf
  pg src postgres -c "DROP DATABASE closed"
  [ "$status" -eq 0 ] || fail "rc=$status: $output"
  [[ "$output" == *"Skipping databases that do not allow connections: closed"* ]] || fail "$output"
  assert_dump_dir "$E2E_TMP/closed-dumps/e2e" globals.sql appdb.dump postgres.dump straße.dump template1.dump
}
