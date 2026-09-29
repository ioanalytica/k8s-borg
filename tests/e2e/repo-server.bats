#!/usr/bin/env bats
#
# The repository server, end to end: the image's own sshd as an unprivileged
# user, the image's own Borg as the client, real keys, a real repository. Runs
# once per Borg major like the rest of the suite — Borg 2 talks to
# `borg serve --rest`, Borg 1 to `borg serve`.
#
# What a pod gets from the chart is set up by hand here: the account, the
# Secret's two files, the client list and the directories.

bats_require_minimum_version 1.5.0

SERVER_UID=20222
DATA=/repos
STAGE=/run/borg-repo-server
PORT=2222

as_server() { su -s /bin/sh borg -c "$*"; }

# server_pids — every process of the server: the listener and its sessions.
# busybox pgrep cannot select by user, so the owner is read from /proc.
server_pids() {
  local pid
  for pid in $(pgrep sshd); do
    [ "$(stat -c '%u' "/proc/$pid" 2>/dev/null)" = "$SERVER_UID" ] && echo "$pid"
  done
  return 0
}

start_server() {
  as_server /prepare-repo-server.sh >>/tmp/repo-server.log 2>&1 || return 1
  # The pod mounts the staged directory read-only into the server container.
  chmod -R a-w "$STAGE/home" "$STAGE/hostkeys"
  # 3>&-: bats waits for everything that still holds its descriptor 3.
  as_server /run-repo-server.sh >>/tmp/repo-server.log 2>&1 3>&- &
  local i
  for i in $(seq 1 50); do
    nc -z 127.0.0.1 "$PORT" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}

stop_server() {
  local pids i
  pids="$(server_pids)"
  # shellcheck disable=SC2086
  [ -z "$pids" ] || kill $pids 2>/dev/null || true
  for i in $(seq 1 50); do
    [ -n "$(server_pids)" ] || break
    sleep 0.2
  done
  [ -z "$(server_pids)" ] || { echo "the server did not stop" >&2; return 1; }
  # prepare-repo-server.sh writes into the staged directory again.
  chmod -R u+w "$STAGE/home" "$STAGE/hostkeys" 2>/dev/null || true
}

setup_file() {
  : >/tmp/repo-server.log
  grep -q '^borg:' /etc/passwd \
    || echo "borg:x:$SERVER_UID:$SERVER_UID:Borg repository server:$STAGE/home:/bin/sh" >>/etc/passwd
  grep -q '^borg:' /etc/group || echo "borg:x:$SERVER_UID:" >>/etc/group

  # As the volumes arrive in the pod: the data directory belongs to the server,
  # the staging directory is writable by anyone.
  install -d -o "$SERVER_UID" -g "$SERVER_UID" -m 0755 "$DATA"
  install -d -m 1777 "$STAGE"

  install -d -m 0700 /root/.ssh
  rm -f /root/.ssh/id_ed25519 /root/.ssh/id_reader /root/.ssh/id_keeper /root/.ssh/id_stranger
  ssh-keygen -q -t ed25519 -N "" -C "cluster-a" -f /root/.ssh/id_ed25519
  ssh-keygen -q -t ed25519 -N "" -C "reader" -f /root/.ssh/id_reader
  ssh-keygen -q -t ed25519 -N "" -C "keeper" -f /root/.ssh/id_keeper
  ssh-keygen -q -t ed25519 -N "" -C "stranger" -f /root/.ssh/id_stranger

  install -d /etc/borg-repo-server/ssh /etc/borg-repo-server/clients
  rm -f /etc/borg-repo-server/ssh/ssh_host_ed25519_key
  ssh-keygen -q -t ed25519 -N "" -C "" -f /etc/borg-repo-server/ssh/ssh_host_ed25519_key
  cat /root/.ssh/id_ed25519.pub /root/.ssh/id_reader.pub /root/.ssh/id_keeper.pub \
    >/etc/borg-repo-server/ssh/authorized_keys
  chmod 0444 /etc/borg-repo-server/ssh/ssh_host_ed25519_key /etc/borg-repo-server/ssh/authorized_keys
  printf '%s\n' "reader cluster-a read-only" "keeper cluster-a no-delete" \
    >/etc/borg-repo-server/clients/clients

  # The clients trust exactly this host key.
  printf '[127.0.0.1]:%s %s\n' "$PORT" "$(cat /etc/borg-repo-server/ssh/ssh_host_ed25519_key.pub)" \
    >/root/.ssh/known_hosts

  start_server || { cat /tmp/repo-server.log >&2; return 1; }
}

teardown_file() { stop_server; }

setup() {
  load helpers/repo
  e2e_setup
  SERVER="borg@127.0.0.1"
  unset BORG_RSH BORGSTORE_RSH
  BORG_REPO="$(repo_url "cluster-a/$BATS_TEST_NUMBER")"
  export BORG_REPO
}

teardown() {
  if [ -z "${BATS_TEST_COMPLETED:-}" ]; then
    echo "--- server log ---" >&2
    tail -40 /tmp/repo-server.log >&2
  fi
  e2e_teardown
}

# borg2_beta — the beta number of the image's Borg 2 (24 for 2.0.0b24).
borg2_beta() { borg2 --version 2>/dev/null | sed -n 's/.*2\.0\.0b\([0-9][0-9]*\).*/\1/p'; }

# repo_url PATH — how a client addresses PATH on the server. PATH is relative to
# the data directory; pass one starting with "/" for an absolute path. Borg 2
# named these repositories rest:// up to 2.0.0b24 and ssh:// from then on.
repo_url() {
  local scheme=ssh path="$1"
  if [ "$BORG_VERSION" = "2" ]; then
    [ "$(borg2_beta)" -ge 25 ] || scheme=rest
  else
    # Borg 1 takes a relative path as /./path.
    case "$path" in /*) ;; *) path="./$path" ;; esac
  fi
  printf '%s://%s:%s/%s' "$scheme" "borg@127.0.0.1" "$PORT" "$path"
}

# with_key NAME — the following Borg calls use that key and no other. The port
# is part of it: Borg 2 takes a remote shell command as it is and then ignores
# the port of the URL.
with_key() {
  export BORG_RSH="ssh -p $PORT -i /root/.ssh/id_$1 -o IdentitiesOnly=yes"
  export BORGSTORE_RSH="$BORG_RSH"
}

# host_key — the key the server presents, as "<type> <key>".
host_key() { ssh-keyscan -t ed25519 -p "$PORT" 127.0.0.1 2>/dev/null | grep -v '^#' | awk '{ print $2, $3 }'; }

ssh_server() { ssh -p "$PORT" -o BatchMode=yes -o IdentitiesOnly=yes -i "/root/.ssh/id_${KEY:-ed25519}" "$SERVER" "$@"; }

# --- what a client can do -----------------------------------------------------

@test "a client creates a repository below its directory, backs up and lists it" {
  run borg-init
  [ "$status" -eq 0 ] || fail "$output"
  run borg-backup
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(archive_count)" -eq 1 ]
  [ -d "$DATA/cluster-a/$BATS_TEST_NUMBER" ]
}

@test "repositories are created on demand, several directories deep" {
  # Borg 1 creates a repository only in a directory that exists.
  [ "$BORG_VERSION" = "2" ] || skip "Borg 1 does not create parent directories"
  BORG_REPO="$(repo_url "cluster-a/nodes/node01")" run borg-init
  [ "$status" -eq 0 ] || fail "$output"
  [ -d "$DATA/cluster-a/nodes/node01" ]
}

@test "what the server writes belongs to its user and is closed to everyone else" {
  borg-init
  [ "$(stat -c '%u %a' "$DATA")" = "$SERVER_UID 700" ]
  [ "$(stat -c '%u' "$DATA/cluster-a/$BATS_TEST_NUMBER")" = "$SERVER_UID" ]
  [ -z "$(find "$DATA" -perm /077 | head -1)" ] || fail "readable by others: $(find "$DATA" -perm /077 | head -5)"
}

@test "sshd runs as the unprivileged user" {
  [ -n "$(server_pids)" ] || fail "no sshd of uid $SERVER_UID"
  [ "$(server_pids | wc -l)" -eq "$(pgrep sshd | wc -l)" ] || fail "an sshd runs as another user"
}

# --- what a client cannot do --------------------------------------------------

@test "a repository outside the client's directory is refused" {
  for path in other/repo cluster-a/../other/repo /tmp/outside; do
    BORG_REPO="$(repo_url "$path")" run borg-init
    [ "$status" -ne 0 ] || fail "$path: created"
  done
  [ ! -e "$DATA/other" ]
  [ ! -e /tmp/outside ]
}

@test "a foreign command is refused" {
  run --separate-stderr ssh_server whoami
  [ "$status" -eq 1 ] || fail "status $status, stderr: $stderr"
  [ -z "$output" ] || fail "stdout: $output"
  [[ "$stderr" == *rejected* ]] || fail "$stderr"
}

@test "there is no shell" {
  run --separate-stderr ssh_server
  [ "$status" -eq 1 ] || fail "status $status, stderr: $stderr"
  [[ "$stderr" == *rejected* ]] || fail "$stderr"
}

@test "a command smuggled in behind the request is not run" {
  run ssh_server "borg serve; touch /tmp/pwned"
  [ ! -e /tmp/pwned ]
}

@test "a key the server does not know is refused" {
  KEY=stranger run ssh_server whoami
  [ "$status" -eq 255 ] || fail "status $status: $output"
}

@test "a changed host key is noticed by the client" {
  ssh-keygen -q -t ed25519 -N "" -C "" -f "$TMP/other-host"
  printf '[127.0.0.1]:%s %s\n' "$PORT" "$(cat "$TMP/other-host.pub")" >"$TMP/known_hosts"
  run ssh -p "$PORT" -o BatchMode=yes -o UserKnownHostsFile="$TMP/known_hosts" "$SERVER" whoami
  [ "$status" -eq 255 ] || fail "status $status: $output"
}

# --- permissions --------------------------------------------------------------

@test "a key that may only read lists archives and cannot add one" {
  borg-init
  borg-backup
  with_key reader
  if [ "$BORG_VERSION" = "1" ]; then
    # Borg 1 could not hold the key to reading, so it gets no access at all.
    run borg-list
    [ "$status" -ne 0 ] || fail "a read-only key reached a Borg 1 repository"
    return 0
  fi
  [ "$(archive_count)" -eq 1 ]
  run borg create "$(archive_ref by-reader)" "$SRC"
  [ "$status" -ne 0 ] || fail "a read-only key wrote an archive: $output"
  [ "$(archive_count)" -eq 1 ]
}

@test "a key that may not delete adds archives and cannot remove the repository" {
  borg-init
  with_key keeper
  # Plain `borg create`: borg-backup also creates the repository and prunes,
  # which only a key with all permissions may.
  run borg create "$(archive_ref by-keeper)" "$SRC"
  [ "$status" -eq 0 ] || fail "$output"
  # Confirmed in advance, so that a refusal is the server's and not the prompt's.
  BORG_DELETE_I_KNOW_WHAT_I_AM_DOING=YES run borg-delete
  [ "$status" -ne 0 ] || fail "a no-delete key deleted the repository"
  with_key ed25519
  [ "$(archive_count)" -ge 1 ]
}

# --- restart ------------------------------------------------------------------

@test "after a restart the clients connect without a changed host key" {
  borg-init
  before="$(host_key)"
  stop_server
  start_server || fail "$(tail -20 /tmp/repo-server.log)"
  after="$(host_key)"
  [ -n "$before" ] && [ "$before" = "$after" ] || fail "before: $before / after: $after"
  [ "$before" = "$(cut -d' ' -f1,2 /etc/borg-repo-server/ssh/ssh_host_ed25519_key.pub)" ] \
    || fail "the server presents another key than the one handed in"
  run borg-info
  [ "$status" -eq 0 ] || fail "$output"
}

@test "a key with restricted permissions cannot create a repository" {
  [ "$BORG_VERSION" = "2" ] || skip "Borg 1 has no permissions"
  with_key keeper
  run borg-init
  [ "$status" -ne 0 ] || fail "a no-delete key created a repository"
}

@test "a client added to authorized_keys gets its own directory after a restart" {
  chmod 0644 /etc/borg-repo-server/ssh/authorized_keys
  cat /root/.ssh/id_stranger.pub >>/etc/borg-repo-server/ssh/authorized_keys
  stop_server
  start_server || fail "$(tail -20 /tmp/repo-server.log)"
  with_key stranger
  BORG_REPO="$(repo_url "stranger/repo")" run borg-init
  [ "$status" -eq 0 ] || fail "$output"
  BORG_REPO="$(repo_url "cluster-a/by-stranger")" run borg-init
  [ "$status" -ne 0 ] || fail "the new client reached another client's directory"
}
