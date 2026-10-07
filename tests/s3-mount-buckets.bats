#!/usr/bin/env bats
#
# `s3-mount-buckets`: which listed buckets get mounted at the start and what a
# bucket that cannot be mounted does under S3_ON_MOUNT_FAILURE (skip: warn and
# go on, stop only when none is mounted; fail: stop), and the same count with
# --check before a backup. s3-mount-bucket and mountpoint are stubs.

bats_require_minimum_version 1.5.0

setup() {
  load helpers/common
  common_setup
  mkdir -p "$TMP/stubs" "$TMP/s3"
  PATH="$TMP/stubs:$BIN:$PATH"
  export S3_MOUNTPOINT="$TMP/s3" STUB="$TMP"
  printf '%s\n' "# buckets" "" pg-backups media logs >"$TMP/buckets"
  # s3-mount-bucket fails for every bucket named in $TMP/broken and marks the
  # others mounted; mountpoint reads the marks.
  : >"$TMP/broken"
  cat >"$TMP/stubs/s3-mount-bucket" <<'EOF'
#!/usr/bin/env bash
echo "s3-mount-bucket $*" >>"$STUB/calls"
grep -qxF -- "$1" "$STUB/broken" && { echo "ERROR: S3 bucket '$1' did not answer" >&2; exit 1; }
echo "$1" >>"$STUB/mounted"
EOF
  cat >"$TMP/stubs/mountpoint" <<'EOF'
#!/usr/bin/env bash
grep -qxF -- "$(basename "$2")" "$STUB/mounted" 2>/dev/null
EOF
  chmod +x "$TMP/stubs/"*
}

teardown() { common_teardown; }

broken() { printf '%s\n' "$@" >"$TMP/broken"; }
mounted() { printf '%s\n' "$@" >"$TMP/mounted"; }
called() { grep -qxF -- "$1" "$TMP/calls" 2>/dev/null; }

@test "every listed bucket is mounted, comments and blank lines skipped" {
  run "$BIN/s3-mount-buckets" "$TMP/buckets"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(cat "$TMP/calls")" = "s3-mount-bucket pg-backups
s3-mount-bucket media
s3-mount-bucket logs" ] || fail "$(cat "$TMP/calls")"
}

@test "skip: one bucket that cannot be mounted is skipped with a warning, the rest is mounted" {
  broken media
  run --separate-stderr "$BIN/s3-mount-buckets" "$TMP/buckets"
  [ "$status" -eq 1 ] || fail "status $status: $stderr"
  called "s3-mount-bucket logs" || fail "stopped at the failing bucket: $(cat "$TMP/calls")"
  [[ $stderr == *"ERROR: S3 bucket 'media' did not answer"* ]] || fail "$stderr"
  [[ $stderr == *"WARNING: S3 bucket 'media' is skipped and not backed up (s3.onMountFailure=skip)"* ]] || fail "$stderr"
  [[ $stderr == *"WARNING: 1 of 3 listed S3 buckets are not mounted and not backed up: media"* ]] || fail "$stderr"
}

@test "skip: no bucket mounted stops the start" {
  broken pg-backups media logs
  run --separate-stderr "$BIN/s3-mount-buckets" "$TMP/buckets"
  [ "$status" -eq 2 ] || fail "status $status: $stderr"
  [[ $stderr == *"ERROR: none of the 3 listed S3 buckets is mounted (pg-backups media logs); check s3.endpoint, s3.region and the credentials"* ]] \
    || fail "$stderr"
}

@test "skip is the default" {
  broken media
  unset S3_ON_MOUNT_FAILURE
  run "$BIN/s3-mount-buckets" "$TMP/buckets"
  [ "$status" -eq 1 ] || fail "status $status: $output"
}

@test "fail: the first bucket that cannot be mounted stops the start" {
  broken media
  S3_ON_MOUNT_FAILURE=fail run --separate-stderr "$BIN/s3-mount-buckets" "$TMP/buckets"
  [ "$status" -eq 2 ] || fail "status $status: $stderr"
  [[ $stderr == *"ERROR: S3 bucket 'media' cannot be mounted (s3.onMountFailure=fail)"* ]] || fail "$stderr"
  ! called "s3-mount-bucket logs" || fail "went on after the failing bucket"
}

@test "a bucket file without buckets passes without mounting" {
  echo "# No S3 buckets configured (cluster.s3Buckets)." >"$TMP/buckets"
  run "$BIN/s3-mount-buckets" "$TMP/buckets"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ ! -f "$TMP/calls" ] || fail "$(cat "$TMP/calls")"
}

@test "an unknown policy is refused before any mount" {
  S3_ON_MOUNT_FAILURE=ignore run --separate-stderr "$BIN/s3-mount-buckets" "$TMP/buckets"
  [ "$status" -eq 2 ] || fail "status $status"
  [[ $stderr == *"S3_ON_MOUNT_FAILURE must be skip or fail, got 'ignore'"* ]] || fail "$stderr"
  [ ! -f "$TMP/calls" ] || fail "mounted: $(cat "$TMP/calls")"
}

@test "--check: every listed bucket mounted passes" {
  mounted pg-backups media logs
  run "$BIN/s3-mount-buckets" --check "$TMP/buckets"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ ! -f "$TMP/calls" ] || fail "mounted: $(cat "$TMP/calls")"
}

@test "--check, skip: a bucket that is not mounted is a warning that names it, without a mount" {
  mounted pg-backups logs
  run --separate-stderr "$BIN/s3-mount-buckets" --check "$TMP/buckets"
  [ "$status" -eq 1 ] || fail "status $status: $stderr"
  [[ $stderr == *"WARNING: 1 of 3 listed S3 buckets are not mounted and not backed up: media"* ]] || fail "$stderr"
  [ ! -f "$TMP/calls" ] || fail "mounted: $(cat "$TMP/calls")"
}

@test "--check, skip: no bucket mounted is an error" {
  run --separate-stderr "$BIN/s3-mount-buckets" --check "$TMP/buckets"
  [ "$status" -eq 2 ] || fail "status $status: $stderr"
  [[ $stderr == *"none of the 3 listed S3 buckets is mounted"* ]] || fail "$stderr"
}

@test "--check, fail: a bucket that is not mounted is an error" {
  mounted pg-backups logs
  S3_ON_MOUNT_FAILURE=fail run --separate-stderr "$BIN/s3-mount-buckets" --check "$TMP/buckets"
  [ "$status" -eq 2 ] || fail "status $status: $stderr"
  [[ $stderr == *"ERROR: 1 of 3 listed S3 buckets are not mounted (s3.onMountFailure=fail): media"* ]] || fail "$stderr"
}
