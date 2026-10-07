#!/usr/bin/env bats
#
# The reconcile Job keeps its reason: the finished Job and its pod stay for
# borgUI.reconcile.ttlSecondsAfterFinished (a day by default), the FATAL line
# lands in the pod status, and the gated agent pods' wait-for-reconcile prints
# the failure the Job of their revision left in the status ConfigMap.
#
# The init container's script is taken from the rendered manifest and run
# against tests/helpers/fake-borgui.py standing in for the k8s API.

bats_require_minimum_version 1.5.0   # run --separate-stderr

setup() {
  load helpers/common
  command -v helm >/dev/null || fail "helm is required for the chart tests"
  command -v yq >/dev/null || fail "yq is required for the chart tests"
  CHART="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/chart"
  BASE="$BATS_TEST_TMPDIR/base.yaml"
  VALUES="$BATS_TEST_TMPDIR/values.yaml"
  cat >"$BASE" <<'YAML'
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
cluster:
  enabled: true
  mode: agent
YAML
  : >"$VALUES"
}

teardown() {
  if [ -n "${FAKE_PID:-}" ]; then kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null || true; fi
}

render() { helm template rel "$CHART" -n backup -f "$BASE" -f "$VALUES" "$@"; }

job() { yq -o=json -I=0 'select(.kind == "Job")' <<<"$RENDERED"; }

@test "reconcile Job: a finished Job is kept for a day by default" {
  RENDERED="$(render)" || fail "did not render"
  [ "$(job | jq .spec.ttlSecondsAfterFinished)" = 86400 ] || fail "$(job | jq .spec)"
}

@test "reconcile Job: the TTL is a value" {
  RENDERED="$(render --set borgUI.reconcile.ttlSecondsAfterFinished=3600)" || fail "did not render"
  [ "$(job | jq .spec.ttlSecondsAfterFinished)" = 3600 ] || fail "$(job | jq .spec)"
}

@test "reconcile Job: the last log lines go into the pod status" {
  RENDERED="$(render)" || fail "did not render"
  [ "$(job | jq -r '.spec.template.spec.containers[0].terminationMessagePolicy')" = FallbackToLogsOnError ] \
    || fail "$(job | jq '.spec.template.spec.containers[0]')"
}

# wait_script — the wait-for-reconcile script of the console pod, pointed at
# the fake server and a ServiceAccount mount under $TMP.
wait_script() {
  RENDERED="$(render)" || fail "did not render"
  yq 'select(.kind == "StatefulSet") | .spec.template.spec.initContainers[] | select(.name == "wait-for-reconcile") | .command[2]' \
      <<<"$RENDERED" \
    | sed -e "s|/var/run/secrets/kubernetes.io/serviceaccount|$TMP/sa|" \
          -e "s|https://kubernetes.default.svc|$API|" >"$TMP/wait.sh"
  grep -q "$API" "$TMP/wait.sh" || fail "the script does not use the k8s API URL it is expected to"
}

# start_api DATA_JSON — the fake k8s API, holding the status ConfigMap with DATA.
start_api() {
  TMP="$BATS_TEST_TMPDIR"
  mkdir -p "$TMP/sa"
  printf backup >"$TMP/sa/namespace"
  printf sa-token >"$TMP/sa/token"
  : >"$TMP/sa/ca.crt"
  FAKE_DIR="$TMP" python3 "$BATS_TEST_DIRNAME/helpers/fake-borgui.py" 3>&- &
  FAKE_PID=$!
  local i
  for i in $(seq 50); do [ -f "$TMP/port" ] && break; sleep 0.1; done
  [ -f "$TMP/port" ] || fail "the fake server did not start"
  API="http://127.0.0.1:$(cat "$TMP/port")"
  curl -fsS -X PATCH -H "Authorization: Bearer sa-token" -H "Content-Type: application/merge-patch+json" \
    -d "{\"data\": $1}" \
    "$API/api/v1/namespaces/backup/configmaps/rel-k8s-borg-reconcile-status" >/dev/null
}

# run_wait — run the script as the init container would, with revision 7.
run_wait() {
  local shell; shell="$(command -v dash || command -v sh)"
  RECONCILE_STATUS_CONFIGMAP=rel-k8s-borg-reconcile-status RECONCILE_TOKEN=7 RECONCILE_WAIT_SECONDS="$1" \
    run --separate-stderr "$shell" "$TMP/wait.sh"
}

@test "wait-for-reconcile: the failure of its own revision is shown once" {
  start_api '{"reconciled": "6", "lastError": "revision 7 at 2026-10-07T19:21:23Z: FATAL: OIDC configuration failed — HTTP 422"}'
  wait_script
  run_wait 4
  [ "$status" -eq 1 ] || fail "status $status: $output $stderr"
  [ "$(grep -c "The reconcile Job failed: revision 7 at 2026-10-07T19:21:23Z: FATAL: OIDC configuration failed — HTTP 422" <<<"$stderr")" = 1 ] \
    || fail "$stderr"
}

@test "wait-for-reconcile: a failure of an earlier revision is not shown" {
  start_api '{"reconciled": "6", "lastError": "revision 6 at 2026-10-07T19:21:23Z: FATAL: something old"}'
  wait_script
  run_wait 2
  [ "$status" -eq 1 ] || fail "status $status: $output $stderr"
  [[ "$stderr" != *"something old"* ]] || fail "$stderr"
}

@test "wait-for-reconcile: proceeds once its revision is reconciled" {
  start_api '{"reconciled": "7"}'
  wait_script
  run_wait 10
  [ "$status" -eq 0 ] || fail "status $status: $output $stderr"
  [[ "$output" == *"Reconcile complete — proceeding."* ]] || fail "$output"
}

@test "wait-for-reconcile: each request is bounded in time" {
  RENDERED="$(render)" || fail "did not render"
  script="$(yq 'select(.kind == "StatefulSet") | .spec.template.spec.initContainers[] | select(.name == "wait-for-reconcile") | .command[2]' <<<"$RENDERED")"
  [[ "$script" == *"curl -sS --connect-timeout 5 --max-time 10 "* ]] || fail "$script"
}
