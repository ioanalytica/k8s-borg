#!/usr/bin/env bats
#
# What the clients say to Borg, against a repository on the container's own
# filesystem and against one on the repository server. The suite runs once per
# Borg major; where the two differ, or where Borg 2 changed with 2.0.0b25, the
# test says which behaviour belongs to which.
#
# The remote end matters: a local repository needs neither a URL scheme nor a
# remote path, so tests on it alone pass while both are wrong.

bats_require_minimum_version 1.5.0

setup_file() {
  load helpers/repo-server
  repo_server_setup
}

teardown_file() {
  load helpers/repo-server
  stop_server
}

setup() {
  load helpers/repo
  load helpers/repo-server
  e2e_setup
  unset BORG_RSH BORGSTORE_RSH BORG_REMOTE_PATH BORG_ENCRYPTION
  export BORG_DELETE_I_KNOW_WHAT_I_AM_DOING=YES
  LOCAL_BASE="${BORG_REPO%/repo}"
  REMOTE_DIR="cluster-a/clients-$BATS_TEST_NUMBER"
  # A working directory of its own: a repository that ends up next to the
  # caller instead of on the server is found there.
  WORK="$TMP/cwd"
  mkdir -p "$WORK"
  cd "$WORK"
}

teardown() {
  if [ -z "${BATS_TEST_COMPLETED:-}" ]; then
    echo "--- server log ---" >&2
    tail -40 /tmp/repo-server.log >&2
  fi
  cd /
  e2e_teardown
}

# on KIND [NAME] — the following calls use a local or a remote repository.
on() {
  case "$1" in
    local) export BORG_REPO="$LOCAL_BASE/${2:-repo}" ;;
    remote) BORG_REPO="$(repo_url "$REMOTE_DIR-${2:-repo}")" && export BORG_REPO ;;
    *) fail "on: $1" ;;
  esac
}

# exists KIND [NAME] — succeed iff that repository has a directory.
exists() {
  case "$1" in
    local) [ -e "$TMP/${2:-repo}" ] ;;
    remote) [ -e "$DATA/$REMOTE_DIR-${2:-repo}" ] ;;
  esac
}

# before_b25 — succeed iff the calls go to Borg 1 or to a Borg 2 before 2.0.0b25.
before_b25() { [ "$BORG_VERSION" = "1" ] || [ "$(borg2_beta)" -lt 25 ]; }

# nothing_left — the working directory is as empty as the test found it.
nothing_left() { [ -z "$(ls -A "$WORK")" ] || fail "left behind: $(find "$WORK" -mindepth 1 | head -5)"; }

# --- rest:// ------------------------------------------------------------------

@test "a rest:// repository is refused from 2.0.0b25 on, and no directory is left behind" {
  [ "$BORG_VERSION" = "2" ] || skip "rest:// was a Borg 2 scheme"
  [ "$(borg2_beta)" -ge 25 ] || skip "this Borg 2 still speaks rest://"
  export BORG_REPO="rest://$SERVER:$PORT/$REMOTE_DIR-rest"
  for script in borg-init borg-backup borg-prune borg-list borg-info borg-break-lock borg-delete; do
    run "$script"
    [ "$status" -ne 0 ] || fail "$script: exit 0: $output"
    [[ "$output" == *"rest://"*"ssh://"* ]] || fail "$script does not name the reason: $output"
    nothing_left
  done
  run borg-init
  [[ "$output" != *"has been created"* ]] || fail "$output"
  ! exists remote rest || fail "created on the server"
  [ -z "$(find / -xdev -type d -name 'rest:' 2>/dev/null | head -1)" ] \
    || fail "a directory named rest: exists: $(find / -xdev -type d -name 'rest:' | head -3)"
}

@test "a Borg 2 before 2.0.0b25 keeps its rest:// repositories" {
  [ "$BORG_VERSION" = "2" ] || skip "rest:// was a Borg 2 scheme"
  [ "$(borg2_beta)" -lt 25 ] || skip "2.0.0b25 and later have no rest://"
  export BORG_REPO="rest://$SERVER:$PORT/$REMOTE_DIR-rest"
  run borg-init
  [ "$status" -eq 0 ] || fail "$output"
  run borg-backup
  [ "$status" -eq 0 ] || fail "$output"
  exists remote rest || fail "not on the server"
  nothing_left
}

@test "the version is printed whatever the repository URL says" {
  BORG_REPO="rest://$SERVER:$PORT/$REMOTE_DIR-rest" run borg --version
  [ "$status" -eq 0 ] || fail "$output"
}

# --- the remote path ----------------------------------------------------------

@test "with BORG_REMOTE_PATH set every script works" {
  # The repository server takes any name for Borg: what it runs is fixed.
  export BORG_REMOTE_PATH=borg-custom
  for kind in local remote; do
    on "$kind"
    for script in borg-init borg-backup borg-list borg-info borg-prune borg-break-lock; do
      run "$script"
      [ "$status" -eq 0 ] || fail "$kind: $script: $output"
    done
    [ "$(archive_count)" -eq 1 ] || fail "$kind: $(archive_count) archives"
    exists "$kind" || fail "$kind: no repository"
    run borg-delete
    [ "$status" -eq 0 ] || fail "$kind: borg-delete: $output"
    ! exists "$kind" || fail "$kind: the repository is still there"
    nothing_left
  done
}

# --- encryption modes ---------------------------------------------------------

@test "borg-init creates a repository for every mode, and the scripts work on it" {
  if [ "$BORG_VERSION" = "2" ]; then
    modes="repokey-aes-ocb repokey-chacha20-poly1305 keyfile-aes-ocb keyfile-chacha20-poly1305 authenticated"
  else
    modes="repokey-blake2 keyfile-blake2 authenticated none"
  fi
  for kind in local remote; do
    for mode in $modes; do
      on "$kind" "$mode"
      export BORG_ENCRYPTION="$mode"
      run borg-init
      [ "$status" -eq 0 ] || fail "$kind, $mode: borg-init: $output"
      [[ "$output" == *"has been created"* ]] || fail "$kind, $mode: $output"
      exists "$kind" "$mode" || fail "$kind, $mode: no repository"
      for script in borg-backup borg-prune borg-list borg-info; do
        run "$script"
        [ "$status" -eq 0 ] || fail "$kind, $mode: $script: $output"
      done
      [ "$(archive_count)" -eq 1 ] || fail "$kind, $mode: $(archive_count) archives"
    done
  done
  nothing_left
}

@test "BORG_ENCRYPTION=authenticated is authenticated-sha256 in Borg 2" {
  [ "$BORG_VERSION" = "2" ] || skip "Borg 1 has one authenticated mode"
  export BORG_ENCRYPTION=authenticated
  for kind in local remote; do
    on "$kind"
    borg-init
    run borg-info
    [ "$status" -eq 0 ] || fail "$kind: $output"
    [[ "$output" == *"authenticated-sha256"* ]] || fail "$kind: $output"
  done
}

@test "BORG_ENCRYPTION=none is refused for Borg 2, and nothing is created" {
  [ "$BORG_VERSION" = "2" ] || skip "Borg 1 has repositories without a key"
  export BORG_ENCRYPTION=none
  for kind in local remote; do
    on "$kind"
    for script in borg-init borg-backup; do
      run "$script"
      [ "$status" -ne 0 ] || fail "$kind: $script: exit 0: $output"
      [[ "$output" == *"BORG_ENCRYPTION=none"*"authenticated"* ]] || fail "$kind: $script: $output"
      ! exists "$kind" || fail "$kind: $script created a repository"
    done
  done
  nothing_left
}

@test "BORG_ENCRYPTION=authenticated-blake3 is refused for Borg 2, and nothing is created" {
  # Borg UI has no name for the mode, so the repository could not be recorded.
  [ "$BORG_VERSION" = "2" ] || skip "a Borg 2 mode"
  export BORG_ENCRYPTION=authenticated-blake3
  for kind in local remote; do
    on "$kind"
    run borg-init
    [ "$status" -eq 1 ] || fail "$kind: status $status: $output"
    [[ "$output" == *"BORG_ENCRYPTION=authenticated-blake3"*"'authenticated'"* ]] || fail "$kind: $output"
    ! exists "$kind" || fail "$kind: created"
  done
  nothing_left
}

# --- what a failed borg-init is blamed on -------------------------------------
#
# Borg exits 2 both when it rejects the command line and when it cannot reach
# the repository; borg-init tells the two apart by Borg's output.

# blamed_on_repository — the last `run borg-init` failed, kept Borg's message
# and closed with the repository, not with borg-init.
blamed_on_repository() {
  [ "$status" -eq 1 ] || fail "status $status: $output"
  [[ "$output" == *"Repository cannot be accessed!" ]] || fail "$output"
  [[ "$output" != *"rejected the repo-creation command"* ]] || fail "$output"
}

@test "borg-init blames a command line Borg rejects on itself" {
  # The default parameters are the one way to put an option Borg does not
  # know onto borg-init's command line.
  for kind in local remote; do
    on "$kind"
    BORG1_DEFAULT_PARAMS=--no-such-option BORG2_DEFAULT_PARAMS=--no-such-option run borg-init
    [ "$status" -eq 1 ] || fail "$kind: status $status: $output"
    [[ "$output" == "usage: "* ]] || fail "$kind: $output"
    [[ "$output" == *"rejected the repo-creation command"* ]] || fail "$kind: $output"
    [[ "$output" != *"cannot be accessed"* ]] || fail "$kind: $output"
    ! exists "$kind" || fail "$kind: created"
  done
  nothing_left
}

@test "borg-init blames a refused path on the repository" {
  BORG_REPO="$(repo_url other/repo)" run borg-init
  blamed_on_repository
  [[ "$output" == *"Repository path not allowed"* ]] || fail "$output"
  [ ! -e "$DATA/other" ]
}

@test "borg-init blames a key the server does not know on the repository" {
  on remote
  with_key stranger
  run borg-init
  blamed_on_repository
  [[ "$output" == *"Permission denied (publickey)"* ]] || fail "$output"
  ! exists remote || fail "created"
}

@test "borg-init blames a host that does not answer on the repository" {
  # Nothing listens on port 1. Borg 2 takes the port from the remote shell
  # command once one is set, so it goes into both.
  on remote
  BORG_REPO="${BORG_REPO/:$PORT\//:1/}"
  export BORG_RSH="ssh -p 1" BORGSTORE_RSH="ssh -p 1"
  run borg-init
  blamed_on_repository
  [[ "$output" == *"Connection refused"* ]] || fail "$output"
}

# --- the passphrase -----------------------------------------------------------

@test "break-lock and delete work with the passphrase the pods carry" {
  for kind in local remote; do
    on "$kind"
    borg-init
    run borg-break-lock
    [ "$status" -eq 0 ] || fail "$kind: borg-break-lock: $output"
    run borg-delete --force
    [ "$status" -eq 0 ] || fail "$kind: borg-delete: $output"
    ! exists "$kind" || fail "$kind: the repository is still there"
  done
  nothing_left
}

@test "without the passphrase break-lock and delete fail from 2.0.0b25 on" {
  for kind in local remote; do
    on "$kind"
    borg-init
    for script in borg-break-lock "borg-delete --force"; do
      # shellcheck disable=SC2086
      run env -u BORG_PASSPHRASE $script
      if before_b25; then
        [ "$status" -eq 0 ] || fail "$kind: $script: $output"
      else
        [ "$status" -ne 0 ] || fail "$kind: $script worked without the passphrase"
        exists "$kind" || fail "$kind: $script removed the repository"
      fi
    done
  done
}

# --- borg-mount ---------------------------------------------------------------

@test "borg-mount makes the files of a remote repository readable" {
  on remote
  borg-backup
  run borg-mount "$(first_archive)"
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"successfully mounted"* ]] || fail "$output"
  mountpoint -q /mnt/borg || fail "/mnt/borg is not a mountpoint"
  run cat "$(mounted_path "$SRC/hello.txt")"
  [ "$output" = "hello from the e2e suite" ] || fail "$output"
}

@test "borg-mount fails with Borg's exit code when the repository cannot be mounted" {
  for kind in local remote; do
    on "$kind" does-not-exist
    run borg-mount some-archive
    [ "$status" -ne 0 ] || fail "$kind: exit 0: $output"
    [[ "$output" == *"failed"* ]] || fail "$kind: $output"
    [[ "$output" != *"successfully mounted"* ]] || fail "$kind: $output"
    ! mountpoint -q /mnt/borg || fail "$kind: /mnt/borg is a mountpoint"
  done
  nothing_left
}
