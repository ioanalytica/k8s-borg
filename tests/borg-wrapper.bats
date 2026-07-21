#!/usr/bin/env bats
#
# The `borg` gateway: version dispatch, default-param injection, --remote-path,
# warning handling and the stdout/stderr separation BorgUI depends on.
# The real borg binary is replaced by a stub via BORG1_BINARY/BORG2_BINARY.

bats_require_minimum_version 1.5.0   # run --separate-stderr

setup() {
  load helpers/common
  common_setup
}

teardown() { common_teardown; }

# --- version dispatch ---------------------------------------------------------

@test "dispatch: BORG_VERSION unset runs borg1" {
  make_fake_borg 0
  run "$BIN/borg" list
  [ "$status" -eq 0 ]
  [ "$(argv_line 1)" = "list" ]
}

@test "dispatch: BORG_VERSION=2 hands off to the borg2 wrapper" {
  make_fake_borg 1
  BORG_VERSION=2 run "$BIN/borg" repo-list
  # The borg2 wrapper owns the message, so its prefix proves the hand-off.
  [[ "$output" == *"borg2: warning"* ]]
  [ "$(argv_line 1)" = "repo-list" ]
}

@test "dispatch: BORG_VERSION=1 stays on borg1" {
  make_fake_borg 1
  BORG_VERSION=1 run "$BIN/borg" list
  [[ "$output" == *"borg: warning"* ]]
  [[ "$output" != *"borg2: warning"* ]]
}

# --- argument handling --------------------------------------------------------

@test "args: defaults precede caller args so the caller wins (argparse last-wins)" {
  make_fake_borg 0
  BORG1_DEFAULT_PARAMS="--remote-path=borg-1.4" run "$BIN/borg" create --remote-path=borg-1.2
  [ "$(argv_line 1)" = "--remote-path=borg-1.4" ]
  [ "$(argv_line 2)" = "create" ]
  [ "$(argv_line 3)" = "--remote-path=borg-1.2" ]
}

@test "args: BORG1_DEFAULT_PARAMS word-splits into separate arguments" {
  make_fake_borg 0
  BORG1_DEFAULT_PARAMS="--foo --bar" run "$BIN/borg" list
  [ "$(argv_line 1)" = "--foo" ]
  [ "$(argv_line 2)" = "--bar" ]
  [ "$(argv_line 3)" = "list" ]
}

@test "args: BORG_REMOTE_PATH injects --remote-path ahead of the defaults" {
  make_fake_borg 0
  BORG_REMOTE_PATH=borg-1.4 run "$BIN/borg" list
  [ "$(argv_line 1)" = "--remote-path=borg-1.4" ]
  [ "$(argv_line 2)" = "list" ]
}

@test "args: no --remote-path when BORG_REMOTE_PATH is unset" {
  make_fake_borg 0
  run "$BIN/borg" list
  [[ "$(argv_joined)" != *"--remote-path"* ]]
}

@test "args: an empty BORG_REMOTE_PATH injects nothing" {
  make_fake_borg 0
  BORG_REMOTE_PATH="" run "$BIN/borg" list
  [ "$(argv_line 1)" = "list" ]
}

# --- warning handling ---------------------------------------------------------

@test "rc: legacy warning 1 is downgraded to 0" {
  make_fake_borg 1
  run "$BIN/borg" create
  [ "$status" -eq 0 ]
}

@test "rc: modern warning 100 is downgraded to 0" {
  make_fake_borg 100
  run "$BIN/borg" create
  [ "$status" -eq 0 ]
}

@test "rc: errors pass through untouched with their granular code" {
  for code in 2 73; do
    make_fake_borg "$code"
    run "$BIN/borg" create
    [ "$status" -eq "$code" ] || fail "rc=$code became $status"
  done
}

@test "rc: success stays 0 and prints no wrapper diagnostics" {
  make_fake_borg 0
  run "$BIN/borg" create
  [ "$status" -eq 0 ]
  [[ "$output" != *"treated as success"* ]]
}

@test "rc: BORG_TREAT_WARNINGS_AS_ERRORS=true propagates warnings unchanged" {
  make_fake_borg 1
  BORG_TREAT_WARNINGS_AS_ERRORS=true run "$BIN/borg" create
  [ "$status" -eq 1 ]
  make_fake_borg 100
  BORG_TREAT_WARNINGS_AS_ERRORS=true run "$BIN/borg" create
  [ "$status" -eq 100 ]
}

@test "rc: any value other than 'true' keeps the downgrade" {
  make_fake_borg 1
  BORG_TREAT_WARNINGS_AS_ERRORS=1 run "$BIN/borg" create
  [ "$status" -eq 0 ]
}

# --- stream invariant ---------------------------------------------------------
# BorgUI parses borg's stdout (--json) and reads stderr for warnings. A single
# stray wrapper line on stdout breaks that parse, so this is pinned explicitly.

@test "streams: borg stdout passes through byte-exact even when warning" {
  make_fake_borg 1 '{"archives":[]}' 'file changed while we backed it up'
  run --separate-stderr "$BIN/borg" create --json
  [ "$status" -eq 0 ]
  [ "$output" = '{"archives":[]}' ]
}

@test "streams: the wrapper's own diagnostics go to stderr" {
  make_fake_borg 1 '{"archives":[]}' ''
  run --separate-stderr "$BIN/borg" create --json
  [[ "$stderr" == *"treated as success"* ]]
}

@test "streams: borg stderr is not folded into stdout" {
  make_fake_borg 0 'STDOUT-PAYLOAD' 'STDERR-PAYLOAD'
  run --separate-stderr "$BIN/borg" list
  [ "$output" = "STDOUT-PAYLOAD" ]
  [ "$stderr" = "STDERR-PAYLOAD" ]
}
