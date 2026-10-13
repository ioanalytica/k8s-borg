#!/usr/bin/env bats
#
# Only the database engines a release configures are dumped
# (databases.<engine>.enabled AND at least one instance or an existingSecret):
# in plan mode only they are published to the cluster agent and attached as
# pre-backup hooks, in CronJob mode only they are in BORG_DB_ENGINES, which
# backup-cluster-databases runs; only they get their credentials volume. An
# enabled engine with nothing configured fails the render, naming the engine.
#
# The engines come from the chart's k8s-borg.databases.supported, so a new
# engine is covered here as soon as it is added there.

setup() {
  load helpers/common
  common_setup
  command -v helm >/dev/null || fail "helm is required for the chart tests"
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
YAML
  read -r -a ENGINES <<<"$(supported)"
}

teardown() { common_teardown; }

# supported — the chart's list of engines, from k8s-borg.databases.supported.
supported() {
  awk '/define "k8s-borg.databases.supported"/{on=1; next} on && /end -/{exit} on' \
    "$CHART/templates/_helpers.tpl"
}

# only ENGINE — helm args that configure ENGINE alone, by an existingSecret.
only() { printf -- '--set databases.%s.enabled=true --set databases.%s.existingSecret=%s-creds' "$1" "$1" "$1"; }

render() { helm template rel "$CHART" -n backup -f "$VALUES" "$@"; }
plan() { render --set cluster.mode=agent --set cluster.backupMode=plan "$@"; }
cron() { render --set cluster.backupMode=cronjob "$@"; }

# The plan's pre-backup hooks; the scripts published to the cluster agent;
# BORG_DB_ENGINES of the CronJob; the credentials volumes of a workload kind.
plan_hooks() {
  plan "$@" | awk '/^kind: /{k=$2} k=="StatefulSet" && /name: BORG_PLAN_PRE_AGENT_SCRIPTS$/{getline; print; exit}' \
    | sed 's/^ *value: //' | tr -d '"'
}
agent_scripts() {
  plan "$@" | awk '/^kind: /{k=$2} /^  name: /{cm=$2}
    k=="ConfigMap" && cm ~ /-cluster-agent-scripts$/ && /^  [^ ].*: \|/{sub(/^  /, ""); sub(/: \|.*/, ""); print}' \
    | sort | tr '\n' ' ' | sed 's/ $//'
}
cron_engines() {
  cron "$@" | awk '/^kind: /{k=$2} k=="CronJob" && /name: BORG_DB_ENGINES$/{getline; print; exit}' \
    | sed 's/^ *value: //' | tr -d '"'
}
db_volumes() {
  local kind=$1; shift
  cron "$@" | awk -v k="$kind" -v engines=" ${ENGINES[*]} " '/^kind: /{kd=$2}
    kd==k && /mountPath: \/root\/\.[a-z0-9]+$/ {e=$2; sub(/^\/root\/\./, "", e); if (index(engines, " " e " ")) print $2}' \
    | sort -u | tr '\n' ' ' | sed 's/ $//'
}

@test "the chart's engine list is read (the extraction itself)" {
  [ "${#ENGINES[@]}" -ge 2 ] || fail "engines: '${ENGINES[*]}'"
  for engine in "${ENGINES[@]}"; do
    [[ "$engine" =~ ^[a-z0-9]+$ ]] || fail "engine: '$engine'"
  done
}

@test "plan mode: an engine configured alone is the only one published and attached" {
  for engine in "${ENGINES[@]}"; do
    # shellcheck disable=SC2046
    [ "$(plan_hooks $(only "$engine"))" = "backup-cluster-$engine" ] \
      || fail "$engine: hooks '$(plan_hooks $(only "$engine"))'"
    # shellcheck disable=SC2046
    [ "$(agent_scripts $(only "$engine"))" = "backup-cluster-$engine" ] \
      || fail "$engine: scripts '$(agent_scripts $(only "$engine"))'"
  done
}

@test "CronJob mode: an engine configured alone is the only one that runs, the only one mounted" {
  for engine in "${ENGINES[@]}"; do
    # shellcheck disable=SC2046
    [ "$(cron_engines $(only "$engine"))" = "$engine" ] || fail "$engine: '$(cron_engines $(only "$engine"))'"
    # shellcheck disable=SC2046
    [ "$(db_volumes CronJob $(only "$engine"))" = "/root/.$engine" ] \
      || fail "$engine: mounts '$(db_volumes CronJob $(only "$engine"))'"
  done
}

@test "no engine configured: nothing published, attached, mounted or run" {
  [ -z "$(plan_hooks)" ] || fail "hooks '$(plan_hooks)'"
  [ -z "$(agent_scripts)" ] || fail "scripts '$(agent_scripts)'"
  cron | grep -q 'name: BORG_DB_ENGINES$' || fail "BORG_DB_ENGINES is not rendered"
  [ -z "$(cron_engines)" ] || fail "engines '$(cron_engines)'"
  [ -z "$(db_volumes CronJob)" ] || fail "mounts '$(db_volumes CronJob)'"
}

@test "every engine configured: all of them, in the chart's order" {
  local args=() engine hooks=()
  for engine in "${ENGINES[@]}"; do
    # shellcheck disable=SC2207
    args+=($(only "$engine"))
    hooks+=("backup-cluster-$engine")
  done
  [ "$(cron_engines "${args[@]}")" = "${ENGINES[*]}" ] || fail "'$(cron_engines "${args[@]}")'"
  [ "$(plan_hooks "${args[@]}")" = "${hooks[*]}" ] || fail "'$(plan_hooks "${args[@]}")'"
}

@test "an instance configures an engine as an existingSecret does" {
  [ "$(cron_engines --set databases.postgres.enabled=true \
        --set 'databases.postgres.instances[0].name=pg' \
        --set 'databases.postgres.instances[0].config=pg:5432:*:u:p')" = postgres ]
}

@test "an engine that is configured but not enabled is not dumped" {
  [ -z "$(cron_engines --set databases.postgres.existingSecret=pg)" ]
  [ -z "$(plan_hooks --set databases.postgres.existingSecret=pg)" ]
}

@test "an enabled engine without instances and existingSecret fails the render, naming it" {
  for engine in "${ENGINES[@]}"; do
    for mode in plan cron; do
      run "$mode" --set "databases.$engine.enabled=true"
      [ "$status" -ne 0 ] || fail "$engine/$mode rendered"
      [[ "$output" == *"databases.$engine.enabled is true, but the engine has no instances and no existingSecret"* ]] \
        || fail "$engine/$mode: $output"
    done
  done
}
