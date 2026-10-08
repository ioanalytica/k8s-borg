#!/usr/bin/env bats
#
# The console pod shares its process namespace, so that the pause container is
# PID 1 and reaps orphaned processes (an s3fs that ends after its unmount):
# the agent, the container's main process, does not.

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
YAML
}

teardown() { common_teardown; }

# share_pns [HELM ARGS…] — shareProcessNamespace of the console StatefulSet.
share_pns() {
  helm template rel "$CHART" -n backup -f "$VALUES" "$@" \
    | awk '/^kind: /{k=$2} k=="StatefulSet" && /shareProcessNamespace:/{print $2; exit}'
}

@test "the console pod shares its process namespace" {
  [ "$(share_pns)" = "true" ] || fail "got '$(share_pns)'"
}

@test "also as a managed agent in plan mode" {
  [ "$(share_pns --set cluster.mode=agent --set cluster.backupMode=plan)" = "true" ] \
    || fail "got '$(share_pns --set cluster.mode=agent --set cluster.backupMode=plan)'"
}
