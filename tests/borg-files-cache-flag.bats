#!/usr/bin/env bats
#
# borg-files-cache-flag gates the "mtime,size" files-cache mode on S3 being
# enabled AND a bucket actually mounted. Getting the gate wrong is expensive in
# both directions: too loose weakens change detection on a normal filesystem
# (where inodes are stable), too strict re-downloads the whole bucket every run.
#
# The positive case needs a real fuse.s3fs entry in /proc/mounts and is covered
# by the image smoke test, not here.

setup() {
  load helpers/common
  common_setup
}

teardown() { common_teardown; }

@test "files-cache: prints nothing when S3 is disabled" {
  run "$BIN/borg-files-cache-flag"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "files-cache: prints nothing when S3_ENABLED is explicitly false" {
  S3_ENABLED=false run "$BIN/borg-files-cache-flag"
  [ -z "$output" ]
}

@test "files-cache: S3 enabled but no bucket mounted prints nothing" {
  S3_ENABLED=true run "$BIN/borg-files-cache-flag"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
