#!/usr/bin/env bats
#
# The credentials resolver: the init container that writes the *.conf files
# of secretRef database instances. Its script is taken from the rendered
# console StatefulSet and run by sh (POSIX: no Bash in the default image) with
# a stub kubectl that serves the Secrets' keys, its /out and /static
# directories moved below $TMP: the files must be
# what backup-mariadb / backup-mysql / backup-postgres / backup-mongodb /
# backup-redis read,
# values escaped for their file, mode 600, and each client's option for no TLS
# for an instance with `tls: false`. Every value reaches the script as one
# single-quoted word: nothing in it runs or expands. A Secret value keeps its
# trailing line breaks, written as \n where the file can carry them and
# refused where it cannot. Releases of the same name in two namespaces get
# Roles and RoleBindings of their own in a namespace both read Secrets from.

setup() {
  load helpers/common
  common_setup
  command -v helm >/dev/null || fail "helm is required for the chart tests"
  command -v yq >/dev/null || fail "yq is required for the chart tests"
  CHART="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/chart"
  VALUES="$TMP/values.yaml"
  cat >"$VALUES" <<'YAML'
borg:
  passphrase:
    value: "test"
  repoBase:
    value: "ssh://borg@backup.example.com/./cluster"
ssh:
  privateKey: "test"
  publicKey: "test"
  knownHosts: "test"
databases:
  mariadb:
    enabled: true
    instances:
      - name: maria-tls
        host: maria.db.svc
        user: root
        secretRef: { namespace: db, name: maria, passwordKey: root-password }
      - name: maria-plain
        host: old-maria.db.svc
        port: 3307
        tls: false
        secretRef: { namespace: db, name: old-maria, usernameKey: username, passwordKey: password }
  mysql:
    enabled: true
    instances:
      - name: mysql-tls
        host: mysql.db.svc
        user: root
        secretRef: { namespace: db, name: mysql, passwordKey: root-password }
      - name: mysql-plain
        host: plain-mysql.db.svc
        port: 3307
        tls: false
        secretRef: { namespace: db, name: plain-mysql, usernameKey: username, passwordKey: password }
  postgres:
    enabled: true
    instances:
      - name: pg
        host: pg.db.svc
        secretRef: { namespace: db, name: pg-creds, usernameKey: username, passwordKey: password }
  redis:
    enabled: true
    instances:
      - name: valkey-acl
        host: valkey.cache.svc
        cacert: /etc/cache-ca/ca.crt
        tls: true
        secretRef: { namespace: cache, name: valkey, usernameKey: username, passwordKey: password }
      - name: redis-default
        host: redis.cache.svc
        port: 6380
        insecure: true
        secretRef: { namespace: cache, name: redis, passwordKey: redis-password }
YAML

  # kubectl get secret -n NS NAME -o jsonpath={.data.KEY} → base64 of
  # $TMP/secrets/NS/NAME/KEY, as the API serves it.
  mkdir -p "$TMP/bin" "$TMP/secrets/db/maria" "$TMP/secrets/db/old-maria" "$TMP/secrets/db/pg-creds" \
    "$TMP/secrets/db/mysql" "$TMP/secrets/db/plain-mysql" "$TMP/secrets/cache/valkey" "$TMP/secrets/cache/redis"
  cat >"$TMP/bin/kubectl" <<EOF
#!/usr/bin/env bash
key=\${7#jsonpath=\{.data.}; key=\${key%\}}
base64 <"$TMP/secrets/\$4/\$5/\$key"
EOF
  chmod +x "$TMP/bin/kubectl"
  printf '%s' 'r"oot\pw' >"$TMP/secrets/db/maria/root-password"
  printf '%s' backup >"$TMP/secrets/db/old-maria/username"
  printf '%s' plain >"$TMP/secrets/db/old-maria/password"
  printf '%s' 'my"sql\pw' >"$TMP/secrets/db/mysql/root-password"
  printf '%s' backup >"$TMP/secrets/db/plain-mysql/username"
  printf '%s' plain >"$TMP/secrets/db/plain-mysql/password"
  printf '%s' zalando >"$TMP/secrets/db/pg-creds/username"
  printf '%s' 'pg:pa\ss' >"$TMP/secrets/db/pg-creds/password"
  printf '%s' backup >"$TMP/secrets/cache/valkey/username"
  printf '%s' 'p=w "d\ #x' >"$TMP/secrets/cache/valkey/password"
  printf '%s' plain >"$TMP/secrets/cache/redis/redis-password"
}

teardown() { common_teardown; }

# resolve [VALUES] — run the rendered resolver script (with VALUES over the
# ones above) in $TMP; the files land in $TMP/out.
resolve() {
  helm template rel "$CHART" -n backup -f "$VALUES" ${1:+-f "$1"} \
    | yq 'select(.kind == "StatefulSet") | .spec.template.spec.initContainers[] | select(.name == "resolve-db-credentials") | .command[2]' \
    | sed -e "s|/out/|$TMP/out/|g" -e "s|/static/|$TMP/static/|g" >"$TMP/resolve.sh"
  grep -q "$TMP/out/" "$TMP/resolve.sh" || fail "no resolver script rendered: $(cat "$TMP/resolve.sh")"
  mkdir -p "$TMP/out/mariadb" "$TMP/out/mysql" "$TMP/out/postgres" "$TMP/out/mongodb" "$TMP/out/redis"
  (cd "$TMP" && PATH="$TMP/bin:$PATH" sh "$TMP/resolve.sh")
}

@test "the resolver script is POSIX sh: the default image's shell is BusyBox ash" {
  command -v shellcheck >/dev/null || skip "shellcheck is not installed"
  resolve || fail "the resolver failed"
  run shellcheck -s sh -S warning "$TMP/resolve.sh"
  [ "$status" -eq 0 ] || fail "$output"
}

@test "a MariaDB instance gets a defaults file, the password escaped, TLS left to the client" {
  resolve || fail "the resolver failed"
  [ "$(cat "$TMP/out/mariadb/maria-tls.conf")" = '[client]
host="maria.db.svc"
port="3306"
user="root"
password="r\"oot\\pw"' ] || fail "$(cat "$TMP/out/mariadb/maria-tls.conf")"
  [ "$(stat -c %a "$TMP/out/mariadb/maria-tls.conf" 2>/dev/null || stat -f %Lp "$TMP/out/mariadb/maria-tls.conf")" = 600 ]
}

@test "a MariaDB instance with tls: false gets skip-ssl" {
  resolve || fail "the resolver failed"
  [ "$(cat "$TMP/out/mariadb/maria-plain.conf")" = '[client]
host="old-maria.db.svc"
port="3307"
user="backup"
password="plain"
skip-ssl' ] || fail "$(cat "$TMP/out/mariadb/maria-plain.conf")"
}

@test "a MySQL instance gets a defaults file in its own directory, the password escaped, TLS left to the client" {
  resolve || fail "the resolver failed"
  [ "$(cat "$TMP/out/mysql/mysql-tls.conf")" = '[client]
host="mysql.db.svc"
port="3306"
user="root"
password="my\"sql\\pw"' ] || fail "$(cat "$TMP/out/mysql/mysql-tls.conf")"
  [ "$(stat -c %a "$TMP/out/mysql/mysql-tls.conf" 2>/dev/null || stat -f %Lp "$TMP/out/mysql/mysql-tls.conf")" = 600 ]
  [ ! -e "$TMP/out/mariadb/mysql-tls.conf" ]
}

@test "a MySQL instance with tls: false gets ssl-mode=DISABLED and the server's public key" {
  resolve || fail "the resolver failed"
  [ "$(cat "$TMP/out/mysql/mysql-plain.conf")" = '[client]
host="plain-mysql.db.svc"
port="3307"
user="backup"
password="plain"
ssl-mode=DISABLED
get-server-public-key' ] || fail "$(cat "$TMP/out/mysql/mysql-plain.conf")"
}

@test "a PostgreSQL instance gets a pgpass line, ':' and '\\' escaped" {
  resolve || fail "the resolver failed"
  [ "$(cat "$TMP/out/postgres/pg.conf")" = 'pg.db.svc:5432:*:zalando:pg\:pa\\ss' ] \
    || fail "$(cat "$TMP/out/postgres/pg.conf")"
}

@test "a CloudNativePG Secret: user and password from it, the host from the values, not the Secret's short one" {
  # What CloudNativePG writes into <cluster>-superuser and <cluster>-app:
  # host is the bare service name, which resolves only in the cluster's own
  # namespace; pgpass carries it, and the application database, too.
  for secret in pg-test-superuser pg-test-app; do
    mkdir -p "$TMP/secrets/cnpg/$secret"
    printf '%s' pg-test-rw >"$TMP/secrets/cnpg/$secret/host"
    printf '%s' 5432 >"$TMP/secrets/cnpg/$secret/port"
  done
  printf '%s' postgres >"$TMP/secrets/cnpg/pg-test-superuser/username"
  printf '%s' 'su:pw' >"$TMP/secrets/cnpg/pg-test-superuser/password"
  printf '%s' 'pg-test-rw:5432:*:postgres:su:pw' >"$TMP/secrets/cnpg/pg-test-superuser/pgpass"
  printf '%s' app >"$TMP/secrets/cnpg/pg-test-app/username"
  printf '%s' app-pw >"$TMP/secrets/cnpg/pg-test-app/password"
  printf '%s' 'pg-test-rw:5432:app:app:app-pw' >"$TMP/secrets/cnpg/pg-test-app/pgpass"
  cat >"$TMP/cnpg.yaml" <<'YAML'
databases:
  postgres:
    instances:
      - name: cnpg-superuser
        host: pg-test-rw.cnpg.svc
        secretRef: { namespace: cnpg, name: pg-test-superuser, usernameKey: username, passwordKey: password }
      - name: cnpg-app
        host: pg-test-rw.cnpg.svc
        secretRef: { namespace: cnpg, name: pg-test-app, usernameKey: username, passwordKey: password }
YAML
  resolve "$TMP/cnpg.yaml" || fail "the resolver failed"
  [ "$(cat "$TMP/out/postgres/cnpg-superuser.conf")" = 'pg-test-rw.cnpg.svc:5432:*:postgres:su\:pw' ] \
    || fail "$(cat "$TMP/out/postgres/cnpg-superuser.conf")"
  [ "$(cat "$TMP/out/postgres/cnpg-app.conf")" = 'pg-test-rw.cnpg.svc:5432:*:app:app-pw' ] \
    || fail "$(cat "$TMP/out/postgres/cnpg-app.conf")"
}

# hostile VALUE — the values file with VALUE as each engine's literal user
# and, where the chart takes any, host.
hostile() {
  local v=$1
  v=${v//\\/\\\\}; v=${v//\"/\\\"}
  cat >"$TMP/hostile.yaml" <<YAML
databases:
  mariadb:
    instances:
      - { name: maria, host: "h-$v", user: "u-$v", secretRef: { namespace: db, name: maria, passwordKey: root-password } }
  mysql:
    instances:
      - { name: mysql, host: "h-$v", user: "u-$v", secretRef: { namespace: db, name: mysql, passwordKey: root-password } }
  postgres:
    instances:
      - { name: pg, host: "h-$v", user: "u-$v", secretRef: { namespace: db, name: pg-creds, passwordKey: password } }
  mongodb:
    enabled: true
    instances:
      - { name: mongo, host: mongo.db.svc, user: "u-$v", secretRef: { namespace: db, name: mongo, passwordKey: password } }
YAML
}

@test "values with \$(…), backticks, quotes, \$VARs and backslashes reach every file as they are, and nothing runs" {
  mkdir -p "$TMP/secrets/db/mongo"
  printf '%s' 'mongo-pw' >"$TMP/secrets/db/mongo/password"
  # shellcheck disable=SC2016  # the $ are the point
  value='$(touch ran-dollar)`touch ran-backtick` it'"'"'s "$HOME" \ ${PATH}'
  hostile "$value"
  resolve "$TMP/hostile.yaml" || fail "the resolver failed"
  [ -z "$(cd "$TMP" && ls ran-* 2>/dev/null)" ] || fail "ran: $(cd "$TMP" && ls ran-*)"

  # Option files: double-quoted, '\' and '"' escaped.
  esc=${value//\\/\\\\}; esc=${esc//\"/\\\"}
  for engine in mariadb mysql; do
    f="$TMP/out/$engine/${engine/mariadb/maria}.conf"
    grep -qxF "host=\"h-$esc\"" "$f" || fail "$(cat "$f")"
    grep -qxF "user=\"u-$esc\"" "$f" || fail "$(cat "$f")"
  done
  # pgpass: '\' and ':' escaped.
  pg=${value//\\/\\\\}; pg=${pg//:/\\:}
  [ "$(cat "$TMP/out/postgres/pg.conf")" = "h-$pg:5432:*:u-$pg:"'pg\:pa\\ss' ] || fail "$(cat "$TMP/out/postgres/pg.conf")"
  # MongoDB: the user percent-encoded in the URI.
  uri=$(yq .uri "$TMP/out/mongodb/mongo.conf")
  [[ "$uri" == "mongodb://u-%24%28touch%20ran-dollar%29%60touch%20ran-backtick%60%20it%27s%20%22%24HOME%22%20%5C%20%24%7BPATH%7D@mongo.db.svc:27017/?authSource=admin" ]] \
    || fail "$uri"
}

@test "a password's trailing line breaks are kept in the MariaDB and MySQL files, as \\n" {
  printf 'pw\n\n' >"$TMP/secrets/db/maria/root-password"
  printf 'pw\r\n' >"$TMP/secrets/db/mysql/root-password"
  resolve || fail "the resolver failed"
  grep -qxF 'password="pw\n\n"' "$TMP/out/mariadb/maria-tls.conf" || fail "$(cat "$TMP/out/mariadb/maria-tls.conf")"
  grep -qxF 'password="pw\r\n"' "$TMP/out/mysql/mysql-tls.conf" || fail "$(cat "$TMP/out/mysql/mysql-tls.conf")"
}

@test "a line break PostgreSQL's pgpass or MongoDB's file cannot carry stops the resolver, without the value" {
  printf 'secret-pw\n' >"$TMP/secrets/db/pg-creds/password"
  run resolve
  [ "$status" -ne 0 ] || fail "the resolver succeeded: $output"
  [[ "$output" == *"postgres instance pg: password holds a line break"* ]] || fail "$output"
  [[ "$output" != *secret-pw* ]] || fail "the value is in the output: $output"

  printf '%s' 'pg:pa\ss' >"$TMP/secrets/db/pg-creds/password"
  mkdir -p "$TMP/secrets/db/mongo"
  printf 'secret-pw\n' >"$TMP/secrets/db/mongo/password"
  cat >"$TMP/mongo.yaml" <<'YAML'
databases:
  mongodb:
    enabled: true
    instances:
      - { name: mongo, host: mongo.db.svc, user: root, secretRef: { namespace: db, name: mongo, passwordKey: password } }
YAML
  run resolve "$TMP/mongo.yaml"
  [ "$status" -ne 0 ] || fail "the resolver succeeded: $output"
  [[ "$output" == *"mongodb instance mongo: password holds a line break"* ]] || fail "$output"
  [[ "$output" != *secret-pw* ]] || fail "the value is in the output: $output"
}

@test "a Redis instance gets key=value lines, the password verbatim, TLS and CA as configured" {
  resolve || fail "the resolver failed"
  [ "$(cat "$TMP/out/redis/valkey-acl.conf")" = 'host=valkey.cache.svc
port=6379
user=backup
password=p=w "d\ #x
tls=true
cacert=/etc/cache-ca/ca.crt' ] || fail "$(cat "$TMP/out/redis/valkey-acl.conf")"
  [ "$(stat -c %a "$TMP/out/redis/valkey-acl.conf" 2>/dev/null || stat -f %Lp "$TMP/out/redis/valkey-acl.conf")" = 600 ]
}

@test "a Redis instance without a user is the default user" {
  resolve || fail "the resolver failed"
  [ "$(cat "$TMP/out/redis/redis-default.conf")" = 'host=redis.cache.svc
port=6380
password=plain
insecure=true' ] || fail "$(cat "$TMP/out/redis/redis-default.conf")"
}

@test "a Redis password with a line break or a CR stops the resolver, also a trailing one, without the value" {
  local password
  for password in 'secret\nlines' 'secret-trailing\n' 'secret-cr\r' 'sec\rret'; do
    # shellcheck disable=SC2059  # the \n and \r are meant
    printf "$password" >"$TMP/secrets/cache/redis/redis-password"
    run resolve
    [ "$status" -ne 0 ] || fail "$password: the resolver passed"
    [[ $output == *"redis instance redis-default: password holds a line break"* ]] || fail "$password: $output"
    [[ $output != *secret* ]] || fail "$password: the value is in the output: $output"
  done
}

@test "Redis values reach the file as they are, nothing in them runs" {
  # shellcheck disable=SC2016  # the $ are the point
  local value='$(touch ran-dollar)`touch ran-backtick` it'"'"'s "$HOME" \ ${PATH}'
  local v=${value//\\/\\\\}; v=${v//\"/\\\"}
  cat >"$TMP/redis.yaml" <<YAML
databases:
  redis:
    instances:
      - { name: redis-default, host: "h-$v", user: "u-$v", secretRef: { namespace: cache, name: redis, passwordKey: redis-password } }
YAML
  resolve "$TMP/redis.yaml" || fail "the resolver failed"
  [ -z "$(cd "$TMP" && ls ran-* 2>/dev/null)" ] || fail "ran: $(cd "$TMP" && ls ran-*)"
  [ "$(head -3 "$TMP/out/redis/redis-default.conf")" = "host=h-$value
port=6379
user=u-$value" ] || fail "$(cat "$TMP/out/redis/redis-default.conf")"
}

@test "a Redis secretRef instance takes at most one of user and usernameKey; the others exactly one" {
  run helm template rel "$CHART" -n backup -f "$VALUES" --set 'databases.redis.instances[0].user=x'
  [ "$status" -ne 0 ] && [[ $output == *"databases.redis.instances[0] must define at most one of user or secretRef.usernameKey"* ]] \
    || fail "$output"
  run helm template rel "$CHART" -n backup -f "$VALUES" --set 'databases.postgres.instances[0].secretRef.usernameKey=null'
  [ "$status" -ne 0 ] && [[ $output == *"databases.postgres.instances[0] must define exactly one of user or secretRef.usernameKey"* ]] \
    || fail "$output"
}

@test "releases of the same name in two namespaces get Roles and RoleBindings of their own in a namespace both list" {
  # names NAMESPACE — "Kind name roleRef" of the RBAC objects rendered into db.
  names() {
    helm template rel "$CHART" -n "$1" -f "$VALUES" \
      | yq -N 'select((.kind == "Role" or .kind == "RoleBinding") and .metadata.namespace == "db")
               | .kind + " " + .metadata.name + " " + (.roleRef.name // "-")'
  }
  a=$(names backup) b=$(names other)
  [ "$(printf '%s\n' "$a" | wc -l)" -eq 2 ] && [ "$(printf '%s\n' "$b" | wc -l)" -eq 2 ] || fail "backup: $a; other: $b"
  [ -z "$(comm -12 <(printf '%s\n' "$a" | awk '{print $2}' | sort) <(printf '%s\n' "$b" | awk '{print $2}' | sort))" ] \
    || fail "shared names: backup: $a; other: $b"
  # Each binding still points at its own release's Role.
  printf '%s\n' "$a" | awk '$1 == "RoleBinding" && $2 != $3 {exit 1}' || fail "$a"
}
