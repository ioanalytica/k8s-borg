#!/usr/bin/env bats
#
# `s3-remount-buckets`: every listed bucket is unmounted and mounted again
# (a busy mount is detached lazily and its s3fs ended, a lost one is cleaned
# up first), a bucket that cannot be mounted again does not stop the others,
# and the verdict is that of `s3-mount-buckets --check` under
# S3_ON_MOUNT_FAILURE. mountpoint, umount, fusermount3, pkill and
# s3-mount-bucket are stubs; s3-mount-buckets is the real one.

bats_require_minimum_version 1.5.0

setup() {
  load helpers/common
  common_setup
  mkdir -p "$TMP/stubs" "$TMP/s3"
  PATH="$TMP/stubs:$BIN:$PATH"
  export S3_MOUNTPOINT="$TMP/s3" STUB="$TMP"
  printf '%s\n' "# buckets" "" pg-backups media logs >"$TMP/buckets"
  : >"$TMP/broken"; : >"$TMP/busy"; : >"$TMP/calls"
  printf '%s\n' pg-backups media logs >"$TMP/mounted"
  # The mount table is $TMP/mounted; a bucket in $TMP/busy cannot be unmounted
  # except lazily, one in $TMP/broken cannot be mounted.
  cat >"$TMP/stubs/mountpoint" <<'STUB'
#!/usr/bin/env bash
grep -qxF -- "$(basename "$2")" "$STUB/mounted"
STUB
  cat >"$TMP/stubs/umount" <<'STUB'
#!/usr/bin/env bash
echo "umount $*" >>"$STUB/calls"
lazy=false; [[ $1 == -l ]] && { lazy=true; shift; }
b="$(basename "$1")"
grep -qxF -- "$b" "$STUB/mounted" || exit 1
! $lazy && grep -qxF -- "$b" "$STUB/busy" && exit 1
grep -vxF -- "$b" "$STUB/mounted" >"$STUB/mounted.new"; mv "$STUB/mounted.new" "$STUB/mounted"
STUB
  cat >"$TMP/stubs/fusermount3" <<'STUB'
#!/usr/bin/env bash
echo "fusermount3 $*" >>"$STUB/calls"
exit 1
STUB
  cat >"$TMP/stubs/pkill" <<'STUB'
#!/usr/bin/env bash
echo "pkill $*" >>"$STUB/calls"
STUB
  cat >"$TMP/stubs/s3-mount-bucket" <<'STUB'
#!/usr/bin/env bash
echo "s3-mount-bucket $*" >>"$STUB/calls"
grep -qxF -- "$1" "$STUB/broken" && { echo "ERROR: S3 bucket '$1' did not answer" >&2; exit 1; }
echo "$1" >>"$STUB/mounted"
STUB
  chmod +x "$TMP/stubs/"*
}

teardown() { common_teardown; }

calls() { cat "$TMP/calls"; }

@test "every listed bucket is unmounted and mounted again, in order" {
  run "$BIN/s3-remount-buckets" "$TMP/buckets"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(calls)" = "umount $TMP/s3/pg-backups
s3-mount-bucket pg-backups
umount $TMP/s3/media
s3-mount-bucket media
umount $TMP/s3/logs
s3-mount-bucket logs" ] || fail "$(calls)"
  [ "$(sort "$TMP/mounted")" = "$(printf '%s\n' logs media pg-backups)" ] || fail "$(cat "$TMP/mounted")"
}

@test "a busy mount is detached lazily and its s3fs ended before the new mount" {
  echo media >"$TMP/busy"
  run --separate-stderr "$BIN/s3-remount-buckets" "$TMP/buckets"
  [ "$status" -eq 0 ] || fail "status $status: $stderr"
  [[ $stderr == *"media: $TMP/s3/media is busy, detaching it"* ]] || fail "$stderr"
  grep -A4 -xF "umount $TMP/s3/media" "$TMP/calls" | tr '\n' '|' \
    | grep -qxF "umount $TMP/s3/media|fusermount3 -u $TMP/s3/media|umount -l $TMP/s3/media|pkill -KILL -f ^s3fs media $TMP/s3/media( |\$)|s3-mount-bucket media|" \
    || fail "$(calls)"
}

@test "a bucket that is not mounted is cleaned up and mounted" {
  printf '%s\n' pg-backups logs >"$TMP/mounted"
  run "$BIN/s3-remount-buckets" "$TMP/buckets"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  grep -qxF "umount -l $TMP/s3/media" "$TMP/calls" || fail "$(calls)"
  grep -qxF "s3-mount-bucket media" "$TMP/calls" || fail "$(calls)"
}

@test "skip: a bucket that cannot be mounted again is a warning, the others are mounted" {
  echo media >"$TMP/broken"
  run --separate-stderr "$BIN/s3-remount-buckets" "$TMP/buckets"
  [ "$status" -eq 1 ] || fail "status $status: $stderr"
  grep -qxF "s3-mount-bucket logs" "$TMP/calls" || fail "stopped at the failing bucket: $(calls)"
  [[ $stderr == *"WARNING: 1 of 3 listed S3 buckets are not mounted and not backed up: media"* ]] || fail "$stderr"
}

@test "fail: the others are still mounted, the run fails" {
  echo media >"$TMP/broken"
  S3_ON_MOUNT_FAILURE=fail run --separate-stderr "$BIN/s3-remount-buckets" "$TMP/buckets"
  [ "$status" -eq 2 ] || fail "status $status: $stderr"
  grep -qxF "s3-mount-bucket logs" "$TMP/calls" || fail "stopped at the failing bucket: $(calls)"
  [[ $stderr == *"(s3.onMountFailure=fail): media"* ]] || fail "$stderr"
}

@test "no bucket can be mounted again: an error" {
  printf '%s\n' pg-backups media logs >"$TMP/broken"
  run --separate-stderr "$BIN/s3-remount-buckets" "$TMP/buckets"
  [ "$status" -eq 2 ] || fail "status $status: $stderr"
  [[ $stderr == *"none of the 3 listed S3 buckets is mounted"* ]] || fail "$stderr"
}

@test "without a bucket file it refuses" {
  run "$BIN/s3-remount-buckets" "$TMP/nope"
  [ "$status" -eq 2 ] || fail "status $status: $output"
  [ ! -s "$TMP/calls" ] || fail "$(calls)"
}
