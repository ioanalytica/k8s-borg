#!/usr/bin/env bats
#
# The chart's own claims (persistence.cache, .ui, .uiAgent) ask for
# ReadWriteMany unless persistence.<name>.accessModes says otherwise; storage
# such as k3s's local-path offers only ReadWriteOnce. Values without the key,
# as --reuse-values from an older chart leaves them, still ask for
# ReadWriteMany. A static PV (createPV) offers the modes of its claim, since a
# claim binds only to a volume that offers all of them. An existing claim is
# used as it is.

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
YAML
  CLAIMS=(cache ui ui-agent)
  STATIC=(--set persistence.cache.createPV=true --set persistence.ui.createPV=true
          --set persistence.uiAgent.createPV=true)
}

render() { helm template rel "$CHART" -n backup -f "$VALUES" "$@"; }

# modes KIND NAME ARGS… — the access modes of one rendered object, comma-separated.
modes() {
  local kind="$1" name="$2"
  shift 2
  render "$@" | yq "select(.kind == \"$kind\" and .metadata.name == \"$name\") | .spec.accessModes | join(\",\")"
}

@test "every claim asks for ReadWriteMany by default" {
  for claim in "${CLAIMS[@]}"; do
    got="$(modes PersistentVolumeClaim "rel-k8s-borg-$claim")"
    [ "$got" = ReadWriteMany ] || fail "claim $claim: $got"
  done
}

@test "every static volume offers ReadWriteMany by default" {
  for claim in "${CLAIMS[@]}"; do
    got="$(modes PersistentVolume "rel-k8s-borg-$claim-pv" "${STATIC[@]}")"
    [ "$got" = ReadWriteMany ] || fail "volume $claim: $got"
  done
}

@test "values without accessModes ask for ReadWriteMany, as after --reuse-values from an older chart" {
  # --reuse-values takes the defaults of the chart the release was installed
  # with; null removes the key from the coalesced values the same way.
  unset_all=("${STATIC[@]}" --set persistence.cache.accessModes=null
             --set persistence.ui.accessModes=null --set persistence.uiAgent.accessModes=null)
  for claim in "${CLAIMS[@]}"; do
    got="$(modes PersistentVolumeClaim "rel-k8s-borg-$claim" "${unset_all[@]}")"
    [ "$got" = ReadWriteMany ] || fail "claim $claim: $got"
    got="$(modes PersistentVolume "rel-k8s-borg-$claim-pv" "${unset_all[@]}")"
    [ "$got" = ReadWriteMany ] || fail "volume $claim: $got"
  done
}

@test "a claim's access modes change that claim only" {
  set_cache=(--set 'persistence.cache.accessModes={ReadWriteOnce}')
  got="$(modes PersistentVolumeClaim rel-k8s-borg-cache "${set_cache[@]}")"
  [ "$got" = ReadWriteOnce ] || fail "cache: $got"
  for claim in ui ui-agent; do
    got="$(modes PersistentVolumeClaim "rel-k8s-borg-$claim" "${set_cache[@]}")"
    [ "$got" = ReadWriteMany ] || fail "claim $claim: $got"
  done
}

@test "a static volume offers the modes of its claim" {
  set_agent=("${STATIC[@]}" --set 'persistence.uiAgent.accessModes={ReadWriteOnce,ReadOnlyMany}')
  got="$(modes PersistentVolumeClaim rel-k8s-borg-ui-agent "${set_agent[@]}")"
  [ "$got" = ReadWriteOnce,ReadOnlyMany ] || fail "claim: $got"
  got="$(modes PersistentVolume rel-k8s-borg-ui-agent-pv "${set_agent[@]}")"
  [ "$got" = ReadWriteOnce,ReadOnlyMany ] || fail "volume: $got"
}

@test "an existing claim is used as it is" {
  RENDERED="$(render "${STATIC[@]}" --set persistence.cache.existingClaim=my-cache \
    --set 'persistence.cache.accessModes={ReadWriteOnce}')"
  [ -z "$(yq 'select(.metadata.name == "rel-k8s-borg-cache" or .metadata.name == "rel-k8s-borg-cache-pv") | .kind' <<<"$RENDERED")" ] \
    || fail "rendered the chart's own cache claim or volume"
  yq 'select(.kind == "DaemonSet") | .spec.template.spec.volumes[] | select(.name == "cache") | .persistentVolumeClaim.claimName' <<<"$RENDERED" \
    | grep -qx my-cache
}
