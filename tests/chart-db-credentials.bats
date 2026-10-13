#!/usr/bin/env bats
#
# The credentials resolver: the init container that writes the *.conf files
# of secretRef database instances. Its script is taken from the rendered
# console StatefulSet and run with a stub kubectl that serves the Secrets'
# keys, its /out and /static directories moved below $TMP: the files must be
# what backup-mariadb / backup-mysql / backup-postgres read, passwords
# escaped, mode 600, and each client's option for no TLS for an instance with
# `tls: false`.

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
YAML

  # kubectl get secret -n NS NAME -o jsonpath={.data.KEY} → base64 of
  # $TMP/secrets/NS/NAME/KEY, as the API serves it.
  mkdir -p "$TMP/bin" "$TMP/secrets/db/maria" "$TMP/secrets/db/old-maria" "$TMP/secrets/db/pg-creds" \
    "$TMP/secrets/db/mysql" "$TMP/secrets/db/plain-mysql"
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
}

teardown() { common_teardown; }

# resolve — run the rendered resolver script; the files land in $TMP/out.
resolve() {
  helm template rel "$CHART" -n backup -f "$VALUES" \
    | yq 'select(.kind == "StatefulSet") | .spec.template.spec.initContainers[] | select(.name == "resolve-db-credentials") | .command[2]' \
    | sed -e "s|/out/|$TMP/out/|g" -e "s|/static/|$TMP/static/|g" >"$TMP/resolve.sh"
  grep -q "$TMP/out/" "$TMP/resolve.sh" || fail "no resolver script rendered: $(cat "$TMP/resolve.sh")"
  mkdir -p "$TMP/out/mariadb" "$TMP/out/mysql" "$TMP/out/postgres"
  PATH="$TMP/bin:$PATH" bash "$TMP/resolve.sh" || fail "the resolver failed"
}

@test "a MariaDB instance gets a defaults file, the password escaped, TLS left to the client" {
  resolve
  [ "$(cat "$TMP/out/mariadb/maria-tls.conf")" = '[client]
host=maria.db.svc
port=3306
user=root
password="r\"oot\\pw"' ] || fail "$(cat "$TMP/out/mariadb/maria-tls.conf")"
  [ "$(stat -c %a "$TMP/out/mariadb/maria-tls.conf" 2>/dev/null || stat -f %Lp "$TMP/out/mariadb/maria-tls.conf")" = 600 ]
}

@test "a MariaDB instance with tls: false gets skip-ssl" {
  resolve
  [ "$(cat "$TMP/out/mariadb/maria-plain.conf")" = '[client]
host=old-maria.db.svc
port=3307
user=backup
password="plain"
skip-ssl' ] || fail "$(cat "$TMP/out/mariadb/maria-plain.conf")"
}

@test "a MySQL instance gets a defaults file in its own directory, the password escaped, TLS left to the client" {
  resolve
  [ "$(cat "$TMP/out/mysql/mysql-tls.conf")" = '[client]
host=mysql.db.svc
port=3306
user=root
password="my\"sql\\pw"' ] || fail "$(cat "$TMP/out/mysql/mysql-tls.conf")"
  [ "$(stat -c %a "$TMP/out/mysql/mysql-tls.conf" 2>/dev/null || stat -f %Lp "$TMP/out/mysql/mysql-tls.conf")" = 600 ]
  [ ! -e "$TMP/out/mariadb/mysql-tls.conf" ]
}

@test "a MySQL instance with tls: false gets ssl-mode=DISABLED and the server's public key" {
  resolve
  [ "$(cat "$TMP/out/mysql/mysql-plain.conf")" = '[client]
host=plain-mysql.db.svc
port=3307
user=backup
password="plain"
ssl-mode=DISABLED
get-server-public-key' ] || fail "$(cat "$TMP/out/mysql/mysql-plain.conf")"
}

@test "a PostgreSQL instance gets a pgpass line, ':' and '\\' escaped" {
  resolve
  [ "$(cat "$TMP/out/postgres/pg.conf")" = 'pg.db.svc:5432:*:zalando:pg\:pa\\ss' ] \
    || fail "$(cat "$TMP/out/postgres/pg.conf")"
}
