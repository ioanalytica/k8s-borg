#!/usr/bin/env bats
#
# The Borg UI container's privileges follow borgUI.fuse. FUSE stays on by
# default and the container privileged, since containerd lets only privileged
# containers and device-plugin devices open /dev/fuse. A FUSE device plugin
# replaces privileged with SYS_ADMIN; FUSE off leaves only the capabilities the
# entrypoint needs. A containerSecurityContext the user set wins, {} included.

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

# ui QUERY ARGS… — QUERY on the UI server container.
ui() {
  local query="$1"
  shift
  render -s templates/ui-deployment.yaml "$@" | yq ".spec.template.spec.containers[0] | $query"
}

@test "FUSE on without a device plugin: privileged, as before" {
  run ui '.securityContext | to_json(0)'
  [ "$status" -eq 0 ] || fail "$output"
  [ "$output" = '{"privileged":true}' ] || fail "got $output"
  run ui '.resources'
  [ "$output" = "null" ] || fail "resources: $output"
}

@test "FUSE device plugin: not privileged, SYS_ADMIN, one device in the limits" {
  args=(--set borgUI.fuse.deviceResource=squat.ai/fuse --set borgUI.resources.limits.memory=1Gi)
  run ui '.securityContext.privileged' "${args[@]}"
  [ "$output" = "null" ] || fail "privileged: $output"
  run ui '.securityContext.capabilities | to_json(0)' "${args[@]}"
  [ "$output" = '{"drop":["ALL"],"add":["CHOWN","DAC_OVERRIDE","FOWNER","SETGID","SETUID","SYS_ADMIN"]}' ] || fail "got $output"
  # The setuid fusermount3 mounts; containerd's AppArmor profile denies mount.
  run ui '.securityContext.allowPrivilegeEscalation' "${args[@]}"
  [ "$output" = "true" ] || fail "allowPrivilegeEscalation: $output"
  run ui '.securityContext.appArmorProfile.type' "${args[@]}"
  [ "$output" = "Unconfined" ] || fail "appArmorProfile: $output"
  run ui '.securityContext.seccompProfile.type' "${args[@]}"
  [ "$output" = "RuntimeDefault" ] || fail "seccompProfile: $output"
  run ui '.resources.limits | to_json(0)' "${args[@]}"
  [ "$output" = '{"memory":"1Gi","squat.ai/fuse":1}' ] || fail "limits: $output"
}

@test "the reconcile Job never requests the FUSE device" {
  run render -s templates/ui-reconcile-job.yaml \
    --set borgUI.fuse.deviceResource=squat.ai/fuse --set borgUI.resources.limits.memory=1Gi
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" != *squat.ai/fuse* ]] || fail "the reconcile Job requests the FUSE device"
}

@test "FUSE off: not privileged, no escalation, no SYS_ADMIN, no device" {
  run ui '.securityContext | to_json(0)' --set borgUI.fuse.enabled=false
  [ "$status" -eq 0 ] || fail "$output"
  [ "$output" = '{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"],"add":["CHOWN","DAC_OVERRIDE","FOWNER","SETGID","SETUID"]},"seccompProfile":{"type":"RuntimeDefault"}}' ] || fail "got $output"
  run ui '.resources' --set borgUI.fuse.enabled=false
  [ "$output" = "null" ] || fail "resources: $output"
}

@test "a containerSecurityContext the user set wins, {} renders none" {
  run ui '.securityContext | to_json(0)' --set borgUI.containerSecurityContext.runAsUser=0
  [ "$output" = '{"runAsUser":0}' ] || fail "got $output"
  run ui '.securityContext' --set-json 'borgUI.containerSecurityContext={}'
  [ "$output" = "null" ] || fail "got $output"
}

@test "a device resource with FUSE off is refused" {
  run render --set borgUI.fuse.enabled=false --set borgUI.fuse.deviceResource=squat.ai/fuse
  [ "$status" -ne 0 ] || fail "rendered although it should not"
  [[ "$output" == *"borgUI.fuse.deviceResource"* ]] || fail "$output"
}
