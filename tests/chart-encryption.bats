#!/usr/bin/env bats
#
# borg.encryption: the mode of the repositories the chart's workloads create,
# rendered as BORG_ENCRYPTION for borg-init and register-repo. Empty leaves the
# manifests as they were. A mode the chosen Borg major does not have fails the
# render, and the chart's list of modes is the one borg-encryption.sh accepts,
# so that the render and the pods cannot disagree. Borg's key files go to the
# uiAgent volume (BORG_KEYS_DIR) in every mode, so the keyfile modes survive the
# pod.

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

render() { helm template rel "$CHART" -n backup -f "$VALUES" "$@"; }

# chart_modes VERSION — the modes the chart accepts for that major, read from
# the message of a refused value.
chart_modes() {
  local out
  out=$(render --set "borg.version=$1" --set borg.encryption=no-such-mode 2>&1) && return 1
  sed -n 's/.*valid: \([^.]*\)\..*/\1/p' <<<"$out" | tr -d ',' | tr ' ' '\n' | sed '/^$/d'
}

# lib_labels — every mode named in a case label of borg_encryption.
lib_labels() {
  sed -n 's/^[[:space:]]*\([a-z0-9][a-z0-9 |-]*\))[[:space:]]*$/\1/p' \
    "$BORG_LIB_DIR/borg-encryption.sh" | tr '|' '\n' | tr -d ' ' | sed '/^$/d'
}

# lib_accepts VERSION MODE — whether borg-init would create a repository with it.
lib_accepts() {
  # shellcheck source=../docker/rootfs/usr/local/lib/borg-encryption.sh
  ( . "$BORG_LIB_DIR/borg-encryption.sh"; BORG_ENCRYPTION="$2" borg_encryption "$1" ) 2>/dev/null
}

@test "empty borg.encryption renders no BORG_ENCRYPTION and the same manifests" {
  for v in 1 2; do
    run render --set "borg.version=$v" --set node.backupMode=agent --set cluster.mode=agent --set borgUI.enabled=true
    [ "$status" -eq 0 ] || fail "$output"
    [[ "$output" != *BORG_ENCRYPTION* ]] || fail "Borg $v: BORG_ENCRYPTION rendered without a value"
    without="$output"
    run render --set "borg.version=$v" --set node.backupMode=agent --set cluster.mode=agent --set borgUI.enabled=true \
      --set-string borg.encryption=
    [ "$status" -eq 0 ] || fail "$output"
    [ "$output" = "$without" ] || fail "Borg $v: an explicitly empty value changed the manifests"
  done
}

@test "a mode reaches every workload that creates a repository" {
  run render --set borg.version=2 --set borg.encryption=authenticated --set cluster.mode=agent
  [ "$status" -eq 0 ] || fail "$output"
  # DaemonSet (node), StatefulSet (console pod) and CronJob (cluster backup).
  for kind in DaemonSet StatefulSet CronJob; do
    doc=$(awk -v kind="$kind" '/^---/ { keep = 0 } $0 == "kind: " kind { keep = 1 } keep' <<<"$output")
    [[ "$doc" == *$'- name: BORG_ENCRYPTION\n'*'value: "authenticated"'* ]] \
      || fail "$kind has no BORG_ENCRYPTION=authenticated"
  done
  [ "$(grep -c 'name: BORG_ENCRYPTION' <<<"$output")" -eq 3 ] || fail "BORG_ENCRYPTION outside the three workloads"
}

@test "a mode the major does not have fails the render and lists the valid ones" {
  run render --set borg.version=2 --set borg.encryption=repokey-blake2
  [ "$status" -ne 0 ] || fail "rendered although it should not"
  [[ "$output" == *'borg.encryption: "repokey-blake2" is not a Borg 2 mode'* ]] || fail "$output"
  [[ "$output" == *"valid: repokey-aes-ocb, "* ]] || fail "$output"

  run render --set borg.version=1 --set borg.encryption=repokey-aes-ocb
  [ "$status" -ne 0 ] || fail "rendered although it should not"
  [[ "$output" == *'borg.encryption: "repokey-aes-ocb" is not a Borg 1 mode'* ]] || fail "$output"
  [[ "$output" == *"valid: repokey-blake2, "* ]] || fail "$output"
}

@test "Borg 2 refuses none and authenticated-blake3, as borg-init does" {
  for mode in none authenticated-blake3; do
    run render --set borg.version=2 --set "borg.encryption=$mode"
    [ "$status" -ne 0 ] || fail "$mode rendered although it should not"
    [[ "$output" == *"is not a Borg 2 mode"* ]] || fail "$output"
  done
}

@test "the extractors find the lists they compare" {
  [ "$(chart_modes 2 | wc -l)" -ge 4 ] || fail "chart list for Borg 2: $(chart_modes 2)"
  [ "$(chart_modes 1 | wc -l)" -ge 4 ] || fail "chart list for Borg 1: $(chart_modes 1)"
  [ "$(lib_labels | wc -l)" -ge 8 ] || fail "case labels: $(lib_labels)"
}

@test "BORG_KEYS_DIR is on the uiAgent volume in every workload, whatever the mode" {
  for args in "--set borg.version=1" "--set borg.version=2" \
    "--set borg.version=1 --set borg.encryption=keyfile-blake2" \
    "--set borg.version=2 --set borg.encryption=keyfile-aes-ocb"; do
    # shellcheck disable=SC2086  # $args holds several options
    run render $args --set cluster.mode=agent
    [ "$status" -eq 0 ] || fail "$args: $output"
    for kind in DaemonSet StatefulSet CronJob; do
      doc=$(awk -v kind="$kind" '/^---/ { keep = 0 } $0 == "kind: " kind { keep = 1 } keep' <<<"$output")
      [[ "$doc" == *$'- name: BORG_KEYS_DIR\n'*'value: "/etc/borg-ui-agent/borg-keys"'* ]] \
        || fail "$args: $kind has no BORG_KEYS_DIR"
      # The directory is below the per-node mount of the uiAgent claim.
      ui=$(grep -A2 -E '^ *- name: ui-agent$' <<<"$doc" | sed 's/^ *//')
      [[ "$ui" == *$'- name: ui-agent\nmountPath: /etc/borg-ui-agent\nsubPathExpr: $(NODE_NAME)'* ]] \
        || fail "$args: $kind does not mount ui-agent at /etc/borg-ui-agent per node: $ui"
      [[ "$ui" == *$'- name: ui-agent\npersistentVolumeClaim:\nclaimName: rel-k8s-borg-ui-agent'* ]] \
        || fail "$args: $kind's ui-agent volume is not the uiAgent claim: $ui"
    done
    [ "$(grep -c 'name: BORG_KEYS_DIR' <<<"$output")" -eq 3 ] || fail "$args: BORG_KEYS_DIR outside the three workloads"
  done
}

@test "keyfile modes render for both majors" {
  for vm in 1:keyfile 1:keyfile-blake2 2:keyfile-aes-ocb 2:keyfile-chacha20-poly1305; do
    run render --set "borg.version=${vm%%:*}" --set "borg.encryption=${vm#*:}"
    [ "$status" -eq 0 ] || fail "$vm: $output"
    [[ "$output" == *"value: \"${vm#*:}\""* ]] || fail "$vm not rendered"
  done
}

@test "Borg 2: the chart accepts the modes borg-encryption.sh accepts" {
  chart=$(chart_modes 2 | sort)
  for mode in $chart; do
    lib_accepts 2 "$mode" || fail "the chart accepts $mode, borg-init refuses it"
  done
  for mode in $(lib_labels); do
    if ! lib_accepts 2 "$mode"; then
      ! grep -qxF "$mode" <<<"$chart" || fail "borg-init refuses $mode, the chart accepts it"
    else
      grep -qxF "$mode" <<<"$chart" || fail "borg-init accepts $mode, the chart refuses it"
    fi
  done
}

@test "Borg 1: the chart accepts the modes of Borg 1.4, passed through by borg-encryption.sh" {
  # The choices of `borg init --encryption` in Borg 1.4.5.
  borg14="authenticated authenticated-blake2 keyfile keyfile-blake2 none repokey repokey-blake2"
  lib=$( . "$BORG_LIB_DIR/borg-encryption.sh"; printf '%s\n' $BORG1_ENCRYPTION_MODES | sort | tr '\n' ' ')
  [ "$lib" = "$borg14 " ] || fail "BORG1_ENCRYPTION_MODES: $lib"
  chart=$(chart_modes 1 | sort | tr '\n' ' ')
  [ "$chart" = "$borg14 " ] || fail "chart: $chart"
  for mode in $borg14; do
    lib_accepts 1 "$mode" || fail "borg-init refuses $mode"
  done
}

@test "every accepted mode renders, as it is" {
  for v in 1 2; do
    for mode in $(chart_modes "$v"); do
      run render --set "borg.version=$v" --set "borg.encryption=$mode"
      [ "$status" -eq 0 ] || fail "Borg $v, $mode: $output"
      [[ "$output" == *"value: \"$mode\""* ]] || fail "Borg $v, $mode not rendered"
    done
  done
}

@test "the validations render no object" {
  run render --set borg.version=2 --set borg.encryption=authenticated --show-only templates/validations.yaml
  [ "$status" -ne 0 ] || fail "validations.yaml rendered an object"
  [[ "$output" == *"could not find template"* ]] || fail "$output"
}
