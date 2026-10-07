#!/usr/bin/env bats
#
# s3.onMountFailure reaches the cluster CronJob and the console pod as
# S3_ON_MOUNT_FAILURE (skip unless set to fail, anything else refused), and in
# plan mode the cluster plan gets s3-check-mounts as a pre-backup hook, so that
# a bucket that is not mounted shows as a warning in Borg UI.

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

render() { helm template rel "$CHART" -n backup -f "$VALUES" "$@"; }

# env_of KIND NAME [HELM ARGS…] — the value of env var NAME in the first
# workload of KIND, or nothing when it is not rendered.
env_of() {
  local kind=$1 name=$2; shift 2
  render "$@" | awk -v k="$kind" -v n="$name" \
    '/^kind: /{kind=$2} kind==k && $0 ~ "name: "n"$" {getline; print $2; exit}' | tr -d '"'
}

plan_args=(--set cluster.mode=agent --set cluster.backupMode=plan)

@test "skip is the default in the CronJob and the console pod" {
  [ "$(env_of CronJob S3_ON_MOUNT_FAILURE)" = "skip" ] || fail "CronJob: '$(env_of CronJob S3_ON_MOUNT_FAILURE)'"
  [ "$(env_of StatefulSet S3_ON_MOUNT_FAILURE)" = "skip" ] || fail "StatefulSet: '$(env_of StatefulSet S3_ON_MOUNT_FAILURE)'"
}

@test "s3.onMountFailure=fail is passed on" {
  [ "$(env_of CronJob S3_ON_MOUNT_FAILURE --set s3.onMountFailure=fail)" = "fail" ] \
    || fail "got '$(env_of CronJob S3_ON_MOUNT_FAILURE --set s3.onMountFailure=fail)'"
}

@test "any other s3.onMountFailure is refused" {
  run render --set s3.onMountFailure=ignore
  [ "$status" -ne 0 ] || fail "rendered"
  [[ $output == *'s3.onMountFailure must be "skip" or "fail" (got "ignore")'* ]] || fail "$output"
}

@test "without S3 there is no policy" {
  [ -z "$(env_of CronJob S3_ON_MOUNT_FAILURE --set s3.enabled=false)" ] \
    || fail "got '$(env_of CronJob S3_ON_MOUNT_FAILURE --set s3.enabled=false)'"
}

@test "plan mode: s3-check-mounts is published and runs before the database dumps" {
  local out
  out="$(render "${plan_args[@]}" --set databases.postgres.enabled=true --set databases.postgres.existingSecret=pg)"
  grep -qx '    exec /usr/local/bin/s3-mount-buckets --check /root/.borg/cluster-s3-buckets' <<<"$out" \
    || fail "no s3-check-mounts script in the agent scripts"
  grep -A1 'name: BORG_PLAN_PRE_AGENT_SCRIPTS' <<<"$out" | grep -qx '              value: "s3-check-mounts backup-cluster-postgres"' \
    || fail "$(grep -A1 'name: BORG_PLAN_PRE_AGENT_SCRIPTS' <<<"$out")"
}

@test "plan mode without S3: no s3-check-mounts" {
  local out
  out="$(render "${plan_args[@]}" --set s3.enabled=false --set databases.postgres.enabled=true --set databases.postgres.existingSecret=pg)"
  ! grep -q 's3-check-mounts' <<<"$out" || fail "$(grep -n 's3-check-mounts' <<<"$out")"
}
