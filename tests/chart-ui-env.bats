#!/usr/bin/env bats
#
# The Borg UI server's env: borgUI.errorReporting.enabled is always rendered as
# ERROR_REPORTING_ENABLED, so the release overrides the image default either
# way. borgUI.extraEnv is appended after the chart's env and may not repeat a
# name the chart sets, nor one of its own.

setup() {
  load helpers/common
  command -v helm >/dev/null || fail "helm is required for the chart tests"
  command -v yq >/dev/null || fail "yq is required for the chart tests"
  CHART="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/chart"
  VALUES="$BATS_TEST_TMPDIR/values.yaml"
  cat >"$VALUES" <<'YAML'
borg:
  repoBase:
    value: "ssh://user@backup.example.com/cluster"
  passphrase:
    value: "test"
ssh:
  privateKey: "test"
  publicKey: "test"
  knownHosts: "test"
borgUI:
  enabled: true
  adminPassword:
    value: "test"
YAML
}

render() { helm template rel "$CHART" -n backup -f "$VALUES" "$@"; }

# ui_env QUERY ARGS… — QUERY on the UI server container's env.
ui_env() {
  local query="$1"
  shift
  render -s templates/ui-deployment.yaml "$@" | yq ".spec.template.spec.containers[0].env | $query"
}

# extra YAML — borgUI.extraEnv from a values file.
extra() {
  printf 'borgUI:\n  extraEnv:\n%s\n' "$1" >"$BATS_TEST_TMPDIR/extra.yaml"
}

@test "error reporting: rendered as \"true\" by default, like the image" {
  run ui_env '.[] | select(.name == "ERROR_REPORTING_ENABLED") | .value'
  [ "$status" -eq 0 ] || fail "$output"
  [ "$output" = "true" ] || fail "got $output"
}

@test "error reporting: enabled=false renders the string \"false\"" {
  run ui_env '.[] | select(.name == "ERROR_REPORTING_ENABLED") | .value | tag + " " + .' \
    --set borgUI.errorReporting.enabled=false
  [ "$status" -eq 0 ] || fail "$output"
  [ "$output" = "!!str false" ] || fail "got $output"
}

@test "error reporting: a non-boolean value fails the render" {
  run render --set-string borgUI.errorReporting.enabled=false
  [ "$status" -ne 0 ] || fail "rendered with the string \"false\""
  [[ "$output" == *"borgUI.errorReporting.enabled must be true or false"* ]] || fail "$output"
}

@test "extraEnv: empty by default, the chart's env unchanged" {
  run ui_env '[.[].name] | join(",")'
  [ "$status" -eq 0 ] || fail "$output"
  [ "$output" = "TZ,PUBLIC_BASE_URL,INITIAL_ADMIN_PASSWORD,ENABLE_STARTUP_LICENSE_SYNC,ACTIVATION_SERVICE_URL,ERROR_REPORTING_ENABLED" ] || fail "got $output"
}

@test "extraEnv: appended after the chart's env, value and valueFrom kept" {
  extra '    - name: LOG_LEVEL
      value: "DEBUG"
    - name: SOME_TOKEN
      valueFrom:
        secretKeyRef: { name: borgui-extra, key: token }'
  run ui_env '.[-2:] | to_json(0)' -f "$BATS_TEST_TMPDIR/extra.yaml"
  [ "$status" -eq 0 ] || fail "$output"
  [ "$output" = '[{"name":"LOG_LEVEL","value":"DEBUG"},{"name":"SOME_TOKEN","valueFrom":{"secretKeyRef":{"key":"token","name":"borgui-extra"}}}]' ] || fail "got $output"
  run ui_env '[.[] | select(.name == "ERROR_REPORTING_ENABLED")] | length' -f "$BATS_TEST_TMPDIR/extra.yaml"
  [ "$output" = "1" ] || fail "ERROR_REPORTING_ENABLED entries: $output"
}

@test "extraEnv: a name the chart sets fails the render" {
  extra '    - name: ERROR_REPORTING_ENABLED
      value: "false"'
  run render -f "$BATS_TEST_TMPDIR/extra.yaml"
  [ "$status" -ne 0 ] || fail "rendered a second ERROR_REPORTING_ENABLED"
  [[ "$output" == *"borgUI.extraEnv[0]: ERROR_REPORTING_ENABLED is set by the chart"* ]] || fail "$output"
}

@test "extraEnv: the check follows the values (REDIS_HOST only while the chart sets it)" {
  extra '    - name: REDIS_HOST
      value: "redis.example.com"'
  run render -f "$BATS_TEST_TMPDIR/extra.yaml" --set borgUI.redis.mode=internal
  [ "$status" -ne 0 ] || fail "rendered a second REDIS_HOST"
  [[ "$output" == *"REDIS_HOST is set by the chart"* ]] || fail "$output"
  run ui_env '.[-1].value' -f "$BATS_TEST_TMPDIR/extra.yaml" --set borgUI.redis.mode=disabled
  [ "$status" -eq 0 ] || fail "$output"
  [ "$output" = "redis.example.com" ] || fail "got $output"
}

@test "extraEnv: a name listed twice fails the render" {
  extra '    - name: LOG_LEVEL
      value: "DEBUG"
    - name: LOG_LEVEL
      value: "INFO"'
  run render -f "$BATS_TEST_TMPDIR/extra.yaml"
  [ "$status" -ne 0 ] || fail "rendered LOG_LEVEL twice"
  [[ "$output" == *"borgUI.extraEnv: LOG_LEVEL is listed twice"* ]] || fail "$output"
}

@test "extraEnv: no list, or an entry without a name, fails the render" {
  printf 'borgUI:\n  extraEnv:\n    LOG_LEVEL: DEBUG\n' >"$BATS_TEST_TMPDIR/extra.yaml"
  run render -f "$BATS_TEST_TMPDIR/extra.yaml"
  [ "$status" -ne 0 ] || fail "rendered a map"
  [[ "$output" == *"borgUI.extraEnv must be a list of EnvVar objects"* ]] || fail "$output"
  extra '    - value: "DEBUG"'
  run render -f "$BATS_TEST_TMPDIR/extra.yaml"
  [ "$status" -ne 0 ] || fail "rendered an entry without a name"
  [[ "$output" == *"borgUI.extraEnv[0] must be an EnvVar object with a name"* ]] || fail "$output"
}
