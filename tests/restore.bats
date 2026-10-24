#!/usr/bin/env bats
#
# restore-postgres, restore-mariadb and restore-mysql: which dumps they read
# (--from) and what they hand pg_restore (--use-list). psql, pg_restore,
# mariadb and MySQL's mysql are stubs that record their arguments and what
# they read on stdin; the restores themselves run against real servers in
# tests/e2e/db/. restore-mongodb has its own stubs in mongodb.bats.

bats_require_minimum_version 1.5.0

setup() {
  load helpers/common
  common_setup
  mkdir -p "$TMP/stubs" "$TMP/mysql-bin" "$TMP/dumps" "$TMP/conf"
  PATH="$TMP/stubs:$BIN:$PATH"
  export DB_BACKUP_LOCATION="$TMP/dumps" STUB="$TMP" MYSQL_CLIENT_DIR="$TMP/mysql-bin"
  : >"$TMP/calls"
  printf 'pg-new:5432:*:postgres:pw\n' >"$TMP/conf/new.conf"
  printf '[client]\nhost="db-new"\n' >"$TMP/conf/new.cnf"
  # psql answers the server version and reads SQL from stdin unless -f or -c
  # give it.
  cat >"$TMP/stubs/psql" <<'STUB'
#!/usr/bin/env bash
case "$*" in *"SHOW server_version_num"*) echo 180004; exit 0 ;; esac
echo "psql $*" >>"$STUB/calls"
case " $* " in *" -f "*|*" -c "*) ;; *) cat >/dev/null ;; esac
STUB
  # pg_restore -L LIST -l DUMP (the check of a list) prints $TMP/list-warnings
  # to stderr and is not recorded with the restores.
  cat >"$TMP/stubs/pg_restore" <<'STUB'
#!/usr/bin/env bash
if [[ " $* " == *" -l "* ]]; then
  echo "pg_restore $*" >>"$STUB/list-checks"
  [ ! -e "$STUB/list-warnings" ] || cat "$STUB/list-warnings" >&2
  exit 0
fi
echo "pg_restore $*" >>"$STUB/calls"
STUB
  # The MariaDB and MySQL clients answer VERSION() as their engine's server
  # and record the dump they are fed on stdin (without -e).
  for client in "$TMP/stubs/mariadb:11.8.3-MariaDB" "$TMP/mysql-bin/mysql:8.4.11"; do
    cat >"${client%%:*}" <<STUB
#!/usr/bin/env bash
case "\$*" in *"SELECT VERSION()"*) echo "${client#*:}"; exit 0 ;; esac
echo "\${0##*/} \$*" >>"\$STUB/calls"
case " \$* " in *" -e "*) ;; *) sed 's/^/  stdin: /' >>"\$STUB/calls" ;; esac
STUB
  done
  chmod +x "$TMP/stubs/"* "$TMP/mysql-bin/"*
}

teardown() { common_teardown; }

calls() { cat "$TMP/calls"; }

# dumps INSTANCE FILE… — dumps of INSTANCE, each holding its own path.
dumps() {
  local instance=$1 file
  shift
  mkdir -p "$TMP/dumps/$instance"
  for file; do echo "dump $instance/$file" >"$TMP/dumps/$instance/$file"; done
}

# ---- restore-postgres --from ------------------------------------------------

@test "restore-postgres --from reads another instance's dumps and connects with the given file" {
  dumps old globals.sql appdb.dump postgres.dump
  dumps new appdb.dump
  run --separate-stderr restore-postgres "$TMP/conf/new.conf" appdb --from old
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  [ "$(grep '^pg_restore' "$TMP/calls")" = "pg_restore -h pg-new -p 5432 -U postgres -C -j 4 -d postgres $TMP/dumps/old/appdb.dump" ] \
    || fail "$(calls)"

  : >"$TMP/calls"
  run --separate-stderr restore-postgres "$TMP/conf/new.conf" --from old --all
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  grep -qxF "psql -h pg-new -p 5432 -U postgres -X -q -d postgres -f $TMP/dumps/old/globals.sql" "$TMP/calls" || fail "$(calls)"
  [ "$(grep '^pg_restore' "$TMP/calls")" = "pg_restore -h pg-new -p 5432 -U postgres -C -j 4 -d template1 $TMP/dumps/old/postgres.dump
pg_restore -h pg-new -p 5432 -U postgres -C -j 4 -d postgres $TMP/dumps/old/appdb.dump" ] || fail "$(calls)"

  : >"$TMP/calls"
  run --separate-stderr restore-postgres "$TMP/conf/new.conf" appdb --as copy --from old
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  [ "$(grep '^pg_restore' "$TMP/calls")" = "pg_restore -h pg-new -p 5432 -U postgres -j 4 -d copy $TMP/dumps/old/appdb.dump" ] \
    || fail "$(calls)"
}

@test "restore-postgres without --from still reads the dumps named after the credentials file" {
  dumps new appdb.dump
  run --separate-stderr restore-postgres "$TMP/conf/new.conf" appdb
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  grep -qF "$TMP/dumps/new/appdb.dump" "$TMP/calls" || fail "$(calls)"
}

@test "restore-postgres --from without an instance, with a path, or without its dumps fails with rc 2 before anything is dropped" {
  dumps new appdb.dump
  for args in "appdb --from" "appdb --from ../new" "appdb --from a/b" "appdb --from ." "appdb --from .." "appdb --from missing" "--globals --from missing"; do
    : >"$TMP/calls"
    # shellcheck disable=SC2086
    run --separate-stderr restore-postgres "$TMP/conf/new.conf" $args
    [ "$status" -eq 2 ] || fail "$args: rc=$status: $stderr"
    [ -z "$(calls)" ] || fail "$args: $(calls)"
  done
}

# ---- restore-postgres --use-list --------------------------------------------

# toc FILE [ENTRY…] — a list as pg_restore -C -l writes it: the DATABASE
# entry and the ENTRY lines.
toc() {
  local file=$1
  shift
  {
    echo ';'
    echo '; Archive created at 2026-10-14 11:31:02 UTC'
    echo ';'
    echo '4321; 1262 16384 DATABASE - appdb app_owner'
    printf '%s\n' "$@"
  } >"$file"
}

@test "--use-list hands pg_restore the list, with -C for a database restored under its own name" {
  dumps new appdb.dump
  toc "$TMP/appdb.list" '220; 2615 16390 SCHEMA - app app_owner' ';12; 3079 16400 EXTENSION - pg_cron '
  run --separate-stderr restore-postgres "$TMP/conf/new.conf" appdb --use-list "$TMP/appdb.list"
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  [ "$(grep '^pg_restore' "$TMP/calls")" = "pg_restore -h pg-new -p 5432 -U postgres -L $TMP/appdb.list -C -j 4 -d postgres $TMP/dumps/new/appdb.dump" ] \
    || fail "$(calls)"
  grep -qxF "psql -h pg-new -p 5432 -U postgres -X -q -v ON_ERROR_STOP=1 -d postgres -v name=appdb" "$TMP/calls" || fail "$(calls)"
  # The list was checked against the dump first.
  grep -qxF "pg_restore -L $TMP/appdb.list -l $TMP/dumps/new/appdb.dump" "$TMP/list-checks" || fail "$(cat "$TMP/list-checks")"
}

@test "--use-list with --as and --from restores the listed entries into NAME" {
  dumps old appdb.dump
  # A list of pg_restore -l, without the database's own entries.
  printf '220; 2615 16390 SCHEMA - app app_owner\n' >"$TMP/appdb.list"
  run --separate-stderr restore-postgres "$TMP/conf/new.conf" appdb --as copy --from old --use-list "$TMP/appdb.list"
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  [ "$(grep '^pg_restore' "$TMP/calls")" = "pg_restore -h pg-new -p 5432 -U postgres -L $TMP/appdb.list -j 4 -d copy $TMP/dumps/old/appdb.dump" ] \
    || fail "$(calls)"
}

@test "--use-list is refused before anything is dropped: no list, one without entries, --all or --globals" {
  dumps new globals.sql appdb.dump
  toc "$TMP/appdb.list"
  printf '; only comments\n' >"$TMP/empty.list"
  for args in "appdb --use-list" "appdb --use-list $TMP/missing.list" "appdb --use-list $TMP/empty.list" \
              "--all --use-list $TMP/appdb.list" "--globals --use-list $TMP/appdb.list"; do
    : >"$TMP/calls"
    # shellcheck disable=SC2086
    run --separate-stderr restore-postgres "$TMP/conf/new.conf" $args
    [ "$status" -eq 2 ] || fail "$args: rc=$status: $stderr"
    [ -z "$(calls)" ] || fail "$args: $(calls)"
  done
}

@test "--use-list takes a list of bare IDs, also indented" {
  dumps new appdb.dump
  printf '; written by hand\n  220\n' >"$TMP/ids.list"
  run --separate-stderr restore-postgres "$TMP/conf/new.conf" appdb --as copy --use-list "$TMP/ids.list"
  [ "$status" -eq 0 ] || fail "rc=$status: $stderr"
  grep -qF -- "-L $TMP/ids.list" "$TMP/calls" || fail "$(calls)"
}

@test "a list with a line pg_restore cannot match to the dump is refused before anything is dropped" {
  dumps new appdb.dump
  toc "$TMP/appdb.list" '9999; 1259 1 TABLE app nosuch app_owner'
  echo 'pg_restore: warning: line ignored: 9999' >"$TMP/list-warnings"
  run --separate-stderr restore-postgres "$TMP/conf/new.conf" appdb --use-list "$TMP/appdb.list"
  [ "$status" -eq 2 ] || fail "rc=$status: $stderr"
  [[ "$stderr" == *"does not fit"*"line ignored: 9999"* ]] || fail "$stderr"
  [ -z "$(calls)" ] || fail "$(calls)"
}

# ---- restore-mariadb / restore-mysql --from ---------------------------------

@test "restore-mariadb and restore-mysql --from read another instance's dumps and connect with the given file" {
  local engine client
  for engine in mariadb mysql; do
    client=$engine
    dumps old old-full-dump.sql appdb.sql
    : >"$TMP/calls"
    run --separate-stderr "restore-$engine" "$TMP/conf/new.cnf" --all --from old
    [ "$status" -eq 0 ] || fail "$engine: rc=$status: $stderr"
    [ "$(calls)" = "$client --defaults-file=$TMP/conf/new.cnf
  stdin: dump old/old-full-dump.sql
$client --defaults-file=$TMP/conf/new.cnf -e FLUSH PRIVILEGES" ] || fail "$engine: $(calls)"
    [[ "$output" == *"Restoring instance: old from $TMP/dumps/old/old-full-dump.sql"* ]] || fail "$output"

    : >"$TMP/calls"
    run --separate-stderr "restore-$engine" "$TMP/conf/new.cnf" appdb --from old
    [ "$status" -eq 0 ] || fail "$engine: rc=$status: $stderr"
    [ "$(calls)" = "$client --defaults-file=$TMP/conf/new.cnf -e DROP DATABASE IF EXISTS \`appdb\`
$client --defaults-file=$TMP/conf/new.cnf
  stdin: dump old/appdb.sql" ] || fail "$engine: $(calls)"
  done
}

@test "restore-mariadb --from without an instance, with a path, or without its dumps fails with rc 2 before anything is dropped" {
  dumps new new-full-dump.sql appdb.sql
  for args in "--all --from" "--all --from ../new" "appdb --from a/b" "appdb --from ." "appdb --from .." "--all --from missing" "appdb --from missing"; do
    : >"$TMP/calls"
    # shellcheck disable=SC2086
    run --separate-stderr restore-mariadb "$TMP/conf/new.cnf" $args
    [ "$status" -eq 2 ] || fail "$args: rc=$status: $stderr"
    [ -z "$(calls)" ] || fail "$args: $(calls)"
  done
}
