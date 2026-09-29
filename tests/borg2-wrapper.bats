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

# --- --remote-path ------------------------------------------------------------

@test "borg2: BORG_REMOTE_PATH adds no --remote-path, Borg 2 reads the variable" {
  # Borg 2 dropped the option in 2.0.0b22 and exits 2 on it.
  make_fake_borg2 2.0.0b25
  BORG_REMOTE_PATH=borg2 run "$BIN/borg2" repo-list
  [ "$status" -eq 0 ]
  [ "$(argv_joined)" = "repo-list " ]
  [ "$(cat "$TMP/remote-path")" = "borg2" ]
}

@test "borg2: the same through the gateway with BORG_VERSION=2" {
  make_fake_borg2 2.0.0b25
  BORG_VERSION=2 BORG_REMOTE_PATH=borg2 run "$BIN/borg" repo-list
  [ "$status" -eq 0 ]
  [ "$(argv_joined)" = "repo-list " ]
  [ "$(cat "$TMP/remote-path")" = "borg2" ]
}

# --- rest:// ------------------------------------------------------------------

# refused ARGS… — the call ends non-zero, says why on stderr, names ssh://, and
# Borg was not started for it.
refused() {
  run --separate-stderr "$@"
  [ "$status" -ne 0 ] || fail "exit 0"
  [[ "$stderr" == *"rest://"*"2.0.0b25"* ]] || fail "stderr: $stderr"
  [[ "$stderr" == *"ssh://"* ]] || fail "stderr does not name ssh://: $stderr"
  [ -z "$output" ] || fail "stdout: $output"
  ! borg_ran || fail "Borg ran: $(argv_joined)"
}

@test "rest: BORG_REPO=rest:// is refused on 2.0.0b25 before Borg runs" {
  make_fake_borg2 2.0.0b25
  BORG_REPO=rest://user@host/cluster/node refused "$BIN/borg2" repo-create --encryption aes256-ocb
}

@test "rest: refused through the gateway with BORG_VERSION=2" {
  make_fake_borg2 2.0.0b25
  BORG_VERSION=2 BORG_REPO=rest://user@host/cluster/node refused "$BIN/borg" create archive /data
}

@test "rest: refused on every later version" {
  for version in 2.0.0b26 2.0.0b100 2.0.0rc1 2.0.0 2.1.0; do
    make_fake_borg2 "$version"
    BORG_REPO=rest://user@host/repo refused "$BIN/borg2" repo-list
  done
}

@test "rest: the repository option is read in every spelling Borg accepts" {
  # Measured with 2.0.0b24 and 2.0.0b25: all of these name the repository.
  make_fake_borg2 2.0.0b25
  url=rest://user@host/repo
  refused "$BIN/borg2" -r $url repo-list
  refused "$BIN/borg2" -r$url repo-list
  refused "$BIN/borg2" -r=$url repo-list
  refused "$BIN/borg2" --repo $url repo-list
  refused "$BIN/borg2" --repo=$url repo-list
  refused "$BIN/borg2" -vr $url repo-list
  refused "$BIN/borg2" -vr$url repo-list
  refused "$BIN/borg2" --rep $url repo-list
  refused "$BIN/borg2" --rep=$url repo-list
  refused "$BIN/borg2" --r $url repo-list
  refused "$BIN/borg2" --r=$url repo-list
  refused "$BIN/borg2" repo-list -r $url
}

@test "rest: leading white space does not protect a URL" {
  # Borg 2.0.0b25 would create the directory " rest:".
  make_fake_borg2 2.0.0b25
  BORG_REPO=" rest://user@host/repo" refused "$BIN/borg2" repo-list
  refused "$BIN/borg2" -r " rest://user@host/repo" repo-list
  BORG_REPO="$(printf '\trest://user@host/repo')" refused "$BIN/borg2" repo-list
}

@test "rest: the other repository of a transfer is read as well" {
  make_fake_borg2 2.0.0b25
  BORG_REPO=ssh://user@host/repo refused "$BIN/borg2" transfer --other-repo rest://user@host/old
}

@test "rest: a repository in BORG2_DEFAULT_PARAMS is read as well" {
  make_fake_borg2 2.0.0b25
  BORG2_DEFAULT_PARAMS="-r rest://user@host/repo" refused "$BIN/borg2" repo-list
}

@test "rest: the scheme is matched in any case" {
  make_fake_borg2 2.0.0b25
  BORG_REPO=REST://user@host/repo refused "$BIN/borg2" repo-list
}

@test "rest: the repository of the command line replaces BORG_REPO" {
  for option in "-r ssh://user@host/repo" "-rssh://user@host/repo" "-r=ssh://user@host/repo" \
                "--repo ssh://user@host/repo" "--repo=ssh://user@host/repo" "--rep=ssh://user@host/repo"; do
    make_fake_borg2 2.0.0b25
    # shellcheck disable=SC2086
    BORG_REPO=rest://user@host/repo run "$BIN/borg2" $option repo-list
    [ "$status" -eq 0 ] || fail "$option: $output"
    borg_ran || fail "$option: Borg did not run"
  done
  make_fake_borg2 2.0.0b25
  BORG_REPO=ssh://user@host/repo refused "$BIN/borg2" -r rest://user@host/repo repo-list
}

@test "rest: an option without a value names no other repository" {
  make_fake_borg2 2.0.0b25
  BORG_REPO=rest://user@host/repo refused "$BIN/borg2" repo-list -r
}

@test "rest: a Borg 2 before 2.0.0b25 keeps its rest:// repositories" {
  for version in 2.0.0b22 2.0.0b24 2.0.0b24.dev3+g1234567; do
    make_fake_borg2 "$version"
    BORG_REPO=rest://user@host/repo run "$BIN/borg2" repo-list
    [ "$status" -eq 0 ] || fail "$version: $output"
    borg_ran || fail "$version: Borg did not run"
  done
}

@test "rest: a binary that is no Borg 2 before 2.0.0b25 is refused" {
  make_fake_borg2 "1.4.5"
  BORG_REPO=rest://user@host/repo refused "$BIN/borg2" repo-list
}

@test "rest: a version that cannot be read is refused, and the message says that" {
  make_fake_borg2 ""
  BORG_REPO=rest://user@host/repo run --separate-stderr "$BIN/borg2" repo-list
  [ "$status" -ne 0 ] || fail "exit 0"
  [[ "$stderr" == *"does not state its version"* ]] || fail "stderr: $stderr"
  [[ "$stderr" == *"rest://"* ]] || fail "stderr: $stderr"
  [ -z "$output" ] || fail "stdout: $output"
  ! borg_ran || fail "Borg ran: $(argv_joined)"
}

@test "rest: a binary that is missing is refused, with what the shell said" {
  BORG2_BINARY="$TMP/no-such-borg" BORG_REPO=rest://user@host/repo \
    run --separate-stderr "$BIN/borg2" repo-list
  [ "$status" -ne 0 ] || fail "exit 0"
  [[ "$stderr" == *"no-such-borg"* ]] || fail "stderr: $stderr"
  [[ "$stderr" == *"does not state its version"* ]] || fail "stderr: $stderr"
  [ -z "$output" ] || fail "stdout: $output"
}

@test "rest: the binary is asked for its version only for a rest:// URL" {
  make_fake_borg2 2.0.0b25
  for repo in ssh://user@host/repo sftp://user@host/repo file:///repo /repo/rest://x; do
    BORG_REPO="$repo" run "$BIN/borg2" repo-list
    [ "$status" -eq 0 ] || fail "$repo: $output"
  done
  run "$BIN/borg2" repo-list
  [ "$status" -eq 0 ]
  [ "$(probes)" -eq 0 ] || fail "asked $(probes) times"
}

@test "rest: the version and the help are printed whatever BORG_REPO says" {
  # The entrypoint and the agent ask for the version in a pod that may still
  # carry the old URL.
  make_fake_borg2 2.0.0b25
  for arg in --version -V --help -h; do
    BORG_REPO=rest://user@host/repo run "$BIN/borg2" "$arg"
    [ "$status" -eq 0 ] || fail "$arg: $output"
  done
}

@test "rest: what follows -- is a path, not an option" {
  make_fake_borg2 2.0.0b25
  BORG_REPO=rest://user@host/repo refused "$BIN/borg2" create archive -- --version
  make_fake_borg2 2.0.0b25
  BORG_REPO=ssh://user@host/repo run "$BIN/borg2" create archive -- -r rest://a/path
  [ "$status" -eq 0 ]
}
