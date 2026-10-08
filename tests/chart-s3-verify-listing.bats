#!/usr/bin/env bats
#
# s3.verifyListing reaches the cluster CronJob as S3_VERIFY_LISTING, on unless
# switched off; borg-backup reads it (see s3-verify-listing). In plan mode the
# same switch publishes s3-verify-listing to the cluster agent and attaches it
# as the plan's first pre-backup hook, ahead of s3-check-mounts, continuing on
# error; off, it is neither published nor attached.

setup() {
  load helpers/common
  common_setup
  command -v helm >/dev/null || fail "helm is required for the chart tests"
  CHART="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/chart"
  VALUES="$BATS_TEST_TMPDIR/values.yaml"
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
s3:
  enabled: true
  endpoint: "http://s3.example:3900"
  accessKey:
    value: "key"
  secretKey:
    value: "secret"
cluster:
  s3Buckets: [pg-backups]
YAML
}

teardown() { common_teardown; }

# cronjob_verify_listing [HELM ARGS…] — the CronJob's S3_VERIFY_LISTING value,
# or nothing when the variable is not rendered.
cronjob_verify_listing() {
  helm template rel "$CHART" -n backup -f "$VALUES" "$@" \
    | awk '/^kind: /{k=$2} k=="CronJob" && /name: S3_VERIFY_LISTING/{getline; print $2}' | tr -d '"'
}

@test "the cluster run checks the S3 mounts by default" {
  [ "$(cronjob_verify_listing)" = "true" ] || fail "got '$(cronjob_verify_listing)'"
}

@test "s3.verifyListing=false switches the check off" {
  [ "$(cronjob_verify_listing --set s3.verifyListing=false)" = "false" ] \
    || fail "got '$(cronjob_verify_listing --set s3.verifyListing=false)'"
}

@test "without S3 there is nothing to check" {
  [ -z "$(cronjob_verify_listing --set s3.enabled=false)" ] \
    || fail "got '$(cronjob_verify_listing --set s3.enabled=false)'"
}

plan_args=(--set cluster.mode=agent --set cluster.backupMode=plan
           --set databases.postgres.enabled=true --set databases.postgres.existingSecret=pg)

# plan_env NAME [HELM ARGS…] — the console pod's value of env var NAME in plan
# mode, or nothing when it is not rendered.
plan_env() {
  local name=$1; shift
  helm template rel "$CHART" -n backup -f "$VALUES" "${plan_args[@]}" "$@" \
    | awk -v n="$name" '/^kind: /{k=$2} k=="StatefulSet" && $0 ~ "name: "n"$" {getline; print; exit}' \
    | sed 's/^ *value: //' | tr -d '"'
}

# agent_script NAME [HELM ARGS…] — the body of cluster agent script NAME.
agent_script() {
  local name=$1; shift
  helm template rel "$CHART" -n backup -f "$VALUES" "${plan_args[@]}" "$@" \
    | awk -v n="$name" '/^kind: /{k=$2} /^  name: /{cm=$2}
        k=="ConfigMap" && cm ~ /-cluster-agent-scripts$/ && $0 == "  "n": |" {on=1; next}
        on && /^    /{print; next} on{exit}' | sed 's/^    //'
}

@test "plan mode: s3-verify-listing is published to the cluster agent" {
  [ "$(agent_script s3-verify-listing)" = $'#!/bin/sh\nexec /usr/local/bin/s3-verify-listing /root/.borg/cluster-s3-buckets' ] \
    || fail "got '$(agent_script s3-verify-listing)'"
}

@test "plan mode: s3-verify-listing runs right after the fresh mount and continues on error" {
  [ "$(plan_env BORG_PLAN_PRE_AGENT_SCRIPTS)" = "s3-remount-buckets s3-verify-listing s3-check-mounts backup-cluster-postgres" ] \
    || fail "pre-backup: '$(plan_env BORG_PLAN_PRE_AGENT_SCRIPTS)'"
  [ "$(plan_env BORG_PLAN_PRE_AGENT_SCRIPTS_CONTINUE)" = "s3-remount-buckets s3-verify-listing s3-check-mounts" ] \
    || fail "continue: '$(plan_env BORG_PLAN_PRE_AGENT_SCRIPTS_CONTINUE)'"
}

@test "plan mode with s3.verifyListing=false: neither published nor attached" {
  [ -z "$(agent_script s3-verify-listing --set s3.verifyListing=false)" ] \
    || fail "published: '$(agent_script s3-verify-listing --set s3.verifyListing=false)'"
  [ "$(plan_env BORG_PLAN_PRE_AGENT_SCRIPTS --set s3.verifyListing=false)" = "s3-remount-buckets s3-check-mounts backup-cluster-postgres" ] \
    || fail "pre-backup: '$(plan_env BORG_PLAN_PRE_AGENT_SCRIPTS --set s3.verifyListing=false)'"
  [ "$(plan_env BORG_PLAN_PRE_AGENT_SCRIPTS_CONTINUE --set s3.verifyListing=false)" = "s3-remount-buckets s3-check-mounts" ] \
    || fail "continue: '$(plan_env BORG_PLAN_PRE_AGENT_SCRIPTS_CONTINUE --set s3.verifyListing=false)'"
}

@test "plan mode without S3: no s3-verify-listing" {
  [ -z "$(agent_script s3-verify-listing --set s3.enabled=false)" ] \
    || fail "published: '$(agent_script s3-verify-listing --set s3.enabled=false)'"
  [ "$(plan_env BORG_PLAN_PRE_AGENT_SCRIPTS --set s3.enabled=false)" = "backup-cluster-postgres" ] \
    || fail "pre-backup: '$(plan_env BORG_PLAN_PRE_AGENT_SCRIPTS --set s3.enabled=false)'"
  [ -z "$(plan_env BORG_PLAN_PRE_AGENT_SCRIPTS_CONTINUE --set s3.enabled=false)" ] \
    || fail "continue: '$(plan_env BORG_PLAN_PRE_AGENT_SCRIPTS_CONTINUE --set s3.enabled=false)'"
}
