#!/usr/bin/env bats
#
# The `borg2` wrapper. Same contract as `borg`, but it ALWAYS runs Borg 2
# regardless of BORG_VERSION — that is what makes it usable as the borg1
# wrapper's hand-off target and for borg2-only work in a BORG_VERSION=1 pod.

bats_require_minimum_version 1.5.0   # run --separate-stderr

setup() {
  load helpers/common
  common_setup
}

teardown() { common_teardown; }

@test "borg2: runs borg2 even when BORG_VERSION=1" {
  make_fake_borg 0
  BORG_VERSION=1 run "$BIN/borg2" repo-list
  [ "$status" -eq 0 ]
  [ "$(argv_line 1)" = "repo-list" ]
}

@test "borg2: uses BORG2_BINARY, not BORG1_BINARY" {
  make_fake_borg 0
  BORG1_BINARY=/nonexistent/borg1 run "$BIN/borg2" repo-list
  [ "$status" -eq 0 ]
}

@test "borg2: BORG2_DEFAULT_PARAMS precede the caller's arguments" {
  make_fake_borg 0
  BORG2_DEFAULT_PARAMS="--progress" run "$BIN/borg2" create
  [ "$(argv_line 1)" = "--progress" ]
  [ "$(argv_line 2)" = "create" ]
}

@test "borg2: warnings are downgraded, errors pass through" {
  make_fake_borg 100
  run "$BIN/borg2" create
  [ "$status" -eq 0 ]
  make_fake_borg 73
  run "$BIN/borg2" create
  [ "$status" -eq 73 ]
}

@test "borg2: BORG_TREAT_WARNINGS_AS_ERRORS=true propagates the modern warning" {
  make_fake_borg 100
  BORG_TREAT_WARNINGS_AS_ERRORS=true run "$BIN/borg2" create
  [ "$status" -eq 100 ]
}

@test "borg2: a missing /etc/borg-fuse.env is not fatal" {
  # The env file only exists inside the image; outside it the wrapper must still
  # run (the `[ -r ... ] &&` chain returns non-zero and must not abort).
  make_fake_borg 0
  run "$BIN/borg2" --version
  [ "$status" -eq 0 ]
}

@test "borg2: stdout stays clean while warning diagnostics go to stderr" {
  make_fake_borg 100 '{"repository":{}}' ''
  run --separate-stderr "$BIN/borg2" repo-info --json
  [ "$output" = '{"repository":{}}' ]
  [[ "$stderr" == *"borg2: warning"* ]]
}
