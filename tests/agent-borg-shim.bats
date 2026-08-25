#!/usr/bin/env bats
#
# The agent-only `borg` shim (usr/local/libexec/borg-ui-agent-bin/borg): for the
# agent the bare name `borg` must always mean Borg 1, whatever BORG_VERSION says
# in the pod — otherwise version detection reports Borg 2 twice and a Borg 1
# repo job would run the wrong major. The shim must still go THROUGH the
# gateway, so default params and warning downgrade keep applying.

bats_require_minimum_version 1.5.0

setup() {
  load helpers/common
  common_setup
  SHIM="$ROOTFS/usr/local/libexec/borg-ui-agent-bin/borg"
}

teardown() { common_teardown; }

# make_fake_borg_pair — distinct stubs for the two majors, so a test can tell
# WHICH binary answered (the shared make_fake_borg stub stands in for both).
make_fake_borg_pair() {
  printf '#!/usr/bin/env bash\necho "borg 1.4.5"\n' >"$TMP/fake-borg1"
  printf '#!/usr/bin/env bash\necho "borg 2.0.0b23"\n' >"$TMP/fake-borg2"
  chmod +x "$TMP/fake-borg1" "$TMP/fake-borg2"
  export BORG1_BINARY="$TMP/fake-borg1" BORG2_BINARY="$TMP/fake-borg2"
}

@test "shim: BORG_VERSION=2 is overridden — the real Borg 1 answers" {
  make_fake_borg_pair
  BORG_VERSION=2 run "$SHIM" --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"borg 1.4.5"* ]]
  [[ "$output" != *"2.0.0b23"* ]]
}

@test "shim: BORG_VERSION unset also lands on Borg 1" {
  make_fake_borg_pair
  run "$SHIM" --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"borg 1.4.5"* ]]
}

@test "shim: still goes through the gateway — args pass, warning downgraded" {
  make_fake_borg 1
  BORG_VERSION=2 run "$SHIM" list
  [ "$status" -eq 0 ]
  # The borg1 wrapper owns the downgrade message, proving the Borg 1 path.
  [[ "$output" == *"borg: warning"* ]]
  [[ "$output" != *"borg2: warning"* ]]
  [ "$(argv_line 1)" = "list" ]
}

@test "shim: errors pass through the gateway unchanged" {
  make_fake_borg 2
  BORG_VERSION=2 run "$SHIM" list
  [ "$status" -eq 2 ]
}
