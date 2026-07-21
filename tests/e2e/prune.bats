#!/usr/bin/env bats
#
# borg-prune against a real repository. borg-backup runs prune+compact itself,
# so this covers the standalone script and, more importantly, that the two exit
# codes are combined with borg precedence on real borg output rather than only
# in the unit test's synthetic cases.

bats_require_minimum_version 1.5.0

setup() {
  load helpers/repo
  e2e_setup
}

teardown() { e2e_teardown; }

@test "borg-prune succeeds on a fresh repository" {
  borg-backup
  run borg-prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pruning repository"* ]]
  [[ "$output" == *"Compacting repository"* ]]
}

@test "borg-prune keeps the archive inside the 24H window" {
  borg-backup
  borg-prune
  # --keep-within 24H is hardcoded, so a just-created archive always survives.
  [ "$(archive_count)" -eq 1 ]
}

@test "borg-prune honours the KEEP_* environment overrides" {
  borg-backup
  KEEP_DAILY=1 KEEP_WEEKLY=1 KEEP_MONTHLY=1 run borg-prune
  [ "$status" -eq 0 ]
  [ "$(archive_count)" -eq 1 ]
}

@test "borg-prune fails when the repository does not exist" {
  # No init: prune and compact both hit a missing repo. The combined exit code
  # must be the error, not a warning that a caller would treat as success.
  run borg-prune
  [ "$status" -ne 0 ]
  ! borg_rc_is_warning "$status"
}

@test "borg-backup runs prune and compact as part of a backup" {
  run borg-backup
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pruning repository"* ]]
  [[ "$output" == *"Compacting repository"* ]]
}
