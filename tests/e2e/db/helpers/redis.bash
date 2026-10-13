# shellcheck shell=bash
#
# Redis and Valkey side of the database tests: config files as the chart
# renders them, the seeded content, the cluster, a fingerprint to compare a
# restore with its source, and the restore itself as chart/README.md
# describes it: dump.rdb placed in the data directory of a stopped server,
# which then starts on it.

# The backup user's password: '=' in it, which a key=value line must carry
# through, besides what DB_PASSWORD (the administrator's) has.
BACKUP_PASSWORD='bk=pa"ss\w:rd'

# write_conf FILE HOST [KEY=VALUE…] — a config file in the chart's key=value
# format for the backup user.
write_conf() {
  local file=$1 host=$2
  shift 2
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "host=$host" user=backup "password=$BACKUP_PASSWORD" "$@" >"$file"
  chmod 600 "$file"
}

# rd HOST ARG… — valkey-cli as the administrator.
rd() {
  local host=$1
  shift
  REDISCLI_AUTH=$DB_PASSWORD valkey-cli -h "$host" "$@"
}

rd_ready() { [ "$(rd "$1" PING)" = PONG ]; }

# rd_valkey9 — the server is Valkey 9 or later (hash fields with a TTL).
rd_valkey9() { [ "$DB_ENGINE" = valkey ] && [ "${DB_VERSION%%.*}" -ge 9 ]; }

# rd_backup_user HOST — the ACL user chart/README.md documents.
rd_backup_user() {
  rd "$1" ACL SETUSER backup on ">$BACKUP_PASSWORD" +info +sync +replconf '+cluster|nodes' >/dev/null
}

# rd_seed HOST — every type, keys in two databases, a TTL, non-ASCII and
# binary values, enough bulk that the RDB file spans several Borg chunks,
# and on Valkey 9 a hash field with a TTL of its own.
rd_seed() {
  local h=$1
  rd "$h" SET str hello >/dev/null
  rd "$h" SET utf8 'Grüße ✓ 日本' >/dev/null
  head -c 4096 /dev/urandom | rd "$h" -x SET bin >/dev/null
  rd "$h" HSET h f1 v1 f2 v2 >/dev/null
  rd "$h" RPUSH l a b c >/dev/null
  rd "$h" SADD s x y z >/dev/null
  rd "$h" ZADD z 1 a 2.5 b >/dev/null
  rd "$h" XADD st '*' k v >/dev/null
  rd "$h" SET ttl v EX 86400 >/dev/null
  rd "$h" -n 3 SET db3 three >/dev/null
  if rd_valkey9; then
    rd "$h" HSET hft a 1 b 2 >/dev/null
    rd "$h" HEXPIRE hft 86400 FIELDS 1 a >/dev/null
  fi
  rd_bulk "$h" 1 20000
}

# rd_bulk HOST FIRST LAST — keys bulk:FIRST..LAST with 500 random characters
# each, which the server's own compression cannot shrink: the RDB file spans
# several of Borg's chunks.
rd_bulk() {
  head -c $(( ($3 - $2 + 1) * 375 )) /dev/urandom | base64 -w 500 \
    | awk -v i="$2" '{ printf "SET bulk:%d %s\n", i++, $0 }' | rd "$1" --pipe >/dev/null
}

# rd_fingerprint HOST [DB…] — every key of the databases (default 0 and 3)
# with the SHA-1 of its DUMP, sorted.
FP_SCRIPT='local out = {}
for _, k in ipairs(redis.call("KEYS", "*")) do out[#out + 1] = k .. "=" .. redis.sha1hex(redis.call("DUMP", k)) end
table.sort(out)
return out'
rd_fingerprint() {
  local host=$1 db dbs
  shift
  dbs=("$@")
  [ "$#" -gt 0 ] || dbs=(0 3)
  for db in "${dbs[@]}"; do
    rd "$host" -n "$db" EVAL "$FP_SCRIPT" 0 | sed "s/^/$db /"
  done
}

# rd_cluster — c1–c3 as a cluster of three primaries, ready on every node;
# then 3000 keys spread over the slots.
rd_cluster() {
  local nodes=() host ip i
  for host in c1 c2 c3; do
    ip=$(getent hosts "$host" | awk '{print $1}')
    nodes+=("$ip:6379")
  done
  REDISCLI_AUTH=$DB_PASSWORD valkey-cli --cluster create "${nodes[@]}" --cluster-yes >/dev/null
  for host in c1 c2 c3; do
    wait_for 60 rd_cluster_ok "$host"
  done
  # -c follows the MOVED redirects to the node that holds a key's slot.
  for ((i = 1; i <= 3000; i++)); do
    printf 'SET ck:%d v%d\n' "$i" "$i"
  done | rd c1 -c >/dev/null
}

# rd_cluster_ok HOST — HOST sees the cluster as ok, with three primaries.
rd_cluster_ok() {
  rd "$1" CLUSTER INFO | tr -d '\r' | grep -qx 'cluster_state:ok' \
    && [ "$(rd "$1" CLUSTER NODES | grep -c master)" -eq 3 ]
}

# rd_cluster_fingerprint — the union of the primaries' fingerprints (db 0).
rd_cluster_fingerprint() {
  local host
  for host in c1 c2 c3; do rd_fingerprint "$host" 0; done | LC_ALL=C sort
}

# rd_restore FILE — what chart/README.md describes: the server `dst` stopped
# without saving, FILE in place as its dump.rdb, the server started on it
# (`dst` restarts on its own; its data directory is /restore here).
rd_restore() {
  local before
  before=$(rd_run_id dst)
  # In place before the server stops: it would restart before a copy made
  # after. A server stopped with NOSAVE does not write the file.
  cp "$1" /restore/dump.rdb.new
  mv -f /restore/dump.rdb.new /restore/dump.rdb
  rd dst SHUTDOWN NOSAVE >/dev/null 2>&1 || true
  wait_for 60 rd_restarted dst "$before"
}

rd_run_id() { rd "$1" INFO server | tr -d '\r' | sed -n 's/^run_id://p'; }

# rd_restarted HOST RUN_ID — HOST answers as a process other than RUN_ID.
rd_restarted() {
  local now
  now=$(rd_run_id "$1") && [ -n "$now" ] && [ "$now" != "$2" ]
}
