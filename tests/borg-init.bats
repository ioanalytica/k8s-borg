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

@test "borg 2: authenticated-sha256 passes as it is" {
  BORG_VERSION=2 BORG_ENCRYPTION=authenticated-sha256 run "$BIN/borg-init"
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(argv_joined)" = "repo-create --encryption authenticated-sha256 " ]
}

@test "borg 2: authenticated-blake3 is refused before Borg runs, Borg UI has no name for it" {
  rm -f "$TMP/argv"
  BORG_VERSION=2 BORG_ENCRYPTION=authenticated-blake3 run "$BIN/borg-init"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BORG_ENCRYPTION=authenticated-blake3"*"Borg UI"*"'authenticated'"* ]] || fail "$output"
  [ ! -f "$TMP/argv" ] || fail "Borg ran: $(argv_joined)"
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

# --- what a failure is blamed on ----------------------------------------------
#
# Borg exits 2 both when argparse rejects the command line and when the
# repository cannot be reached, so borg-init tells them apart by the output. The
# texts below are what Borg 1.4.5 and Borg 2.0.0b25 print in these cases
# (usage lines shortened); tests/e2e/clients.bats has the same cases against the
# real binaries.

# blamed_on VERSION OUTPUT — run borg-init against a stub that fails with exit
# code 2 and OUTPUT on stderr; print "command" or "repository".
blamed_on() {
  make_fake_borg 2 "" "$2"
  BORG_VERSION="$1" run "$BIN/borg-init"
  [ "$status" -eq 1 ] || { echo "status $status"; return; }
  [[ "$output" == *"$2"* ]] || { echo "Borg's own message is missing"; return; }
  if [[ "$output" == *"rejected the repo-creation command"* ]]; then
    [[ "$output" != *"cannot be accessed"* ]] && echo command && return
  elif [[ "$output" == *"Repository cannot be accessed!" ]]; then
    echo repository && return
  fi
  echo "neither: $output"
}

B1_USAGE='usage: borg [-V] [-h] [--critical] [--error] [--warning] [--info] [--debug]
            [--debug-profile FILE] [--rsh RSH]
            <command> ...'
B2_USAGE='usage: borg [options] repo-create [-h] [--critical] [--error] [--warning]
                                  [--key-location LOCATION] [-C COMPRESSION]
                                  [--chunker-params PARAMS] [--copy-crypt-key]
tip: For details of accepted options run: borg repo-create --help'
B2_ACCESS='Error: Could not access the repository via borg serve on the remote host: stdio server exited with code'
B2_HINT='Is borg 2 installed there (see BORG_REMOTE_PATH)? For a borg 1.x repository, use --from-borg1.'

@test "borg 1: a command line argparse rejects is blamed on borg-init" {
  [ "$(blamed_on 1 "$B1_USAGE
borg: error: unrecognized arguments: --bogus")" = command ]
  [ "$(blamed_on 1 "${B1_USAGE/borg \[-V\]/borg init}
borg init: error: argument -e/--encryption: invalid choice: 'bogus' (choose from none, keyfile, repokey, authenticated, keyfile-blake2, repokey-blake2, authenticated-blake2)")" = command ]
}

@test "borg 2: a command line argparse rejects is blamed on borg-init" {
  [ "$(blamed_on 2 "$B2_USAGE
error: unrecognized arguments: --bogus")" = command ]
  [ "$(blamed_on 2 "$B2_USAGE
error: argument -e/--encryption: invalid choice: 'none-sha256' (choose from aes256-ocb, chacha20-poly1305, authenticated-sha256, authenticated-blake3)")" = command ]
}

@test "borg 1: a repository Borg cannot reach is not blamed on borg-init" {
  local out
  for out in \
    'The parent path of the repo directory [/srv/nope/repo] does not exist.' \
    'Remote: user@host: Permission denied (publickey).
Connection closed by remote host. Is borg working on the server?' \
    'Repository path not allowed: /srv/other/repo' \
    'Remote: ssh: connect to host host port 22: Connection refused
Connection closed by remote host. Is borg working on the server?'
  do
    [ "$(blamed_on 1 "$out")" = repository ] || fail "$out: $(blamed_on 1 "$out")"
  done
}

@test "borg 2: a repository Borg cannot reach is not blamed on borg-init" {
  local out
  for out in \
    "$B2_ACCESS 255:
user@host: Permission denied (publickey).
$B2_HINT" \
    "$B2_ACCESS 83:
Repository path not allowed: /srv/other/repo.
$B2_HINT" \
    "$B2_ACCESS 255:
ssh: connect to host host port 22: Connection refused
$B2_HINT"
  do
    [ "$(blamed_on 2 "$out")" = repository ] || fail "$out: $(blamed_on 2 "$out")"
  done
}

@test "borg 2: the remote side's own usage error is not blamed on borg-init" {
  # A remote that runs Borg 1 rejects Borg 2's serve request with argparse's
  # text, and Borg 2 quotes the end of it behind its own error line.
  out="$B2_ACCESS 2:
                  [--restrict-to-repository PATH] [--append-only]
                  [--storage-quota QUOTA]
borg serve: error: ambiguous option: --rest could match --restrict-to-path, --restrict-to-repository
$B2_HINT"
  [ "$(blamed_on 2 "$out")" = repository ] || fail "$(blamed_on 2 "$out")"
  # The same with the usage line inside the quoted part.
  out="$B2_ACCESS 2:
usage: borg serve [-h] [--critical] [--error] [--warning] [--info] [--debug]
borg serve: error: ambiguous option: --rest could match --restrict-to-path, --restrict-to-repository
$B2_HINT"
  [ "$(blamed_on 2 "$out")" = repository ] || fail "$(blamed_on 2 "$out")"
}
