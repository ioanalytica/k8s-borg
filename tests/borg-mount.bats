#!/usr/bin/env bats
#
# `borg-mount`: the exit code is Borg's, not the one of the closing message.
# Whether a mount works is part of tests/e2e, which has FUSE.

bats_require_minimum_version 1.5.0

setup() {
  load helpers/common
  common_setup
  PATH="$BIN:$PATH"
  export BORG_REPO=ssh://user@host/repo
}

teardown() { common_teardown; }

@test "a failed mount ends with Borg's exit code and says so on stderr" {
  for version in 1 2; do
    make_fake_borg 13
    BORG_VERSION=$version run --separate-stderr "$BIN/borg-mount" archive
    [ "$status" -eq 13 ] || fail "borg $version: status $status"
    [[ "$stderr" == *"failed"* ]] || fail "borg $version: $stderr"
    [[ "$output" != *"successfully mounted"* ]] || fail "borg $version: $output"
  done
}

@test "a mount ends with 0" {
  for version in 1 2; do
    make_fake_borg 0
    BORG_VERSION=$version run "$BIN/borg-mount" archive
    [ "$status" -eq 0 ] || fail "borg $version: status $status"
    [[ "$output" == *"successfully mounted"* ]] || fail "borg $version: $output"
  done
}

@test "a warning that the wrapper hands on still counts as mounted" {
  make_fake_borg 100
  BORG_VERSION=2 BORG_TREAT_WARNINGS_AS_ERRORS=true run "$BIN/borg-mount" archive
  [ "$status" -eq 0 ] || fail "status $status"
  [[ "$output" == *"successfully mounted"* ]] || fail "$output"
}
