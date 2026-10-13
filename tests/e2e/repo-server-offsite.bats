#!/usr/bin/env bats
#
# The repository server's external copy, end to end: the image's own copy job
# (borg-offsite-copy) and rclone, run as the server's user without a single
# passphrase, against a local S3 server (Garage) and an SFTP target that also
# runs `borg serve` — what a Hetzner Storage Box offers. The copies are then
# opened by clients that never talked to the server, and the server is rebuilt
# from one. Runs once per Borg major like the rest of the suite.

bats_require_minimum_version 1.5.0

OFFSITE=/tmp/e2e-offsite
GARAGE_DIR="$OFFSITE/garage"
BOX_PORT=2223
BOX_HOME=/box

garage_cli() { garage -c "$GARAGE_DIR/garage.toml" "$@"; }

setup_file() {
  load helpers/repo-server
  repo_server_setup
  rm -rf "$OFFSITE"
  mkdir -p "$GARAGE_DIR"

  # --- S3: Garage --------------------------------------------------------------
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
  garage -c "$GARAGE_DIR/garage.toml" server >"$GARAGE_DIR/server.log" 2>&1 3>&- &
  GARAGE_PID=$!
  for _ in $(seq 1 50); do garage_cli status >/dev/null 2>&1 && break; sleep 0.2; done
  local node
  node="$(garage_cli node id -q 2>/dev/null | cut -d@ -f1)"
  garage_cli layout assign -z dc1 -c 1G "$node" >/dev/null 2>&1
  garage_cli layout apply --version 1 >/dev/null 2>&1
  garage_cli bucket create offsite >/dev/null 2>&1
  garage_cli key create offsite-key 2>/dev/null >"$GARAGE_DIR/key"
  garage_cli bucket allow --read --write --owner offsite --key offsite-key >/dev/null 2>&1

  # --- SFTP: an account with sftp and a shell for `borg serve` --------------------
  grep -q '^box:' /etc/passwd || echo "box:x:3000:3000:box:$BOX_HOME:/bin/sh" >>/etc/passwd
  grep -q '^box:' /etc/group || echo "box:x:3000:" >>/etc/group
  # "*", not "!": sshd refuses a locked account even for a key.
  grep -q '^box:' /etc/shadow || echo "box:*:19000:0:99999:7:::" >>/etc/shadow
  rm -rf "$BOX_HOME"
  install -d -o 3000 -g 3000 -m 0700 "$BOX_HOME" "$BOX_HOME/.ssh"
  rm -f /root/.ssh/id_box
  ssh-keygen -q -t ed25519 -N "" -C box -f /root/.ssh/id_box
  install -o 3000 -g 3000 -m 0600 /root/.ssh/id_box.pub "$BOX_HOME/.ssh/authorized_keys"
  mkdir -p "$OFFSITE/box-sshd"
  ssh-keygen -q -t ed25519 -N "" -C "" -f "$OFFSITE/box-sshd/host_key"
  cat >"$OFFSITE/box-sshd/sshd_config" <<EOF
Port $BOX_PORT
ListenAddress 127.0.0.1
HostKey $OFFSITE/box-sshd/host_key
PidFile none
PasswordAuthentication no
KbdInteractiveAuthentication no
Subsystem sftp internal-sftp
EOF
  # In the foreground, as a child of this file's process: teardown_file waits
  # for it. A daemon would end up below PID 1, which reaps nothing here, and
  # the next file counts the sshd processes.
  /usr/sbin/sshd -D -f "$OFFSITE/box-sshd/sshd_config" -E "$OFFSITE/box-sshd/log" 3>&- &
  BOX_PID=$!
  for _ in $(seq 1 50); do nc -z 127.0.0.1 "$BOX_PORT" 2>/dev/null && break; sleep 0.2; done
  local box_host_key
  box_host_key="[127.0.0.1]:$BOX_PORT $(cut -d' ' -f1,2 "$OFFSITE/box-sshd/host_key.pub")"
  # The clients reach the box by a name of its own; the repository server is on
  # the same address and must keep getting the clients' own keys.
  echo "$box_host_key" >>/root/.ssh/known_hosts
  cat >>/root/.ssh/config <<EOF
Host box-target
  HostName 127.0.0.1
  Port $BOX_PORT
  User box
  IdentityFile /root/.ssh/id_box
  IdentitiesOnly yes
EOF

  # --- what the chart mounts into the job: rclone.conf, key, known_hosts -----------
  install -d -o "$SERVER_UID" -m 0700 "$OFFSITE/config"
  install -o "$SERVER_UID" -m 0400 /root/.ssh/id_box "$OFFSITE/config/ssh_key"
  echo "$box_host_key" >"$OFFSITE/config/known_hosts"
  cat >"$OFFSITE/config/rclone.conf" <<EOF
[s3]
type = s3
provider = Other
endpoint = http://127.0.0.1:3900
region = eu-central-1
access_key_id = $(awk '/Key ID:/ {print $3}' "$GARAGE_DIR/key")
secret_access_key = $(awk '/Secret key:/ {print $3}' "$GARAGE_DIR/key")

[box]
type = sftp
host = 127.0.0.1
port = $BOX_PORT
user = box
key_file = $OFFSITE/config/ssh_key
known_hosts_file = $OFFSITE/config/known_hosts
EOF
  chown -R "$SERVER_UID" "$OFFSITE/config"
}

teardown_file() {
  load helpers/repo-server
  stop_server
  local pid
  for pid in ${GARAGE_PID:-} ${BOX_PID:-}; do
    kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null
  done
  sed -i '/^Host box-target$/,/^  IdentitiesOnly yes$/d' /root/.ssh/config 2>/dev/null
  rm -rf "$OFFSITE" "$BOX_HOME"
  return 0
}

setup() {
  load helpers/repo
  load helpers/repo-server
  e2e_setup
  unset BORG_RSH BORGSTORE_RSH
  REL="cluster-a/offsite-$BATS_TEST_NUMBER"
  BORG_REPO="$(repo_url "$REL")"
  export BORG_REPO
  # Every test's client starts without anything Borg remembers about a
  # repository, so that "never talked to the server" means what it says.
  export BORG_BASE_DIR="$TMP/client"
  # The S3 and the box copy of this test.
  S3_TARGET="s3:offsite/t$BATS_TEST_NUMBER"
  BOX_TARGET="box:t$BATS_TEST_NUMBER"
}

teardown() {
  if [ -z "${BATS_TEST_COMPLETED:-}" ]; then
    echo "--- server log ---" >&2
    tail -20 /tmp/repo-server.log >&2
    echo "--- job log ---" >&2
    cat "$TMP/job.log" >&2 2>/dev/null
  fi
  e2e_teardown
}

# copy_job TARGET [RCLONE OPTION…] — the job as the chart runs it: the server's
# user, nothing of the client's environment (no passphrase, no key), the files
# the chart mounts. SOURCE overrides the data directory.
copy_job() {
  local target="$1" options=""
  shift
  # In the command itself: busybox su would take an option among its
  # arguments for one of its own.
  [ $# -eq 0 ] || printf -v options '%q ' "$@"
  su -s /bin/bash borg -c "
    exec env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/tmp TZ=UTC \\
      RCLONE_CONFIG=$OFFSITE/config/rclone.conf BORG_OFFSITE_SOURCE=${SOURCE:-$DATA} \\
      BORG_OFFSITE_TARGET=$target BORG_OFFSITE_RETRY_DELAY=1 /usr/local/bin/borg-offsite-copy $options
  " 2>&1 | tee -a "$TMP/job.log"
  return "${PIPESTATUS[0]}"
}

# s3_url PATH — how a Borg 2 client names a copy on the S3 server.
s3_url() {
  printf 's3:%s:%s@http://127.0.0.1:3900/offsite/%s' \
    "$(awk '/Key ID:/ {print $3}' "$GARAGE_DIR/key")" \
    "$(awk '/Secret key:/ {print $3}' "$GARAGE_DIR/key")" "$1"
}

remote_files() { RCLONE_CONFIG="$OFFSITE/config/rclone.conf" rclone lsf -R --files-only "$1" 2>/dev/null; }

# check_copy URL — a client checks the copy at URL and counts its archives.
check_copy() {
  BORG_REPO="$1" run borg check
  [ "$status" -eq 0 ] || fail "borg check of the copy at $1: $output"
  BORG_REPO="$1" archive_count
}

# backup — one more archive in the test's repository, through the server.
backup() {
  echo "$RANDOM" >"$SRC/changed-$RANDOM"
  run borg-backup
  [ "$status" -eq 0 ] || fail "$output"
}

# --- copies a stranger can open -------------------------------------------------

@test "a copy on S3 is opened and checked by a client that never talked to the server" {
  borg-init
  backup
  run copy_job "$S3_TARGET" --transfers=4
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"$REL: copied (Borg $BORG_VERSION, attempt 1)"* ]] || fail "$output"
  ! remote_files "$S3_TARGET/$REL" | grep -qE '^(lock\.|locks/)' || fail "lock files were copied"

  export BORG_BASE_DIR="$TMP/stranger"
  if [ "$BORG_VERSION" = "2" ]; then
    [ "$(check_copy "$(s3_url "t$BATS_TEST_NUMBER/$REL")")" -eq 1 ]
  else
    # Borg 1 knows no S3: the copy is downloaded first.
    RCLONE_CONFIG="$OFFSITE/config/rclone.conf" rclone copy "$S3_TARGET/$REL" "$TMP/download"
    [ "$(check_copy "$TMP/download")" -eq 1 ]
  fi
}

@test "a copy on an SFTP target is opened there directly" {
  borg-init
  backup
  run copy_job "$BOX_TARGET"
  [ "$status" -eq 0 ] || fail "$output"
  export BORG_BASE_DIR="$TMP/stranger"
  if [ "$BORG_VERSION" = "2" ]; then
    # Borg 2 uses the box as plain storage: sftp, relative to the login directory.
    [ "$(check_copy "sftp://box-target/t$BATS_TEST_NUMBER/$REL")" -eq 1 ]
  else
    # Borg 1 runs `borg serve` on the box, as a Storage Box offers it.
    export BORG_REMOTE_PATH=/opt/borg-ui-agent/borg1/current/borg
    [ "$(check_copy "ssh://box-target/./t$BATS_TEST_NUMBER/$REL")" -eq 1 ]
  fi
}

# --- consistency --------------------------------------------------------------------

@test "a backup during the copy is noticed, and the copy is taken again" {
  borg-init
  head -c 12000000 /dev/urandom >"$SRC/bulk"
  backup
  # Throttled, so that the second backup lands in the middle of the copy.
  copy_job "$S3_TARGET" --bwlimit=1M >/dev/null &
  local job=$!
  sleep 3
  backup
  wait "$job" || fail "the job failed: $(cat "$TMP/job.log")"
  grep -q "$REL: changed during the copy (attempt 1 of 3)" "$TMP/job.log" || fail "$(cat "$TMP/job.log")"
  grep -q "$REL: copied (Borg $BORG_VERSION, attempt [23])" "$TMP/job.log" || fail "$(cat "$TMP/job.log")"
  export BORG_BASE_DIR="$TMP/stranger"
  if [ "$BORG_VERSION" = "2" ]; then
    [ "$(check_copy "$(s3_url "t$BATS_TEST_NUMBER/$REL")")" -eq 2 ]
  else
    RCLONE_CONFIG="$OFFSITE/config/rclone.conf" rclone copy "$S3_TARGET/$REL" "$TMP/download"
    [ "$(check_copy "$TMP/download")" -eq 2 ]
  fi
}

# --- nothing lost on the remote -------------------------------------------------------

@test "an empty data directory leaves the copy untouched" {
  borg-init
  backup
  copy_job "$S3_TARGET" >/dev/null || fail "$(cat "$TMP/job.log")"
  before="$(remote_files "$S3_TARGET" | sort)"
  [ -n "$before" ]
  # The server on a new, empty volume.
  install -d -o "$SERVER_UID" -m 0700 "$OFFSITE/empty"
  SOURCE="$OFFSITE/empty" run copy_job "$S3_TARGET"
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"no repository below"* ]] || fail "$output"
  [ "$(remote_files "$S3_TARGET" | sort)" = "$before" ] || fail "the copy changed"
}

# --- restore ------------------------------------------------------------------------

@test "the server is rebuilt from the copy, and its clients carry on" {
  borg-init
  backup
  copy_job "$S3_TARGET" >/dev/null || fail "$(cat "$TMP/job.log")"
  # A backup after the last copy: lost with the storage.
  backup
  [ "$(archive_count)" -eq 2 ]

  # The storage fails; a new volume is filled from the copy, as the server's
  # user and with its umask: rclone would leave the files readable by others.
  stop_server
  rm -rf "${DATA:?}/$REL"
  su -s /bin/sh borg -c "umask 077 && exec env -i HOME=/tmp RCLONE_CONFIG=$OFFSITE/config/rclone.conf \
    rclone copy $S3_TARGET/$REL $DATA/$REL"
  [ -z "$(find "$DATA/$REL" -perm /077 | head -1)" ] || fail "restored readable by others"
  start_server || fail "$(tail -20 /tmp/repo-server.log)"

  if [ "$BORG_VERSION" = "1" ]; then
    # The client has seen the lost archive and takes the older state for an attack…
    run borg-list
    [ "$status" -ne 0 ] || fail "Borg 1 accepted a repository older than it knows"
    [[ "$output" == *"newer than repository"* ]] || fail "$output"
    # …until it forgets what it knew of this repository.
    local id
    id="$(awk '$1 == "id" { print $3 }' "$DATA/$REL/config")"
    rm -rf "$BORG_BASE_DIR/.config/borg/security/$id" "$BORG_BASE_DIR/.cache/borg/$id"
  fi
  [ "$(archive_count)" -eq 1 ]
  # The client's files cache still names chunks that went with the storage. The
  # next backup must not refer to them.
  backup
  [ "$(archive_count)" -eq 2 ]
  run borg check
  [ "$status" -eq 0 ] || fail "after the first backup on the rebuilt server: $output"
}

@test "a client that knew the repository on the server opens the copy once told it moved" {
  borg-init
  backup
  copy_job "$BOX_TARGET" >/dev/null || fail "$(cat "$TMP/job.log")"
  if [ "$BORG_VERSION" = "2" ]; then
    copy="sftp://box-target/t$BATS_TEST_NUMBER/$REL"
  else
    export BORG_REMOTE_PATH=/opt/borg-ui-agent/borg1/current/borg
    copy="ssh://box-target/./t$BATS_TEST_NUMBER/$REL"
  fi
  BORG_REPO="$copy" run borg-list </dev/null
  [ "$status" -ne 0 ] || fail "opened a moved repository without asking"
  [[ "$output" == *"previously located at"* ]] || fail "$output"
  [ "$(BORG_RELOCATED_REPO_ACCESS_IS_OK=yes BORG_REPO="$copy" archive_count)" -eq 1 ]
}
