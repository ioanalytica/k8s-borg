#!/usr/bin/env bats
#
# `s3-verify-listing`: a key the S3 API lists but the mount does not show is
# reported, the bucket is mounted again and checked once more, and only a bucket
# that still misses objects fails; a bucket that lost its mount is mounted again
# too, and one that cannot be is left to s3-mount-buckets under
# S3_ON_MOUNT_FAILURE=skip. rclone, mountpoint, umount and s3-mount-bucket are stubs (sort and comm
# can be made to fail); the mount is a plain directory. The real s3fs
# against a real server is covered by tests/e2e/s3fs.bats.

bats_require_minimum_version 1.5.0

setup() {
  load helpers/common
  common_setup
  mkdir -p "$TMP/stubs" "$TMP/s3/pg-backups"
  PATH="$TMP/stubs:$BIN:$PATH"
  export S3_ENDPOINT=http://s3.example:3900 S3_MOUNTPOINT="$TMP/s3" \
         AWS_KEY=key-id AWS_SECRET_KEY=very-secret STUB="$TMP"
  unset S3_REGION
  echo "pg-backups" >"$TMP/buckets"
  make_stubs
}

teardown() { common_teardown; }

# The rclone stub prints $TMP/api.N for its Nth call (falling back to $TMP/api),
# records its argv and environment, and fails when $TMP/api.fail exists.
# s3-mount-bucket copies $TMP/remount/ into the mount, as a new mount that
# shows more would, or fails when $TMP/mount.fail exists. sort and comm fail
# when $TMP/sort.fail or $TMP/comm.fail exists, as on a full disk.
make_stubs() {
  cat >"$TMP/stubs/rclone" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$STUB/rclone.calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$STUB/rclone.calls"
printf '%s\n' "$@" >"$STUB/rclone.argv"
env | grep '^RCLONE_' | sort >"$STUB/rclone.env"
[ -f "$STUB/api.fail" ] && { echo "connection refused" >&2; exit 1; }
if [ -f "$STUB/api.$n" ]; then cat "$STUB/api.$n"; else cat "$STUB/api"; fi
EOF
  cat >"$TMP/stubs/mountpoint" <<'EOF'
#!/usr/bin/env bash
[ ! -f "$STUB/unmounted" ]
EOF
  cat >"$TMP/stubs/umount" <<'EOF'
#!/usr/bin/env bash
echo "umount $*" >>"$STUB/calls"
EOF
  cat >"$TMP/stubs/s3-mount-bucket" <<'EOF'
#!/usr/bin/env bash
echo "s3-mount-bucket $*" >>"$STUB/calls"
[ -f "$STUB/mount.fail" ] && { echo "ERROR: S3 bucket '$1' cannot be listed" >&2; exit 1; }
rm -f "$STUB/unmounted"
[ -d "$STUB/remount" ] && cp -R "$STUB/remount/." "$S3_MOUNTPOINT/$1/"
exit 0
EOF
  local cmd
  for cmd in sort comm; do
    printf '#!/usr/bin/env bash\n[ -f "$STUB/%s.fail" ] && exit 2\nexec %s "$@"\n' "$cmd" "$(command -v "$cmd")" >"$TMP/stubs/$cmd"
  done
  chmod +x "$TMP/stubs/"*
}

# objects KEY… — what the S3 API lists (every call).
objects() { printf '%s\n' "$@" >"$TMP/api"; }
# shown KEY… — what the mount shows.
shown() {
  local k
  for k in "$@"; do mkdir -p "$(dirname "$TMP/s3/pg-backups/$k")"; : >"$TMP/s3/pg-backups/$k"; done
}
called() { grep -qxF -- "$1" "$TMP/calls" 2>/dev/null; }

@test "a mount that shows every object passes without mounting again" {
  objects db/a.sql.gz db/b.sql.gz top.txt
  shown   db/a.sql.gz db/b.sql.gz top.txt
  run "$BIN/s3-verify-listing" "$TMP/buckets"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [[ $output == *"pg-backups: 3 objects, all under $TMP/s3/pg-backups"* ]] || fail "$output"
  [ ! -f "$TMP/calls" ] || fail "mounted again: $(cat "$TMP/calls")"
}

@test "a missing object is reported and the bucket is mounted again" {
  objects db/a.sql.gz db/b.sql.gz db/c.sql.gz
  shown   db/a.sql.gz
  mkdir -p "$TMP/remount/db"
  : >"$TMP/remount/db/b.sql.gz"; : >"$TMP/remount/db/c.sql.gz"
  run --separate-stderr "$BIN/s3-verify-listing" "$TMP/buckets"
  [ "$status" -eq 0 ] || fail "status $status: $stderr"
  [[ $stderr == *"pg-backups: 2 of 3 objects missing under $TMP/s3/pg-backups"* ]] || fail "$stderr"
  [[ $stderr == *"    db/b.sql.gz"* && $stderr == *"    db/c.sql.gz"* ]] || fail "$stderr"
  called "umount $TMP/s3/pg-backups" || fail "not unmounted: $(cat "$TMP/calls")"
  called "s3-mount-bucket pg-backups" || fail "not mounted again: $(cat "$TMP/calls")"
  [[ $output == *"pg-backups: 3 objects, all under"* ]] || fail "$output"
}

@test "a bucket that still misses objects after the new mount fails" {
  objects db/a.sql.gz db/b.sql.gz
  shown   db/a.sql.gz
  run --separate-stderr "$BIN/s3-verify-listing" "$TMP/buckets"
  [ "$status" -eq 1 ] || fail "status $status"
  [ "$(grep -c '1 of 2 objects missing' <<<"$stderr")" -eq 2 ] || fail "$stderr"
  called "s3-mount-bucket pg-backups" || fail "not mounted again"
}

@test "the sample of missing keys is limited" {
  objects k1 k2 k3 k4 k5
  S3_VERIFY_SAMPLE=2 run --separate-stderr "$BIN/s3-verify-listing" "$TMP/buckets"
  [ "$status" -eq 1 ]
  [ "$(grep -c '^    k' <<<"$stderr")" -eq 4 ] || fail "$stderr"   # 2 per check, 2 checks
}

@test "objects created or deleted during the check do not count" {
  # Listed before the walk only (deleted meanwhile), and after it only (new).
  printf '%s\n' a deleted >"$TMP/api.1"
  printf '%s\n' a created >"$TMP/api.2"
  shown a
  run "$BIN/s3-verify-listing" "$TMP/buckets"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ ! -f "$TMP/calls" ] || fail "mounted again"
}

@test "files the mount shows beyond the listing do not count" {
  objects a
  shown a extra
  run "$BIN/s3-verify-listing" "$TMP/buckets"
  [ "$status" -eq 0 ] || fail "status $status: $output"
}

@test "_\$folder\$ directory markers are not expected as files" {
  objects 'db_$folder$' db/a.sql.gz
  shown db/a.sql.gz
  run "$BIN/s3-verify-listing" "$TMP/buckets"
  [ "$status" -eq 0 ] || fail "status $status: $output"
}

@test "an empty bucket passes" {
  : >"$TMP/api"
  run "$BIN/s3-verify-listing" "$TMP/buckets"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [[ $output == *"pg-backups: 0 objects"* ]] || fail "$output"
}

@test "a bucket that lost its mount is mounted again and checked" {
  objects a
  touch "$TMP/unmounted"
  mkdir -p "$TMP/remount"; : >"$TMP/remount/a"
  run --separate-stderr "$BIN/s3-verify-listing" "$TMP/buckets"
  [ "$status" -eq 0 ] || fail "status $status: $stderr"
  [[ $stderr == *"pg-backups: $TMP/s3/pg-backups is not mounted, mounting it again"* ]] || fail "$stderr"
  called "umount -l $TMP/s3/pg-backups" || fail "dead endpoint not detached: $(cat "$TMP/calls")"
  called "s3-mount-bucket pg-backups" || fail "not mounted again: $(cat "$TMP/calls")"
  [[ $output == *"pg-backups: 1 objects, all under"* ]] || fail "$output"
}

@test "a bucket that lost its mount and cannot be mounted again fails under fail" {
  objects a
  touch "$TMP/unmounted" "$TMP/mount.fail"
  S3_ON_MOUNT_FAILURE=fail run --separate-stderr "$BIN/s3-verify-listing" "$TMP/buckets"
  [ "$status" -eq 1 ] || fail "status $status: $stderr"
  [[ $stderr == *"pg-backups: cannot mount again"* ]] || fail "$stderr"
  [ ! -f "$TMP/rclone.calls" ] || fail "checked a bucket that is not mounted"
}

@test "a bucket that cannot be mounted is left to the mount check under skip" {
  printf '%s
' pg-backups other >"$TMP/buckets"
  mkdir -p "$TMP/s3/other"
  objects a
  touch "$TMP/unmounted" "$TMP/mount.fail"
  run --separate-stderr "$BIN/s3-verify-listing" "$TMP/buckets"
  [ "$status" -eq 0 ] || fail "status $status: $stderr"
  [[ $stderr == *"pg-backups: cannot mount again, not checked (s3.onMountFailure=skip)"* ]] || fail "$stderr"
  called "s3-mount-bucket other" || fail "stopped at the first bucket: $(cat "$TMP/calls")"
  [ ! -f "$TMP/rclone.calls" ] || fail "checked a bucket that is not mounted"
}

@test "a bucket that misses objects and cannot be mounted again fails under skip" {
  objects a b
  shown a
  touch "$TMP/mount.fail"
  run --separate-stderr "$BIN/s3-verify-listing" "$TMP/buckets"
  [ "$status" -eq 1 ] || fail "status $status: $stderr"
  [[ $stderr == *"pg-backups: 1 of 2 objects missing"* ]] || fail "$stderr"
  [[ $stderr == *"pg-backups: cannot mount again"* ]] || fail "$stderr"
  [[ $stderr != *"not checked (s3.onMountFailure=skip)"* ]] || fail "downgraded to the mount check: $stderr"
}

@test "a listing that cannot be written fails instead of passing as empty" {
  objects a
  touch "$TMP/sort.fail"
  run --separate-stderr "$BIN/s3-verify-listing" "$TMP/buckets"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  [[ $stderr == *"cannot write the listing of bucket 'pg-backups'"* ]] || fail "$stderr"
  [ ! -f "$TMP/calls" ] || fail "mounted again"
}

@test "a comparison that fails does not pass as complete" {
  objects a b
  shown a
  touch "$TMP/comm.fail"
  run --separate-stderr "$BIN/s3-verify-listing" "$TMP/buckets"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  [[ $stderr == *"cannot compare the listings of bucket 'pg-backups'"* ]] || fail "$stderr"
  [[ $output != *"all under"* ]] || fail "$output"
}

@test "comments and blank lines in the bucket file are skipped" {
  printf '%s\n' "# buckets" "" "pg-backups" >"$TMP/buckets"
  objects a
  shown a
  run "$BIN/s3-verify-listing" "$TMP/buckets"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(cat "$TMP/rclone.calls")" -eq 2 ] || fail "rclone called $(cat "$TMP/rclone.calls") times"
}

@test "an S3 API that cannot be listed fails without mounting again" {
  touch "$TMP/api.fail"
  run --separate-stderr "$BIN/s3-verify-listing" "$TMP/buckets"
  [ "$status" -eq 1 ]
  [[ $stderr == *"cannot list bucket 'pg-backups' through the S3 API: connection refused"* ]] || fail "$stderr"
  [ ! -f "$TMP/calls" ] || fail "mounted again"
}

@test "the credentials reach rclone through the environment, not the argv" {
  objects a
  shown a
  S3_REGION=eu-central-1 run "$BIN/s3-verify-listing" "$TMP/buckets"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  ! grep -q 'very-secret' "$TMP/rclone.argv" || fail "secret in argv: $(cat "$TMP/rclone.argv")"
  grep -qx 'RCLONE_S3_SECRET_ACCESS_KEY=very-secret' "$TMP/rclone.env" || fail "$(cat "$TMP/rclone.env")"
  grep -qx 'RCLONE_S3_ACCESS_KEY_ID=key-id' "$TMP/rclone.env" || fail "$(cat "$TMP/rclone.env")"
  grep -qx 'RCLONE_S3_ENDPOINT=http://s3.example:3900' "$TMP/rclone.env" || fail "$(cat "$TMP/rclone.env")"
  grep -qx 'RCLONE_S3_REGION=eu-central-1' "$TMP/rclone.env" || fail "$(cat "$TMP/rclone.env")"
  grep -qx ':s3:pg-backups' "$TMP/rclone.argv" || fail "$(cat "$TMP/rclone.argv")"
}

@test "without a region rclone keeps its default" {
  objects a
  shown a
  run "$BIN/s3-verify-listing" "$TMP/buckets"
  [ "$status" -eq 0 ]
  ! grep -q '^RCLONE_S3_REGION=' "$TMP/rclone.env" || fail "$(cat "$TMP/rclone.env")"
}
