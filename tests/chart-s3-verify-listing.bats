#!/usr/bin/env bats
#
# s3.verifyListing reaches the cluster CronJob as S3_VERIFY_LISTING, on unless
# switched off; borg-backup reads it (see s3-verify-listing).

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
