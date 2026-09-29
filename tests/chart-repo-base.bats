#!/usr/bin/env bats
#
# The repository base of the clients. Borg 2.0.0b25 has no rest:// scheme and
# reads such a URL as a local directory, so the chart refuses it where it can
# see it: in borg.repoBase.value. Nothing else about the rendered manifests
# changes.

setup() {
  load helpers/common
  command -v helm >/dev/null || fail "helm is required for the chart tests"
  CHART="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/chart"
  VALUES="$BATS_TEST_TMPDIR/values.yaml"
  cat >"$VALUES" <<'YAML'
borg:
  passphrase:
    value: "test"
ssh:
  privateKey: "test"
  publicKey: "test"
  knownHosts: "test"
YAML
}

render() { helm template rel "$CHART" -n backup -f "$VALUES" "$@"; }

# env_value NAME — the value of the first container variable of that name.
env_value() {
  awk -v name="$1" '
    $1 == "-" && $2 == "name:" && $3 == name { hit = 1; next }
    hit && $1 == "value:" { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/"/, ""); print; exit }
    hit && $1 == "-" { exit }
  ' <<<"$RENDERED"
}

@test "a rest:// base is refused for Borg 2, and the message names ssh://" {
  run render --set borg.version=2 --set borg.repoBase.value=rest://user@backup.example.com/cluster
  [ "$status" -ne 0 ] || fail "rendered although it should not"
  [[ "$output" == *"borg.repoBase.value"* ]] || fail "$output"
  [[ "$output" == *"ssh://"* ]] || fail "$output"
  [[ "$output" == *"2.0.0b25"* ]] || fail "$output"
}

@test "the scheme is matched in any case and behind white space" {
  for base in "REST://user@backup.example.com/cluster" " rest://user@backup.example.com/cluster"; do
    run render --set borg.version=2 --set-string "borg.repoBase.value=$base"
    [ "$status" -ne 0 ] || fail "\"$base\" rendered although it should not"
    [[ "$output" == *"ssh://"* ]] || fail "$output"
  done
}

@test "the bases Borg 2 knows are rendered" {
  for base in ssh://user@backup.example.com:2222/cluster ssh://user@backup.example.com//srv/cluster \
              sftp://user@backup.example.com/cluster /mnt/rest://cluster; do
    run render --set borg.version=2 --set-string "borg.repoBase.value=$base"
    [ "$status" -eq 0 ] || fail "$base: $output"
    [[ "$output" == *"BORG_REPO_BASE: \"$base\""* ]] || fail "$base is not in the Secret"
  done
}

@test "a base from an existing Secret is not validated at render time" {
  # The chart cannot see it. The borg2 wrapper refuses it at run time.
  run render --set borg.version=2 --set borg.repoBase.existingSecret=repo-base
  [ "$status" -eq 0 ] || fail "$output"
  # A value next to the Secret is not used, so it is not judged either.
  run render --set borg.version=2 --set borg.repoBase.existingSecret=repo-base \
    --set borg.repoBase.value=rest://user@backup.example.com/cluster
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" != *"rest://"* ]] || fail "the unused value was rendered"
}

@test "borg.remotePath reaches the pods as BORG_REMOTE_PATH, for both majors" {
  for version in 1 2; do
    RENDERED="$(render --set borg.version=$version --set borg.repoBase.value=ssh://user@backup.example.com/cluster \
      --set borg.remotePath=borg-custom)" || fail "borg $version did not render"
    [ "$(env_value BORG_REMOTE_PATH)" = "borg-custom" ] || fail "borg $version: $(env_value BORG_REMOTE_PATH)"
    [ "$(env_value BORG_VERSION)" = "$version" ] || fail "borg $version: BORG_VERSION=$(env_value BORG_VERSION)"
  done
}

@test "the validations render no object" {
  render --set borg.repoBase.value=ssh://user@backup.example.com/cluster >"$BATS_TEST_TMPDIR/all.yaml"
  if grep -q "^# Source: k8s-borg/templates/validations.yaml" "$BATS_TEST_TMPDIR/all.yaml"; then
    fail "validations.yaml rendered something"
  fi
}
