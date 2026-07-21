#!/usr/bin/env bats
#
# The full repository lifecycle against a real Borg repository in the container:
# init -> backup -> list/info -> mount -> delete. Runs once per Borg major
# (BORG_TEST_VERSION), which is what makes the borg1/borg2 subcommand mapping
# — init/repo-create, list/repo-list, info/repo-info, delete/repo-delete, and
# the REPO::ARCHIVE syntax borg2 dropped — an assertion rather than a comment.

bats_require_minimum_version 1.5.0

setup() {
  load helpers/repo
  e2e_setup
}

teardown() { e2e_teardown; }

# --- borg-init ----------------------------------------------------------------

@test "borg-init creates the repository" {
  run borg-init
  [ "$status" -eq 0 ]
  [[ "$output" == *"has been created"* ]]
  run borg-info
  [ "$status" -eq 0 ]
}

@test "borg-init is idempotent" {
  borg-init
  run borg-init
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "borg-init reports a real failure as rc 1" {
  # An unwritable parent is a genuine access failure, not an existing repo, so
  # the script must not swallow it — callers rely on rc 0 meaning "usable repo".
  if [ "$BORG_VERSION" = "2" ]; then
    BORG_REPO="file:///proc/nope/repo" run borg-init
  else
    BORG_REPO="/proc/nope/repo" run borg-init
  fi
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot be accessed"* ]]
}

# --- borg-backup --------------------------------------------------------------

@test "borg-backup creates an archive end to end" {
  run borg-backup
  [ "$status" -eq 0 ]
  [ "$(archive_count)" -eq 1 ]
}

@test "borg-backup initialises the repository on first run" {
  # No borg-init beforehand: the script owns that itself.
  [ ! -e "$TMP/repo" ]
  run borg-backup
  [ "$status" -eq 0 ]
  [ -d "$TMP/repo" ]
}

@test "borg-backup names the archive after the node" {
  borg-backup
  [[ "$(first_archive)" == "$NODE_NAME"-* ]]
}

@test "borg-backup expands the archive name template, leaving no braces" {
  borg-backup
  # A literal "{now:...}" in the archive name means the template was stored
  # unexpanded — archives then collide and browsing breaks.
  [[ "$(first_archive)" != *"{"* ]]
}

@test "borg-backup honours BORG_ARCHIVE_NAME_TEMPLATE" {
  BORG_ARCHIVE_NAME_TEMPLATE="custom-{now:%Y}" run borg-backup
  [ "$status" -eq 0 ]
  [[ "$(first_archive)" == custom-2* ]]
}

@test "borg-backup archives the source contents" {
  borg-backup
  run borg list "$(archive_ref "$(first_archive)")"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello.txt"* ]]
  [[ "$output" == *"nested/deep.txt"* ]]
}

@test "borg-backup twice yields two archives" {
  borg-backup
  borg-backup
  [ "$(archive_count)" -eq 2 ]
}

@test "borg-backup skips cleanly when no source roots are configured" {
  write_patterns   # comment only, no "R <path>"
  run borg-backup
  [ "$status" -eq 0 ]
  [[ "$output" == *"No source roots"* ]]
  [ ! -e "$TMP/repo" ]
}

@test "borg-backup in node mode reads the node pattern files" {
  BORG_MODE=node write_patterns "R $SRC"
  BORG_MODE=node run borg-backup
  [ "$status" -eq 0 ]
  [ "$(archive_count)" -eq 1 ]
}

@test "borg-backup passes extra arguments through to borg create" {
  run borg-backup --comment "e2e marker"
  [ "$status" -eq 0 ]
  run borg info "$(archive_ref "$(first_archive)")"
  [[ "$output" == *"e2e marker"* ]]
}

# --- borg-list / borg-info / borg-break-lock ----------------------------------

@test "borg-list lists archives at repository level" {
  borg-backup
  run borg-list
  [ "$status" -eq 0 ]
  [[ "$output" == *"$NODE_NAME"* ]]
}

@test "borg-info reports the repository, not a single archive" {
  borg-init
  run borg-info
  [ "$status" -eq 0 ]
  [[ "$output" == *"Repository ID"* ]]
}

@test "borg-break-lock succeeds on an unlocked repository" {
  borg-init
  run borg-break-lock
  [ "$status" -eq 0 ]
}

# --- borg-mount ---------------------------------------------------------------

@test "borg-mount makes the archived files readable" {
  borg-backup
  run borg-mount "$(first_archive)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"successfully mounted"* ]]
  mountpoint -q /mnt/borg || fail "/mnt/borg is not a mountpoint"
  # The archive stores absolute paths, so the source tree reappears under the
  # mountpoint at its original location.
  run cat "$(mounted_path "$SRC/hello.txt")"
  [ "$output" = "hello from the e2e suite" ]
}

@test "borg-mount without an archive name prints usage and fails" {
  run borg-mount
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

# --- borg-delete --------------------------------------------------------------

@test "borg-delete removes the whole repository" {
  borg-backup
  [ -d "$TMP/repo" ]
  BORG_DELETE_I_KNOW_WHAT_I_AM_DOING=YES run borg-delete
  [ "$status" -eq 0 ]
  [ ! -d "$TMP/repo" ]
}
