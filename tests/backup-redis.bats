#!/usr/bin/env bats
#
# `backup-redis`: the config file (read, never sourced), the options handed to
# valkey-cli and redis-rdb-sync (the password only through REDISCLI_AUTH), one
# RDB file for a standalone server, one per primary of a cluster named after
# its first slot range, all-or-nothing replacement of the previous dump, and
# rc 2 for every failure. valkey-cli and redis-rdb-sync are stubs; the real
# servers are the database end-to-end tests' job.

bats_require_minimum_version 1.5.0   # run --separate-stderr

setup() {
  load helpers/common
  common_setup
  unset REDISCLI_AUTH
  mkdir -p "$TMP/stubs" "$TMP/dumps"
  PATH="$TMP/stubs:$BIN:$PATH"
  export STUB="$TMP" DB_BACKUP_LOCATION="$TMP/dumps"
  printf 'cluster_enabled:0\r\n' >"$TMP/info"
  : >"$TMP/nodes"; : >"$TMP/broken"; : >"$TMP/calls"
  # valkey-cli answers INFO and CLUSTER NODES from files, as valkey-cli does
  # with rc 0 also for an error reply.
  cat >"$TMP/stubs/valkey-cli" <<'STUB'
#!/usr/bin/env bash
echo "valkey-cli $* auth=${REDISCLI_AUTH-unset}" >>"$STUB/calls"
case "$*" in
  *"INFO cluster") cat "$STUB/info" ;;
  *"CLUSTER NODES") cat "$STUB/nodes" ;;
esac
STUB
  # redis-rdb-sync writes "RDB <host>:<port>"; a host:port listed in
  # $STUB/broken leaves half a file and fails.
  cat >"$TMP/stubs/redis-rdb-sync" <<'STUB'
#!/usr/bin/env bash
echo "redis-rdb-sync $* auth=${REDISCLI_AUTH-unset}" >>"$STUB/calls"
args=("$@"); n=${#args[@]}
host=${args[n-3]} port=${args[n-2]} file=${args[n-1]}
if grep -qxF "$host:$port" "$STUB/broken"; then
  echo half >"$file"; echo "Error: $host:$port: refused" >&2; exit 2
fi
echo "RDB $host:$port" >"$file"
STUB
  chmod +x "$TMP/stubs/"*
}

teardown() { common_teardown; }

# conf LINE… — the config file of the instance "cache".
conf() { printf '%s\n' "$@" >"$TMP/cache.conf"; }

backup() { run --separate-stderr "$BIN/backup-redis" "$TMP/cache.conf"; }

files() { (cd "$TMP/dumps/cache" && stat -c '%n %a' * 2>/dev/null || stat -f '%N %Lp' *) | LC_ALL=C sort; }

CLUSTER_NODES='07c37dfeb235213a872192d90877d0cd55635b91 10.0.0.2:6379@16379,redis-0.redis myself,master - 0 0 1 connected 0-5460
67ed2db8d677e59ec4a4cefb06858cf2a1a89fa1 10.0.0.3:6379@16379 master - 0 1426238316232 2 connected 5461-10921 [10922->-292f8b365bb7edb5e285caf0b7e6ddc7265d2f4f]
292f8b365bb7edb5e285caf0b7e6ddc7265d2f4f 10.0.0.4:6380@16380 master - 0 1426238318243 3 connected [10922-<-67ed2db8d677e59ec4a4cefb06858cf2a1a89fa1] 10923-16383
e7d1eecce10fd6bb5eb35b9f99a514335d9ba9ca 10.0.0.5:6379@16379 slave 07c37dfeb235213a872192d90877d0cd55635b91 0 1426238317239 4 connected
6ec23923021cf3ffec47632106199cb7f496ce01 10.0.0.6:6379@16379 master,fail - 1426238317741 1426238316232 0 disconnected'

@test "a standalone server: <instance>.rdb, mode 600, and nothing else" {
  conf host=redis.cache.svc
  backup
  [ "$status" -eq 0 ] || fail "status $status: $stderr"
  [ "$(files)" = "cache.rdb 600" ] || fail "$(files)"
  [ "$(cat "$TMP/dumps/cache/cache.rdb")" = "RDB redis.cache.svc:6379" ]
}

@test "user, TLS and CA go to both tools; the password only through REDISCLI_AUTH" {
  conf host=r port=6380 user=backup 'password=p=w d#"' tls=true cacert=/ca.crt
  backup
  [ "$status" -eq 0 ] || fail "status $status: $stderr"
  [ "$(cat "$TMP/calls")" = "valkey-cli -h r -p 6380 --user backup --tls --cacert /ca.crt INFO cluster auth=p=w d#\"
redis-rdb-sync --user backup --tls --cacert /ca.crt r 6380 $TMP/dumps/cache/cache.rdb.tmp auth=p=w d#\"" ] \
    || fail "$(cat "$TMP/calls")"
}

@test "insecure=true turns TLS on" {
  conf host=r insecure=TRUE
  backup
  [ "$status" -eq 0 ] || fail "status $status: $stderr"
  grep -q '^redis-rdb-sync --tls --insecure r 6379 ' "$TMP/calls" || fail "$(cat "$TMP/calls")"
}

@test "without a password no REDISCLI_AUTH, also not one from the environment" {
  conf host=r
  REDISCLI_AUTH=leaked backup
  [ "$status" -eq 0 ] || fail "status $status: $stderr"
  ! grep -q 'auth=leaked' "$TMP/calls" || fail "$(cat "$TMP/calls")"
  grep -q 'auth=unset$' "$TMP/calls"
}

@test "comments, blank lines, CRLF line ends and spaces around the key are read" {
  printf '# Redis\r\n\r\n  host =r\r\nport=7000\r\npassword= lead\r\n' >"$TMP/cache.conf"
  backup
  [ "$status" -eq 0 ] || fail "status $status: $stderr"
  grep -q '^redis-rdb-sync r 7000 .* auth= lead$' "$TMP/calls" || fail "$(cat "$TMP/calls")"
}

@test "a bad config file fails with rc 2 and says why, before any connection" {
  local case
  for case in "host=r|bogus=1|unknown key 'bogus'" \
              "port=6379|host is not set" \
              "host=r|port=63x|port must be a number" \
              "host=r|tls=yes|tls must be true or false" \
              "host=r|just text|not a key=value line"; do
    IFS='|' read -r -a lines <<<"${case%|*}"
    conf "${lines[@]}"
    : >"$TMP/calls"
    backup
    [ "$status" -eq 2 ] || fail "$case: status $status"
    [[ $stderr == *"${case##*|}"* ]] || fail "$case: $stderr"
    [ ! -s "$TMP/calls" ] || fail "$case: $(cat "$TMP/calls")"
  done
}

@test "no config file, an unreadable one, or no DB_BACKUP_LOCATION: rc 2" {
  run "$BIN/backup-redis"
  [ "$status" -eq 2 ]
  run "$BIN/backup-redis" "$TMP/missing.conf"
  [ "$status" -eq 2 ]
  conf host=r
  DB_BACKUP_LOCATION="" run "$BIN/backup-redis" "$TMP/cache.conf"
  [ "$status" -eq 2 ]
}

@test "INFO refused (no +info): rc 2, the reason, and the message once" {
  conf host=r user=backup password=x
  echo "NOPERM User backup has no permissions to run the 'info' command" >"$TMP/info"
  backup
  [ "$status" -eq 2 ] || fail "status $status"
  [[ $stderr == *"the user needs +info"*"NOPERM"* ]] || fail "$stderr"
  ! grep -q redis-rdb-sync "$TMP/calls"
}

@test "a cluster: one RDB file per primary with slots, named after its first range, and CLUSTER NODES" {
  conf host=redis-cluster.cache.svc
  printf 'cluster_enabled:1\r\n' >"$TMP/info"
  printf '%s\n' "$CLUSTER_NODES" >"$TMP/nodes"
  backup
  [ "$status" -eq 0 ] || fail "status $status: $stderr"
  [ "$(files)" = "cache-cluster-nodes.txt 600
cache-slots-0-5460.rdb 600
cache-slots-10923-16383.rdb 600
cache-slots-5461-10921.rdb 600" ] || fail "$(files)"
  [ "$(cat "$TMP/dumps/cache/cache-slots-0-5460.rdb")" = "RDB 10.0.0.2:6379" ]
  [ "$(cat "$TMP/dumps/cache/cache-slots-5461-10921.rdb")" = "RDB 10.0.0.3:6379" ]
  [ "$(cat "$TMP/dumps/cache/cache-slots-10923-16383.rdb")" = "RDB 10.0.0.4:6380" ]
  [ "$(cat "$TMP/dumps/cache/cache-cluster-nodes.txt")" = "$CLUSTER_NODES" ]
}

@test "a cluster node that reports no address of its own is reached at the configured host" {
  conf host=redis-cluster.cache.svc port=7000
  printf 'cluster_enabled:1\r\n' >"$TMP/info"
  echo '07c37dfeb235213a872192d90877d0cd55635b91 :7000@17000 myself,master - 0 0 1 connected 0-16383' >"$TMP/nodes"
  backup
  [ "$status" -eq 0 ] || fail "status $status: $stderr"
  [ "$(cat "$TMP/dumps/cache/cache-slots-0-16383.rdb")" = "RDB redis-cluster.cache.svc:7000" ]
}

@test "CLUSTER NODES refused: rc 2 and the permission it needs" {
  conf host=r
  printf 'cluster_enabled:1\r\n' >"$TMP/info"
  echo "NOPERM User backup has no permissions to run the 'cluster|nodes' command" >"$TMP/nodes"
  backup
  [ "$status" -eq 2 ] || fail "status $status"
  [[ $stderr == *"+cluster|nodes"* ]] || fail "$stderr"
}

@test "one primary failing: rc 2, the previous dump intact, nothing half written left" {
  conf host=r
  printf 'cluster_enabled:1\r\n' >"$TMP/info"
  printf '%s\n' "$CLUSTER_NODES" >"$TMP/nodes"
  backup
  [ "$status" -eq 0 ] || fail "status $status: $stderr"
  before=$(cd "$TMP/dumps/cache" && cat ./*)
  # The second primary answers no more; the first one has new data.
  echo 10.0.0.3:6379 >"$TMP/broken"
  sed -i.bak 's/^echo "RDB /echo "NEW RDB /' "$TMP/stubs/redis-rdb-sync"
  backup
  [ "$status" -eq 2 ] || fail "status $status"
  [ "$(cd "$TMP/dumps/cache" && cat ./*)" = "$before" ] || fail "changed: $(cd "$TMP/dumps/cache" && head ./*)"
  [ "$(files | grep -c tmp)" -eq 0 ] || fail "$(files)"
  [ "$(grep -c 'redis backup failed' <<<"$stderr")" -eq 1 ] || fail "$stderr"
}

@test "files of an earlier layout are removed after a successful run, and only then" {
  conf host=r
  mkdir -p "$TMP/dumps/cache"
  for f in cache-slots-0-5460.rdb cache-cluster-nodes.txt cache.rdb.tmp notes.md; do echo old >"$TMP/dumps/cache/$f"; done
  echo r:6379 >"$TMP/broken"
  backup
  [ "$status" -eq 2 ] || fail "status $status"
  [ -e "$TMP/dumps/cache/cache-slots-0-5460.rdb" ] && [ -e "$TMP/dumps/cache/cache-cluster-nodes.txt" ]
  : >"$TMP/broken"
  backup
  [ "$status" -eq 0 ] || fail "status $status: $stderr"
  [ "$(files)" = "cache.rdb 600
notes.md 644" ] || fail "$(files)"
}
