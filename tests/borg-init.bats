#!/usr/bin/env bats
#
# `borg-init`: what BORG_ENCRYPTION becomes on the command line of each Borg
# major, and what is refused before Borg runs. The real binaries are replaced by
# a stub; the modes against real repositories are part of tests/e2e.

bats_require_minimum_version 1.5.0

setup() {
  load helpers/common
  common_setup
  # borg-init finds `borg` on PATH, as in the image.
  PATH="$BIN:$PATH"
  export BORG_REPO=ssh://user@host/repo
  make_fake_borg 0
}

teardown() { common_teardown; }

@test "borg 2: the default is repokey-aes-ocb" {
  BORG_VERSION=2 run "$BIN/borg-init"
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(argv_joined)" = "repo-create --encryption aes256-ocb --key-location repokey " ]
}

@test "borg 2: the encrypted modes name cipher and key location" {
  while read -r mode cipher location; do
    BORG_VERSION=2 BORG_ENCRYPTION="$mode" run "$BIN/borg-init"
    [ "$status" -eq 0 ] || fail "$mode: $output"
    [ "$(argv_joined)" = "repo-create --encryption $cipher --key-location $location " ] \
      || fail "$mode: $(argv_joined)"
  done <<'MODES'
repokey-aes-ocb aes256-ocb repokey
repokey-chacha20-poly1305 chacha20-poly1305 repokey
keyfile-aes-ocb aes256-ocb keyfile
keyfile-chacha20-poly1305 chacha20-poly1305 keyfile
MODES
}

@test "borg 2: authenticated becomes authenticated-sha256" {
  BORG_VERSION=2 BORG_ENCRYPTION=authenticated run "$BIN/borg-init"
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(argv_joined)" = "repo-create --encryption authenticated-sha256 " ]
}

@test "borg 2: the full names of the authenticated modes pass as they are" {
  for mode in authenticated-sha256 authenticated-blake3; do
    BORG_VERSION=2 BORG_ENCRYPTION="$mode" run "$BIN/borg-init"
    [ "$status" -eq 0 ] || fail "$mode: $output"
    [ "$(argv_joined)" = "repo-create --encryption $mode " ] || fail "$mode: $(argv_joined)"
  done
}

@test "borg 2: none is refused before Borg runs, and the message names the way out" {
  rm -f "$TMP/argv"
  BORG_VERSION=2 BORG_ENCRYPTION=none run "$BIN/borg-init"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BORG_ENCRYPTION=none"* ]] || fail "$output"
  [[ "$output" == *"authenticated"* ]] || fail "$output"
  [ ! -f "$TMP/argv" ] || fail "Borg ran: $(argv_joined)"
}

@test "borg 2: an unknown mode is refused before Borg runs" {
  rm -f "$TMP/argv"
  for mode in repokey-blake2 none-sha256 something; do
    BORG_VERSION=2 BORG_ENCRYPTION="$mode" run "$BIN/borg-init"
    [ "$status" -eq 1 ] || fail "$mode: status $status"
    [[ "$output" == *"is not a Borg 2 mode"* ]] || fail "$mode: $output"
  done
  [ ! -f "$TMP/argv" ] || fail "Borg ran: $(argv_joined)"
}

@test "borg 1: BORG_ENCRYPTION passes as it is, none and authenticated included" {
  for mode in repokey-blake2 authenticated none; do
    BORG_VERSION=1 BORG_ENCRYPTION="$mode" run "$BIN/borg-init"
    [ "$status" -eq 0 ] || fail "$mode: $output"
    [ "$(argv_joined)" = "init --encryption=$mode " ] || fail "$mode: $(argv_joined)"
  done
}

@test "borg 1: BORG_REMOTE_PATH still becomes --remote-path" {
  BORG_VERSION=1 BORG_REMOTE_PATH=borg-1.4 run "$BIN/borg-init"
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(argv_line 1)" = "--remote-path=borg-1.4" ]
}

@test "borg 2: a rest:// repository is refused on 2.0.0b25, and borg-init says why" {
  make_fake_borg2 2.0.0b25
  BORG_VERSION=2 BORG_REPO=rest://user@host/cluster/node run "$BIN/borg-init"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ssh://"* ]] || fail "$output"
  [[ "$output" != *"has been created"* ]] || fail "$output"
  ! borg_ran || fail "Borg ran: $(argv_joined)"
}
