#!/usr/bin/env bats
#
# S3 sources against a real S3 server: the image's s3fs, s3-mount-bucket,
# s3-verify-listing and borg-backup, with a single-node Garage in the container.
#
# The objects are written the way rclone writes them, without directory
# objects, so every directory is implicit. s3fs 1.96 and 1.97 listed two
# entries of such a directory once its stat cache entry had expired, and Borg
# archived those two (see docker/Dockerfile); the image's s3fs carries the
# upstream fix, and the first test fails without it.

bats_require_minimum_version 1.5.0

GARAGE_DIR=/tmp/e2e-garage
FILES_PER_DIR=72

garage_cli() { garage -c "$GARAGE_DIR/garage.toml" "$@"; }

setup_file() {
  rm -rf "$GARAGE_DIR"
  mkdir -p "$GARAGE_DIR"
  cat >"$GARAGE_DIR/garage.toml" <<EOF
metadata_dir = "$GARAGE_DIR/meta"
data_dir = "$GARAGE_DIR/data"
db_engine = "sqlite"
replication_factor = 1
rpc_bind_addr = "127.0.0.1:3901"
rpc_public_addr = "127.0.0.1:3901"
rpc_secret = "$(openssl rand -hex 32)"
[s3_api]
s3_region = "eu-central-1"
api_bind_addr = "127.0.0.1:3900"
EOF
  # Started directly, not through garage_cli, so that $! is the server itself.
  garage -c "$GARAGE_DIR/garage.toml" server >"$GARAGE_DIR/server.log" 2>&1 3>&- &
  echo $! >"$GARAGE_DIR/pid"
  for _ in $(seq 1 50); do garage_cli status >/dev/null 2>&1 && break; sleep 0.2; done
  local node
  node="$(garage_cli node id -q 2>/dev/null | cut -d@ -f1)"
  garage_cli layout assign -z dc1 -c 1G "$node" >/dev/null 2>&1
  garage_cli layout apply --version 1 >/dev/null 2>&1
  garage_cli bucket create e2e-bucket >/dev/null 2>&1
  garage_cli key create e2e-key 2>/dev/null >"$GARAGE_DIR/key"
  garage_cli bucket allow --read --write --owner e2e-bucket --key e2e-key >/dev/null 2>&1

  # Two flat directories and one with only a subdirectory, none with a
  # directory object.
  local src="$GARAGE_DIR/src" i
  mkdir -p "$src/db-a" "$src/db-b" "$src/nested/sub"
  for i in $(seq -w 1 "$FILES_PER_DIR"); do
    echo "a$i" >"$src/db-a/backup.$i.sql.gz"
    echo "b$i" >"$src/db-b/backup.$i.sql.gz"
    echo "n$i" >"$src/nested/sub/part.$i"
  done
  load_s3_env
  rclone copy "$src" :s3:e2e-bucket 2>"$GARAGE_DIR/rclone.err" 3>&- \
    || { cat "$GARAGE_DIR/rclone.err" >&2; return 1; }
}

teardown_file() {
  umount /mnt/s3/e2e-bucket 2>/dev/null || true
  [ -f "$GARAGE_DIR/pid" ] && kill "$(cat "$GARAGE_DIR/pid")" 2>/dev/null
  rm -rf "$GARAGE_DIR"
  return 0
}

# load_s3_env — the environment the chart gives the pods, plus rclone's.
load_s3_env() {
  export S3_ENDPOINT=http://127.0.0.1:3900 S3_REGION=eu-central-1 S3_MOUNTPOINT=/mnt/s3
  AWS_KEY="$(awk '/Key ID:/ {print $3}' "$GARAGE_DIR/key")"
  AWS_SECRET_KEY="$(awk '/Secret key:/ {print $3}' "$GARAGE_DIR/key")"
  export AWS_KEY AWS_SECRET_KEY
  export RCLONE_S3_PROVIDER=Other RCLONE_S3_ENDPOINT="$S3_ENDPOINT" RCLONE_S3_REGION="$S3_REGION" \
         RCLONE_S3_ACCESS_KEY_ID="$AWS_KEY" RCLONE_S3_SECRET_ACCESS_KEY="$AWS_SECRET_KEY" \
         RCLONE_CONFIG=/dev/null
}

setup() {
  load helpers/repo
  e2e_setup
  load_s3_env
  install -m 600 /dev/null /root/.s3fs
  printf '%s:%s\n' "$AWS_KEY" "$AWS_SECRET_KEY" >/root/.s3fs
  echo e2e-bucket >"$TMP/buckets"
  MP=/mnt/s3/e2e-bucket
}

teardown() {
  umount "$MP" 2>/dev/null || true
  e2e_teardown
}

count() { find "$1" -maxdepth 1 -type f | wc -l; }

@test "s3fs lists an implicit directory completely after its stat expired" {
  mkdir -p "$MP"
  # The options s3-mount-bucket uses, with a short stat cache so the test does
  # not wait the default 15 minutes.
  s3fs e2e-bucket "$MP" -o "passwd_file=/root/.s3fs,use_path_request_style,listobjectsv2,url=$S3_ENDPOINT,endpoint=$S3_REGION,stat_cache_expire=2"
  ls "$MP" >/dev/null
  sleep 3
  stat "$MP/db-a" >/dev/null
  [ "$(count "$MP/db-a")" -eq "$FILES_PER_DIR" ] || fail "db-a lists $(count "$MP/db-a") of $FILES_PER_DIR files"
  [ "$(count "$MP/db-b")" -eq "$FILES_PER_DIR" ] || fail "db-b lists $(count "$MP/db-b") of $FILES_PER_DIR files"
}

@test "s3-verify-listing passes a complete mount" {
  s3-mount-bucket e2e-bucket
  run s3-verify-listing "$TMP/buckets"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [[ $output == *"e2e-bucket: $((3 * FILES_PER_DIR)) objects, all under $MP"* ]] || fail "$output"
}

@test "s3-verify-listing reports a key the mount does not show" {
  s3-mount-bucket e2e-bucket
  # An object that s3fs cannot show as a file: "db-a" as a key of its own
  # next to the "db-a/" prefix is listed as the directory.
  echo clash | rclone rcat :s3:e2e-bucket/db-a 2>/dev/null
  run --separate-stderr s3-verify-listing "$TMP/buckets"
  rclone deletefile :s3:e2e-bucket/db-a 2>/dev/null
  [ "$status" -eq 1 ] || fail "status $status: $output $stderr"
  [[ $stderr == *"1 of $((3 * FILES_PER_DIR + 1)) objects missing"* ]] || fail "$stderr"
  [[ $stderr == *"mounting again and checking once more"* ]] || fail "$stderr"
  [[ $stderr == *"    db-a"* ]] || fail "$stderr"
}

@test "s3-verify-listing mounts a bucket again whose s3fs died" {
  s3-mount-bucket e2e-bucket
  pkill -KILL -f "^s3fs e2e-bucket $MP( |\$)"
  ! ls "$MP" >/dev/null 2>&1 || fail "the mount still answers after s3fs was killed"
  run --separate-stderr s3-verify-listing "$TMP/buckets"
  [ "$status" -eq 0 ] || fail "status $status: $output $stderr"
  [[ $stderr == *"$MP is not mounted, mounting it again"* ]] || fail "$stderr"
  [[ $output == *"e2e-bucket: $((3 * FILES_PER_DIR)) objects, all under $MP"* ]] || fail "$output"
}

@test "borg-backup checks the mount and archives every object" {
  s3-mount-bucket e2e-bucket
  write_patterns "R $MP"
  S3_ENABLED=true S3_BUCKETS_FILE="$TMP/buckets" run borg-backup
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [[ $output == *"e2e-bucket: $((3 * FILES_PER_DIR)) objects, all under $MP"* ]] || fail "$output"
  run borg list --format '{type} {path}{NL}' "$(archive_ref "$(first_archive)")"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^- .*/db-a/' <<<"$output")" -eq "$FILES_PER_DIR" ] || fail "$output"
  [ "$(grep -c '^- .*/nested/sub/' <<<"$output")" -eq "$FILES_PER_DIR" ] || fail "$output"
}

@test "borg-backup fails a run whose S3 mount misses objects, after archiving" {
  s3-mount-bucket e2e-bucket
  write_patterns "R $MP"
  echo clash | rclone rcat :s3:e2e-bucket/db-a 2>/dev/null
  S3_ENABLED=true S3_BUCKETS_FILE="$TMP/buckets" run borg-backup
  rclone deletefile :s3:e2e-bucket/db-a 2>/dev/null
  [ "$status" -eq 2 ] || fail "status $status: $output"
  [[ $output == *"an S3 mount does not show every object"* ]] || fail "$output"
  [ "$(archive_count)" -eq 1 ] || fail "no archive written"
}

@test "s3.verifyListing=false skips the check" {
  s3-mount-bucket e2e-bucket
  write_patterns "R $MP"
  S3_ENABLED=true S3_VERIFY_LISTING=false S3_BUCKETS_FILE="$TMP/buckets" run borg-backup
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [[ $output != *"Checking the S3 mounts"* ]] || fail "$output"
}
