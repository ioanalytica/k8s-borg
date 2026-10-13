#!/usr/bin/env bats
#
# backup-mongodb and restore-mongodb: what they hand mongodump and
# mongorestore for each topology and restore mode, and how they fail.
# mongodump, mongorestore and mongodb-admin are stubs that record their
# arguments, --config as the content they read (what mongodb-admin config
# printed); the real tools were run against MongoDB 7.0 and 8.3.

bats_require_minimum_version 1.5.0

setup() {
  load helpers/common
  common_setup
  mkdir -p "$TMP/stubs" "$TMP/dumps"
  PATH="$TMP/stubs:$BIN:$PATH"
  export DB_BACKUP_LOCATION="$TMP/dumps" STUB="$TMP"
  CONF="$TMP/inst.conf"
  printf 'uri: mongodb://backup@mongo:27017/?authSource=admin\npassword: pw\n' >"$CONF"
  echo replset >"$TMP/topology"
  echo yes >"$TMP/oplog"
  printf '%s\n' appdb shop >"$TMP/databases"
  : >"$TMP/calls"
  # mongodb-admin: the topology and the archive's oplog and databases come
  # from files; $TMP/admin-fails makes every call fail, $TMP/fail-COMMAND
  # that command.
  cat >"$TMP/stubs/mongodb-admin" <<'STUB'
#!/usr/bin/env bash
echo "mongodb-admin $*" >>"$STUB/calls"
[ ! -e "$STUB/admin-fails" ] && [ ! -e "$STUB/fail-$1" ] || { echo "Error: mongodb-admin: no server" >&2; exit 2; }
case "$1" in
  config) echo "uri: from $2" ;;
  topology) cat "$STUB/topology" ;;
  archive-oplog) cat "$STUB/oplog" ;;
  archive-databases) cat "$STUB/databases" ;;
esac
STUB
  # mongodump writes "dump" to its --archive, or fails half-way with the rc
  # in $TMP/dump-rc.
  cat >"$TMP/stubs/mongodump" <<'STUB'
#!/usr/bin/env bash
args=()
for a; do
  case "$a" in
    --archive=*) archive=${a#--archive=} ;;
    --config=*) a="--config=[$(cat "${a#--config=}")]" ;;
  esac
  args+=("$a")
done
echo "mongodump ${args[*]}" >>"$STUB/calls"
if [ -e "$STUB/dump-rc" ]; then echo partial >"$archive"; exit "$(cat "$STUB/dump-rc")"; fi
echo dump >"$archive"
STUB
  cat >"$TMP/stubs/mongorestore" <<'STUB'
#!/usr/bin/env bash
args=()
for a; do
  case "$a" in --config=*) a="--config=[$(cat "${a#--config=}")]" ;; esac
  args+=("$a")
done
echo "mongorestore ${args[*]}" >>"$STUB/calls"
# $TMP/replay-rc: the rc of a run that replays an oplog.
[[ " $* " != *" --oplogReplay "* ]] || [ ! -e "$STUB/replay-rc" ] || exit "$(cat "$STUB/replay-rc")"
exit "$(cat "$STUB/restore-rc" 2>/dev/null || echo 0)"
STUB
  chmod +x "$TMP/stubs/"*
}

teardown() { common_teardown; }

calls() { cat "$TMP/calls"; }
archive="inst/inst.archive"
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# ---- backup-mongodb ---------------------------------------------------------

@test "a replica set is dumped with its oplog, uncompressed, one collection at a time" {
  run backup-mongodb "$CONF"
  [ "$status" -eq 0 ] || fail "rc=$status: $output"
  grep -qxF "mongodump --config=[uri: from $CONF] --oplog --numParallelCollections=1 --archive=$TMP/dumps/$archive.tmp" "$TMP/calls" \
    || fail "$(calls)"
  ! grep -q -- --gzip "$TMP/calls" || fail "$(calls)"
  [ "$(cat "$TMP/dumps/$archive")" = dump ]
  [ "$(mode_of "$TMP/dumps/$archive")" = 600 ]
  [ ! -e "$TMP/dumps/$archive.tmp" ]
}

@test "a standalone server is dumped without an oplog" {
  echo standalone >"$TMP/topology"
  run backup-mongodb "$CONF"
  [ "$status" -eq 0 ] || fail "rc=$status: $output"
  grep -qxF "mongodump --config=[uri: from $CONF] --numParallelCollections=1 --archive=$TMP/dumps/$archive.tmp" "$TMP/calls" \
    || fail "$(calls)"
}

@test "a sharded cluster is refused with rc 2, nothing dumped" {
  echo sharded >"$TMP/topology"
  run backup-mongodb "$CONF"
  [ "$status" -eq 2 ] || fail "rc=$status: $output"
  [[ "$output" == *"sharded cluster"* ]] || fail "$output"
  ! grep -q mongodump "$TMP/calls" || fail "$(calls)"
}

@test "an unreachable server fails with rc 2" {
  touch "$TMP/admin-fails"
  run backup-mongodb "$CONF"
  [ "$status" -eq 2 ] || fail "rc=$status: $output"
  ! grep -q mongodump "$TMP/calls" || fail "$(calls)"
}

@test "a failing dump fails with rc >= 2 and keeps the previous archive" {
  mkdir -p "$TMP/dumps/inst"
  echo previous >"$TMP/dumps/$archive"
  echo 1 >"$TMP/dump-rc"
  run backup-mongodb "$CONF"
  [ "$status" -eq 2 ] || fail "rc 1 of mongodump must become 2, got $status: $output"
  [ "$(cat "$TMP/dumps/$archive")" = previous ]
  [ ! -e "$TMP/dumps/$archive.tmp" ] || fail "the half-written dump is left"
}

@test "a config mongodb-admin cannot generate stops the backup before mongodump" {
  touch "$TMP/fail-config"
  run backup-mongodb "$CONF"
  [ "$status" -eq 2 ] || fail "rc=$status: $output"
  ! grep -q mongodump "$TMP/calls" || fail "$(calls)"
}

@test "backup-mongodb without a config file or DB_BACKUP_LOCATION fails with rc 2" {
  run backup-mongodb
  [ "$status" -eq 2 ]
  DB_BACKUP_LOCATION="" run backup-mongodb "$CONF"
  [ "$status" -eq 2 ]
}

# ---- restore-mongodb --------------------------------------------------------

dumped() {
  mkdir -p "$TMP/dumps/inst"
  echo dump >"$TMP/dumps/$archive"
}

@test "--all restores the users and roles, then every collection with --drop, replaying the dump's oplog" {
  dumped
  run restore-mongodb "$CONF" --all
  [ "$status" -eq 0 ] || fail "rc=$status: $output"
  [ "$(grep '^mongorestore' "$TMP/calls")" = "mongorestore --config=[uri: from $CONF] --archive=$TMP/dumps/$archive --drop --nsInclude=admin.system.users --nsInclude=admin.system.roles --nsInclude=admin.system.version
mongorestore --config=[uri: from $CONF] --archive=$TMP/dumps/$archive --drop --oplogReplay" ] || fail "$(calls)"
}

@test "--all without an oplog in the dump replays none, in one pass" {
  dumped
  echo no >"$TMP/oplog"
  run restore-mongodb "$CONF" --all
  [ "$status" -eq 0 ] || fail "rc=$status: $output"
  [ "$(grep '^mongorestore' "$TMP/calls")" = "mongorestore --config=[uri: from $CONF] --archive=$TMP/dumps/$archive --drop" ] \
    || fail "$(calls)"
}

@test "--all --no-oplog leaves the oplog out" {
  dumped
  run restore-mongodb "$CONF" --all --no-oplog
  [ "$status" -eq 0 ] || fail "rc=$status: $output"
  [ "$(grep '^mongorestore' "$TMP/calls")" = "mongorestore --config=[uri: from $CONF] --archive=$TMP/dumps/$archive --drop" ] \
    || fail "$(calls)"
  ! grep -q archive-oplog "$TMP/calls" || fail "$(calls)"
}

@test "one database is dropped, then restored from the archive" {
  dumped
  run restore-mongodb "$CONF" appdb
  [ "$status" -eq 0 ] || fail "rc=$status: $output"
  [ "$(calls)" = "mongodb-admin config $CONF
mongodb-admin archive-databases $TMP/dumps/$archive
mongodb-admin drop-database $CONF appdb
mongorestore --config=[uri: from $CONF] --archive=$TMP/dumps/$archive --nsInclude=appdb.*" ] || fail "$(calls)"
}

@test "--as restores the database under another name and leaves the original alone" {
  dumped
  run restore-mongodb "$CONF" appdb --as appcopy
  [ "$status" -eq 0 ] || fail "rc=$status: $output"
  [ "$(calls)" = "mongodb-admin config $CONF
mongodb-admin archive-databases $TMP/dumps/$archive
mongodb-admin drop-database $CONF appcopy
mongorestore --config=[uri: from $CONF] --archive=$TMP/dumps/$archive --nsInclude=appdb.* --nsFrom=appdb.* --nsTo=appcopy.*" ] \
    || fail "$(calls)"
}

@test "admin, local and config are not restored, nor restored into, as a single database" {
  dumped
  for db in admin local config; do
    run restore-mongodb "$CONF" "$db"
    [ "$status" -eq 2 ] || fail "$db: rc=$status"
    run restore-mongodb "$CONF" appdb --as "$db"
    [ "$status" -eq 2 ] || fail "--as $db: rc=$status"
  done
  ! grep -qE 'drop-database|mongorestore' "$TMP/calls" || fail "$(calls)"
}

@test "a name that is no database name is refused before anything is dropped" {
  dumped
  for name in 'a.b' 'a*' 'a b' 'a/b' 'a\b' 'a"b' 'a$b'; do
    run restore-mongodb "$CONF" appdb --as "$name"
    [ "$status" -eq 2 ] || fail "'$name': rc=$status"
  done
  ! grep -qE 'drop-database|mongorestore' "$TMP/calls" || fail "$(calls)"
}

@test "restore-mongodb usage errors fail with rc 2" {
  dumped
  run restore-mongodb
  [ "$status" -eq 2 ]
  run restore-mongodb "$CONF"
  [ "$status" -eq 2 ]
  run restore-mongodb "$CONF" --all appdb
  [ "$status" -eq 2 ]
  run restore-mongodb "$CONF" --all --as x
  [ "$status" -eq 2 ]
  run restore-mongodb "$CONF" appdb --no-oplog
  [ "$status" -eq 2 ]
  run restore-mongodb "$CONF" appdb --as
  [ "$status" -eq 2 ]
  run restore-mongodb "$TMP/missing.conf" --all
  [ "$status" -eq 2 ]
  [ -z "$(calls)" ] || fail "$(calls)"
}

@test "a missing archive fails with rc 2" {
  run restore-mongodb "$CONF" --all
  [ "$status" -eq 2 ] || fail "rc=$status: $output"
  [[ "$output" == *"not found"* ]] || fail "$output"
}

@test "a failing mongorestore fails with rc >= 2, with a hint when it replayed an oplog" {
  dumped
  echo 1 >"$TMP/replay-rc"
  run restore-mongodb "$CONF" --all
  [ "$status" -eq 2 ] || fail "rc=$status: $output"
  [[ "$output" == *"Hint:"*"--no-oplog"* ]] || fail "$output"
  rm "$TMP/replay-rc"
  echo 1 >"$TMP/restore-rc"
  run restore-mongodb "$CONF" --all
  [ "$status" -eq 2 ] || fail "the users pass failing: rc=$status: $output"
  run restore-mongodb "$CONF" --all --no-oplog
  [ "$status" -eq 2 ] || fail "rc=$status: $output"
  [[ "$output" != *"Hint:"* ]] || fail "$output"
  run restore-mongodb "$CONF" appdb
  [ "$status" -eq 2 ] || fail "rc=$status: $output"
}

@test "a database the archive does not hold is refused before anything is dropped" {
  dumped
  for args in "appdb2" "appdb2 --as appcopy"; do
    : >"$TMP/calls"
    # shellcheck disable=SC2086
    run restore-mongodb "$CONF" $args
    [ "$status" -eq 2 ] || fail "$args: rc=$status: $output"
    [[ "$output" == *"holds no database appdb2 (it holds: appdb shop)"* ]] || fail "$output"
    ! grep -qE 'drop-database|mongorestore' "$TMP/calls" || fail "$(calls)"
  done
}

@test "a config mongodb-admin cannot generate stops the restore before anything is dropped" {
  dumped
  touch "$TMP/fail-config"
  run restore-mongodb "$CONF" appdb
  [ "$status" -eq 2 ] || fail "rc=$status: $output"
  ! grep -qE 'drop-database|mongorestore' "$TMP/calls" || fail "$(calls)"
}

@test "a failing drop stops the restore of a database" {
  dumped
  touch "$TMP/fail-drop-database"
  run restore-mongodb "$CONF" appdb
  [ "$status" -eq 2 ] || fail "rc=$status: $output"
  ! grep -q mongorestore "$TMP/calls" || fail "$(calls)"
}
