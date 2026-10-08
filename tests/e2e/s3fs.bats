#!/usr/bin/env bats
#
# S3 sources against a real S3 server: the image's s3fs, s3-mount-bucket,
# s3-mount-buckets, s3-verify-listing and borg-backup, with a single-node Garage
# in the container.
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

# agent_script_run NAME — run allow-listed script NAME from $TMP/agent-scripts
# the way the cluster agent runs a plan hook (script.run, the agent's own code
# in the image), against a stand-in for the server. Prints the job's state, its
# return code and its log lines. With CANCEL_ON set, the job is cancelled once a
# log line contains that text.
agent_script_run() {
  local python
  python="$(head -1 "$(command -v borg-ui-agent)" | sed 's/^#!//')"
  BORG_UI_AGENT_SCRIPTS_DIR="$TMP/agent-scripts" timeout 120 "$python" - "$1" <<'PY'
import sys, threading
from agent.borg_ui_agent.scripts import execute_script_run_job

class Server:
    state = rc = None
    cancel = threading.Event()
    def send_log(self, job_id, sequence, stream, message):
        print(f"[{stream}] {message}", flush=True)
        on = __import__("os").environ.get("CANCEL_ON")
        if on and on in message:
            self.cancel.set()
    def complete_job(self, job_id, result):
        self.state, self.rc = "completed", result.get("return_code")
    def fail_job(self, job_id, error_message):
        self.state = "failed"
    def cancel_job(self, job_id):
        self.state = "canceled"

server = Server()
execute_script_run_job({"id": 1, "payload": {"script": {"name": sys.argv[1]}}},
                       server, should_cancel=server.cancel.is_set)
print(f"state={server.state} rc={server.rc}")
PY
}

# assert_s3fs_detached — the bucket's s3fs runs in a session of its own and
# holds none of the script's output pipes, so it outlives the script and the
# agent reads the script's output to its end.
assert_s3fs_detached() {
  local pids pid sid
  pids="$(pgrep -f "^s3fs e2e-bucket $MP( |\$)")" || fail "no s3fs for e2e-bucket after the script ended"
  [ "$(wc -w <<<"$pids")" -eq 1 ] || fail "more than one s3fs: $pids"
  pid=$pids
  sid="$(sed 's/.*) //' "/proc/$pid/stat" | cut -d' ' -f4)"
  [ "$sid" = "$pid" ] || fail "s3fs $pid is in session $sid, not its own"
  [ "$(readlink "/proc/$pid/fd/1")" = /dev/null ] || fail "s3fs stdout: $(readlink "/proc/$pid/fd/1")"
  [ "$(readlink "/proc/$pid/fd/2")" = /dev/null ] || fail "s3fs stderr: $(readlink "/proc/$pid/fd/2")"
  [ "$(find "$MP" -type f | wc -l)" -eq $((3 * FILES_PER_DIR)) ] || fail "the new mount shows $(find "$MP" -type f | wc -l) files"
}

# Plan mode: the console pod's cluster agent runs s3-verify-listing as a
# pre-backup hook (the chart's wrapper), and the bucket it mounts again must
# still be mounted when borg create runs after the hook.
@test "s3-verify-listing as an agent hook: the bucket it mounts again outlives the hook" {
  s3-mount-bucket e2e-bucket
  pkill -KILL -f "^s3fs e2e-bucket $MP( |\$)"
  mkdir -p "$TMP/agent-scripts"
  printf '#!/bin/sh\nexec s3-verify-listing %s\n' "$TMP/buckets" >"$TMP/agent-scripts/s3-verify-listing"
  chmod 0555 "$TMP/agent-scripts/s3-verify-listing"
  run agent_script_run s3-verify-listing
  [ "$status" -eq 0 ] || fail "status $status (124: the agent still waits for the script's output): $output"
  [[ $output == *"$MP is not mounted, mounting it again"* ]] || fail "$output"
  [[ $output == *"e2e-bucket: $((3 * FILES_PER_DIR)) objects, all under $MP"* ]] || fail "$output"
  [[ $output == *"state=completed rc=0"* ]] || fail "$output"
  assert_s3fs_detached
}

@test "s3-verify-listing as an agent hook: a cancelled hook leaves the new mount in place" {
  s3-mount-bucket e2e-bucket
  pkill -KILL -f "^s3fs e2e-bucket $MP( |\$)"
  mkdir -p "$TMP/agent-scripts"
  # The agent cancels by signalling the script's process group.
  printf '#!/bin/sh\ns3-verify-listing %s\nexec sleep 300\n' "$TMP/buckets" >"$TMP/agent-scripts/verify-then-wait"
  chmod 0555 "$TMP/agent-scripts/verify-then-wait"
  CANCEL_ON="objects, all under" run agent_script_run verify-then-wait
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [[ $output == *"state=canceled"* ]] || fail "$output"
  assert_s3fs_detached
}

# s3fs_pid — the pid of the bucket's s3fs, or nothing.
s3fs_pid() { pgrep -f "^s3fs e2e-bucket $MP( |\$)"; }

# gone PID — the process has ended within 5 s (a zombie counts: only its exit
# status is left). s3fs ends on its own shortly after its unmount.
gone() {
  local _
  for _ in $(seq 1 50); do
    [ ! -e "/proc/$1" ] || [ "$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1)" = Z ] && return 0
    sleep 0.1
  done
  return 1
}

# Plan mode: before each backup the cluster agent mounts every bucket fresh,
# as each CronJob run does, so the console pod's long-lived mount is never
# what Borg reads.
@test "s3-remount-buckets as an agent hook: every bucket gets a new s3fs that outlives the hook" {
  s3-mount-bucket e2e-bucket
  local old
  old="$(s3fs_pid)"
  mkdir -p "$TMP/agent-scripts"
  printf '#!/bin/sh\nexec s3-remount-buckets %s\n' "$TMP/buckets" >"$TMP/agent-scripts/s3-remount-buckets"
  chmod 0555 "$TMP/agent-scripts/s3-remount-buckets"
  run agent_script_run s3-remount-buckets
  [ "$status" -eq 0 ] || fail "status $status (124: the agent still waits for the script's output): $output"
  [[ $output == *"state=completed rc=0"* ]] || fail "$output"
  gone "$old" || fail "the old s3fs $old still runs"
  [ "$(s3fs_pid)" != "$old" ] || fail "no new s3fs"
  assert_s3fs_detached
}

@test "s3-remount-buckets as an agent hook: a busy mount is detached and mounted fresh" {
  s3-mount-bucket e2e-bucket
  local old busy
  old="$(s3fs_pid)"
  # A shell standing in the mount keeps it busy.
  (cd "$MP/db-a" && exec sleep 300) &
  busy=$!
  mkdir -p "$TMP/agent-scripts"
  printf '#!/bin/sh\nexec s3-remount-buckets %s\n' "$TMP/buckets" >"$TMP/agent-scripts/s3-remount-buckets"
  chmod 0555 "$TMP/agent-scripts/s3-remount-buckets"
  run agent_script_run s3-remount-buckets
  kill "$busy" 2>/dev/null; wait "$busy" 2>/dev/null || true
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [[ $output == *"$MP is busy, detaching it"* ]] || fail "$output"
  [[ $output == *"state=completed rc=0"* ]] || fail "$output"
  gone "$old" || fail "the old s3fs $old still runs"
  assert_s3fs_detached
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

# A bucket that does not exist on the server: s3fs mounts it and then fails or
# hangs on the first listing, as after a move to a new S3 server.
@test "s3-mount-buckets skips a bucket that cannot be mounted and mounts the rest" {
  printf '%s\n' e2e-bucket e2e-missing >"$TMP/buckets"
  S3_PROBE_TIMEOUT=5 run --separate-stderr s3-mount-buckets "$TMP/buckets"
  [ "$status" -eq 1 ] || fail "status $status: $output $stderr"
  [[ $stderr == *"WARNING: S3 bucket 'e2e-missing' is skipped"* ]] || fail "$stderr"
  mountpoint -q "$MP" || fail "e2e-bucket is not mounted"
  ! grep -q ' /mnt/s3/e2e-missing ' /proc/mounts || fail "mount entry left: $(grep e2e-missing /proc/mounts)"
  ! pgrep -f '^s3fs e2e-missing ' >/dev/null || fail "s3fs of the skipped bucket still runs"
  [ ! -e /mnt/s3/e2e-missing ] || fail "the empty directory of the skipped bucket is left behind"
}

@test "s3-mount-buckets stops when no listed bucket can be mounted" {
  echo e2e-missing >"$TMP/buckets"
  S3_PROBE_TIMEOUT=5 run --separate-stderr s3-mount-buckets "$TMP/buckets"
  [ "$status" -eq 2 ] || fail "status $status: $output $stderr"
  [[ $stderr == *"none of the 1 listed S3 buckets is mounted"* ]] || fail "$stderr"
}

@test "borg-backup ends with a warning when a listed bucket is not mounted" {
  s3-mount-bucket e2e-bucket
  write_patterns "R /mnt/s3"
  printf '%s\n' e2e-bucket e2e-missing >"$TMP/buckets"
  S3_ENABLED=true S3_BUCKETS_FILE="$TMP/buckets" S3_PROBE_TIMEOUT=5 run borg-backup
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [[ $output == *"e2e-missing: cannot mount again, not checked (s3.onMountFailure=skip)"* ]] || fail "$output"
  [[ $output == *"WARNING: 1 of 2 listed S3 buckets are not mounted and not backed up: e2e-missing"* ]] || fail "$output"
  [[ $output == *"finished with a warning"* ]] || fail "$output"
  [ "$(archive_count)" -eq 1 ] || fail "no archive written"
}

@test "borg-backup fails under s3.onMountFailure=fail when a listed bucket is not mounted" {
  s3-mount-bucket e2e-bucket
  write_patterns "R $MP"
  printf '%s\n' e2e-bucket e2e-missing >"$TMP/buckets"
  S3_ENABLED=true S3_ON_MOUNT_FAILURE=fail S3_VERIFY_LISTING=false S3_BUCKETS_FILE="$TMP/buckets" run borg-backup
  [ "$status" -eq 2 ] || fail "status $status: $output"
  [[ $output == *"ERROR: S3 buckets are missing from this backup"* ]] || fail "$output"
}
