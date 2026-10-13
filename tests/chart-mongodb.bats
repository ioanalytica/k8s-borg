#!/usr/bin/env bats
#
# databases.mongodb in the chart: a static config becomes a Secret mounted at
# /root/.mongodb, backup-cluster-mongodb is published to the cluster agent and
# attached to the plan, secretRef instances get their get-only Role, and the
# rendered credentials resolver writes the files backup-mongodb reads. The
# resolver script is taken from the rendered console StatefulSet and run with
# a stub kubectl that serves the Secrets' keys, as the API does: base64, and
# nothing (rc 0) for a key the Secret does not have.

setup() {
  load helpers/common
  common_setup
  command -v helm >/dev/null || fail "helm is required for the chart tests"
  command -v yq >/dev/null || fail "yq is required for the chart tests"
  CHART="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/chart"
  BASE="$TMP/base.yaml" VALUES="$TMP/values.yaml"
  cat >"$BASE" <<'YAML'
borg:
  passphrase:
    value: "test"
  repoBase:
    value: "ssh://borg@backup.example.com/./cluster"
ssh:
  privateKey: "test"
  publicKey: "test"
  knownHosts: "test"
YAML
  cat "$BASE" - >"$VALUES" <<'YAML'
cluster:
  mode: agent
  backupMode: plan
databases:
  mongodb:
    enabled: true
    instances:
      - name: static
        config: |
          uri: mongodb://backup@mongo.db.svc:27017/?authSource=admin
          password: 'pw'
      - name: community
        secretRef: { namespace: db, name: ex-admin-backup, uriKey: connectionString.standard }
      - name: percona
        host: ex-rs0.db2.svc
        options: authSource=admin&replicaSet=rs0
        secretRef: { namespace: db2, name: ex-secrets, usernameKey: MONGODB_BACKUP_USER, passwordKey: MONGODB_BACKUP_PASSWORD }
      - name: bitnami
        host: mongo.db.svc
        port: 27018
        user: root
        secretRef: { namespace: db, name: mongo, passwordKey: mongodb-root-password }
YAML

  # kubectl get secret -n NS NAME -o jsonpath={.data.KEY} → base64 of
  # $TMP/secrets/NS/NAME/KEY; a '.' in KEY comes escaped as '\.'.
  mkdir -p "$TMP/bin" "$TMP/secrets/db/ex-admin-backup" "$TMP/secrets/db2/ex-secrets" "$TMP/secrets/db/mongo"
  cat >"$TMP/bin/kubectl" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$TMP/kubectl.calls"
key=\${7#jsonpath=\{.data.}; key=\${key%\}}; key=\${key//\\\\./.}
[ ! -e "$TMP/secrets/\$4/\$5/\$key" ] || base64 <"$TMP/secrets/\$4/\$5/\$key"
EOF
  chmod +x "$TMP/bin/kubectl"
  printf '%s' "mongodb://backup:p%40ss@ex-0.ex-svc.db.svc.cluster.local:27017/admin?replicaSet=ex&ssl=false" \
    >"$TMP/secrets/db/ex-admin-backup/connectionString.standard"
  printf '%s' 'back@up:x' >"$TMP/secrets/db2/ex-secrets/MONGODB_BACKUP_USER"
  printf '%s' "it's \"q\"\\ :@/%#" >"$TMP/secrets/db2/ex-secrets/MONGODB_BACKUP_PASSWORD"
  printf '%s' 'rootpw' >"$TMP/secrets/db/mongo/mongodb-root-password"
}

teardown() { common_teardown; }

render() { helm template rel "$CHART" -n backup -f "$VALUES" "$@"; }
# render_one [HELM ARGS…] — without the instances above, MongoDB enabled.
render_one() { helm template rel "$CHART" -n backup -f "$BASE" --set databases.mongodb.enabled=true "$@"; }

# resolve — run the rendered resolver script; the files land in $TMP/out.
resolve() {
  render \
    | yq 'select(.kind == "StatefulSet") | .spec.template.spec.initContainers[] | select(.name == "resolve-db-credentials") | .command[2]' \
    | sed -e "s|/out/|$TMP/out/|g" -e "s|/static/|$TMP/static/|g" >"$TMP/resolve.sh"
  grep -q "$TMP/out/mongodb" "$TMP/resolve.sh" || fail "no resolver script rendered: $(cat "$TMP/resolve.sh")"
  mkdir -p "$TMP/out/mongodb"
  PATH="$TMP/bin:$PATH" bash "$TMP/resolve.sh"
}

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

@test "a static config becomes the chart's Secret, one file per instance" {
  out="$(render)"
  [ "$(yq 'select(.kind == "Secret" and .metadata.name == "rel-k8s-borg-mongodb") | .stringData["static.conf"]' <<<"$out")" = \
    "uri: mongodb://backup@mongo.db.svc:27017/?authSource=admin
password: 'pw'" ] || fail "$(yq 'select(.kind == "Secret")' <<<"$out")"
}

@test "the console pod reads the files at /root/.mongodb and publishes backup-cluster-mongodb" {
  out="$(render)"
  [ "$(yq 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0].volumeMounts[] | select(.mountPath == "/root/.mongodb") | .name' <<<"$out")" = mongodb-conf ] \
    || fail "no /root/.mongodb mount"
  [ "$(yq 'select(.kind == "ConfigMap" and .metadata.name == "rel-k8s-borg-cluster-agent-scripts") | .data["backup-cluster-mongodb"]' <<<"$out")" = \
    '#!/bin/sh
exec /usr/local/bin/backup-cluster-mongodb "$@"' ] || fail "backup-cluster-mongodb not published"
  [ "$(yq 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0].env[] | select(.name == "BORG_PLAN_PRE_AGENT_SCRIPTS") | .value' <<<"$out")" = \
    backup-cluster-mongodb ] || fail "not attached to the plan"
}

@test "the CronJob mounts the static Secret when no instance uses secretRef" {
  out="$(render_one --set 'databases.mongodb.instances[0].name=static' \
    --set 'databases.mongodb.instances[0].config=uri: mongodb://h/')"
  [ "$(yq 'select(.kind == "CronJob") | .spec.jobTemplate.spec.template.spec.volumes[] | select(.name == "mongodb-secret") | .secret.secretName' <<<"$out")" = \
    rel-k8s-borg-mongodb ] || fail "$(yq 'select(.kind == "CronJob") | .spec.jobTemplate.spec.template.spec.volumes' <<<"$out")"
  [ -z "$(yq 'select(.kind == "CronJob") | .spec.jobTemplate.spec.template.spec.initContainers[]? | select(.name == "resolve-db-credentials")' <<<"$out")" ] \
    || fail "a resolver without secretRef instances"
}

@test "each referenced namespace gets a get-only Role for exactly its Secrets" {
  out="$(render)"
  [ "$(yq 'select(.kind == "Role") | .metadata.namespace + ": " + (.rules[0].resourceNames | join(","))' <<<"$out" | grep -v '^---' | sort)" = \
    "db2: ex-secrets
db: ex-admin-backup,mongo" ] || fail "$(yq 'select(.kind == "Role")' <<<"$out")"
}

@test "uriKey: the operator's connection string is the file's uri, unchanged" {
  resolve || fail "the resolver failed"
  [ "$(cat "$TMP/out/mongodb/community.conf")" = \
    "uri: 'mongodb://backup:p%40ss@ex-0.ex-svc.db.svc.cluster.local:27017/admin?replicaSet=ex&ssl=false'" ] \
    || fail "$(cat "$TMP/out/mongodb/community.conf")"
  [ "$(mode_of "$TMP/out/mongodb/community.conf")" = 600 ]
  grep -q 'jsonpath={.data.connectionString\\.standard}' "$TMP/kubectl.calls" || fail "$(cat "$TMP/kubectl.calls")"
}

@test "user and password keys: the user percent-encoded in the uri, the password a field of its own" {
  resolve || fail "the resolver failed"
  f="$TMP/out/mongodb/percona.conf"
  [ "$(yq .uri "$f")" = 'mongodb://back%40up%3Ax@ex-rs0.db2.svc:27017/?authSource=admin&replicaSet=rs0' ] || fail "$(cat "$f")"
  [ "$(yq .password "$f")" = "it's \"q\"\\ :@/%#" ] || fail "$(cat "$f")"
  [ "$(mode_of "$f")" = 600 ]
}

@test "a literal user, a port of its own, authSource=admin by default" {
  resolve || fail "the resolver failed"
  [ "$(cat "$TMP/out/mongodb/bitnami.conf")" = "uri: 'mongodb://root@mongo.db.svc:27018/?authSource=admin'
password: 'rootpw'" ] || fail "$(cat "$TMP/out/mongodb/bitnami.conf")"
}

@test "a key the Secret does not have stops the resolver" {
  rm "$TMP/secrets/db/ex-admin-backup/connectionString.standard"
  run resolve
  [ "$status" -ne 0 ] || fail "the resolver succeeded: $output"
  [[ "$output" == *"has no connectionString.standard"* ]] || fail "$output"
}

@test "invalid secretRef instances fail the render" {
  base=(--set databases.mongodb.instances[0].name=x --set databases.mongodb.instances[0].secretRef.namespace=db
        --set databases.mongodb.instances[0].secretRef.name=s)
  run render_one "${base[@]}" --set databases.mongodb.instances[0].secretRef.uriKey=u --set databases.mongodb.instances[0].host=h
  [ "$status" -ne 0 ] && [[ "$output" == *"uriKey is the whole connection string"* ]] || fail "uriKey + host: $output"
  run render_one "${base[@]}" --set databases.mongodb.instances[0].secretRef.uriKey=u --set databases.mongodb.instances[0].secretRef.passwordKey=p
  [ "$status" -ne 0 ] && [[ "$output" == *"uriKey is the whole connection string"* ]] || fail "uriKey + passwordKey: $output"
  run render_one "${base[@]}" --set databases.mongodb.instances[0].secretRef.passwordKey=p --set databases.mongodb.instances[0].user=u
  [ "$status" -ne 0 ] && [[ "$output" == *"host is required with secretRef (or secretRef.uriKey)"* ]] || fail "no host: $output"
  run render_one "${base[@]}" --set databases.mongodb.instances[0].host=h --set databases.mongodb.instances[0].secretRef.passwordKey=p
  [ "$status" -ne 0 ] && [[ "$output" == *"exactly one of user or secretRef.usernameKey"* ]] || fail "no user: $output"
  run render_one "${base[@]}" --set databases.mongodb.instances[0].secretRef.uriKey=u --set databases.mongodb.instances[0].port=27018
  [ "$status" -ne 0 ] && [[ "$output" == *"uriKey is the whole connection string"* ]] || fail "uriKey + port: $output"
  run render_one "${base[@]}" --set databases.mongodb.instances[0].secretRef.uriKey=u
  [ "$status" -eq 0 ] || fail "uriKey alone: $output"
}

@test "host, port and options that would change how the URI splits fail the render" {
  base=(--set databases.mongodb.instances[0].name=x --set databases.mongodb.instances[0].secretRef.namespace=db
        --set databases.mongodb.instances[0].secretRef.name=s --set databases.mongodb.instances[0].secretRef.passwordKey=p
        --set databases.mongodb.instances[0].user=u)
  for host in 'evil@h' 'h/admin' 'h?x=1' 'h:27017' 'a\,b' 'h#x'; do
    run render_one "${base[@]}" --set-string "databases.mongodb.instances[0].host=$host"
    [ "$status" -ne 0 ] && [[ "$output" == *"host must be one host name or IP address"* ]] || fail "host '$host': $output"
  done
  for port in 0 65536 '27017/x' 'x'; do
    run render_one "${base[@]}" --set databases.mongodb.instances[0].host=h --set-string "databases.mongodb.instances[0].port=$port"
    [ "$status" -ne 0 ] && [[ "$output" == *"port must be a port number"* ]] || fail "port '$port': $output"
  done
  for options in '?authSource=admin' 'a=1#x' 'a=1 &b=2'; do
    run render_one "${base[@]}" --set databases.mongodb.instances[0].host=h --set-string "databases.mongodb.instances[0].options=$options"
    [ "$status" -ne 0 ] && [[ "$output" == *"options is the URI's query"* ]] || fail "options '$options': $output"
  done
  for host in mongo.db.svc.cluster.local 10.0.0.5 '[fd00::1]'; do
    run render_one "${base[@]}" --set-string "databases.mongodb.instances[0].host=$host" --set databases.mongodb.instances[0].port=27018 \
      --set-string 'databases.mongodb.instances[0].options=authSource=admin&replicaSet=rs0&tlsCAFile=/etc/ca%20file.pem'
    [ "$status" -eq 0 ] || fail "host '$host': $output"
  done
}
