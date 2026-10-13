#!/usr/bin/env bats
#
# `redis-rdb-sync` against tests/helpers/fake-redis.py, a real socket server
# that speaks the replication handshake: both framings of the SYNC answer
# (a sized bulk, and the EOF mark of a diskless sync, also split across
# reads), keepalive newlines, AUTH, the version announced to Valkey only, and
# every way a transfer can go wrong ending in rc 2 without a usable file.

bats_require_minimum_version 1.5.0   # run --separate-stderr

setup() {
  load helpers/common
  common_setup
  unset REDISCLI_AUTH
  # An RDB file as far as the checks go: the magic, a body, the EOF opcode
  # and an 8-byte checksum.
  { printf 'REDIS0011'; head -c 200000 /dev/urandom; printf '\377'; head -c 8 /dev/zero; } >"$TMP/payload"
  export FAKE_DIR="$TMP" FAKE_PAYLOAD="$TMP/payload"
}

teardown() {
  [ -z "${FAKE_PID:-}" ] || kill "$FAKE_PID" 2>/dev/null || true
  common_teardown
}

# start_fake [VAR=VALUE…] — start the fake server with these settings.
start_fake() {
  env "$@" python3 "$BATS_TEST_DIRNAME/helpers/fake-redis.py" 3>&- &
  FAKE_PID=$!
  local i
  for i in $(seq 50); do [ -f "$TMP/port" ] && break; sleep 0.1; done
  [ -f "$TMP/port" ] || fail "the fake server did not start"
  PORT=$(cat "$TMP/port")
}

sync_rdb() { run --separate-stderr "$BIN/redis-rdb-sync" "$@" 127.0.0.1 "$PORT" "$TMP/out.rdb"; }

commands() { cat "$TMP/commands"; }

@test "a sized SYNC answer is written to the file byte for byte" {
  start_fake
  sync_rdb
  [ "$status" -eq 0 ] || fail "status $status: $stderr"
  cmp "$TMP/payload" "$TMP/out.rdb"
  [[ $output == "127.0.0.1:$PORT: 200018 bytes" ]] || fail "$output"
}

@test "a diskless SYNC answer ends at its EOF mark, also split across reads, after keepalives" {
  start_fake FAKE_FRAMING=eof FAKE_CHUNK=7 FAKE_KEEPALIVES=3
  sync_rdb
  [ "$status" -eq 0 ] || fail "status $status: $stderr"
  cmp "$TMP/payload" "$TMP/out.rdb"
}

@test "the handshake: capa eof and rdb-only, then SYNC; a Redis is told no version" {
  start_fake
  sync_rdb
  [ "$status" -eq 0 ] || fail "status $status: $stderr"
  [ "$(commands)" = '["INFO", "server"]
["REPLCONF", "capa", "eof"]
["REPLCONF", "rdb-only", "1"]
["SYNC"]' ] || fail "$(commands)"
}

@test "a Valkey is told its own version, so that Valkey 9 sends its new format" {
  start_fake FAKE_VALKEY_VERSION=9.1.2 FAKE_NEEDS_VERSION=9.0.0
  sync_rdb
  [ "$status" -eq 0 ] || fail "status $status: $stderr"
  grep -qxF '["REPLCONF", "version", "9.1.2"]' "$TMP/commands" || fail "$(commands)"
  [[ $output == *"(Valkey 9.1.2)" ]] || fail "$output"
  cmp "$TMP/payload" "$TMP/out.rdb"
}

@test "the password comes from REDISCLI_AUTH, with the user when one is given" {
  start_fake FAKE_PASSWORD='p:w"d' FAKE_USER=backup
  REDISCLI_AUTH='p:w"d' sync_rdb --user backup
  [ "$status" -eq 0 ] || fail "status $status: $stderr"
  [ "$(head -1 "$TMP/commands")" = '["AUTH", "backup", "***"]' ] || fail "$(commands)"
}

@test "a wrong password fails with rc 2 and the server's reason, before any file" {
  start_fake FAKE_PASSWORD=right
  REDISCLI_AUTH=wrong sync_rdb
  [ "$status" -eq 2 ] || fail "status $status"
  [[ $stderr == *"WRONGPASS"* ]] || fail "$stderr"
  [ ! -e "$TMP/out.rdb" ]
}

@test "no password where one is required: rc 2, NOAUTH" {
  start_fake FAKE_PASSWORD=right
  sync_rdb
  [ "$status" -eq 2 ] || fail "status $status"
  [[ $stderr == *"NOAUTH"* ]] || fail "$stderr"
}

@test "SYNC refused: rc 2 with the server's reason" {
  start_fake "FAKE_SYNC_ERROR=NOPERM User backup has no permissions to run the 'sync' command"
  sync_rdb
  [ "$status" -eq 2 ] || fail "status $status"
  [[ $stderr == *"SYNC failed: NOPERM"* ]] || fail "$stderr"
}

@test "a connection lost in the middle of a sized transfer: rc 2" {
  start_fake FAKE_CUT=1000
  sync_rdb
  [ "$status" -eq 2 ] || fail "status $status"
  [[ $stderr == *"closed the connection"* ]] || fail "$stderr"
}

@test "a connection lost in the middle of a diskless transfer: rc 2" {
  start_fake FAKE_FRAMING=eof FAKE_CUT=1000
  sync_rdb
  [ "$status" -eq 2 ] || fail "status $status"
}

@test "a server that drops the link instead of answering SYNC: rc 2" {
  start_fake FAKE_VALKEY_VERSION=8.1.0 FAKE_NEEDS_VERSION=9.0.0
  sync_rdb
  [ "$status" -eq 2 ] || fail "status $status"
}

@test "a payload that is no RDB file: rc 2" {
  printf 'HELLO world, no RDB here\377........' >"$TMP/payload"
  start_fake
  sync_rdb
  [ "$status" -eq 2 ] || fail "status $status"
  [[ $stderr == *"no RDB file"* ]] || fail "$stderr"
}

@test "an RDB file without its EOF record: rc 2" {
  { printf 'VALKEY080'; head -c 5000 /dev/zero; } >"$TMP/payload"
  start_fake
  sync_rdb
  [ "$status" -eq 2 ] || fail "status $status"
  [[ $stderr == *"truncated"* ]] || fail "$stderr"
}

@test "nobody listening: rc 2" {
  PORT=1
  sync_rdb
  [ "$status" -eq 2 ] || fail "status $status"
}
