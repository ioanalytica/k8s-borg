# shellcheck shell=bash
#
# The repository server as the remote end of a test: the image's own sshd as an
# unprivileged user, real keys, a data directory. What a pod gets from the chart
# is set up by hand here: the account, the Secret's two files, the client list
# and the directories.
#
#   setup_file()    { load helpers/repo-server; repo_server_setup; }
#   teardown_file() { load helpers/repo-server; stop_server; }

SERVER_UID=20222
SERVER="borg@127.0.0.1"
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
  for _ in $(seq 1 50); do
    nc -z 127.0.0.1 "$PORT" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}

stop_server() {
  local pids
  pids="$(server_pids)"
  # shellcheck disable=SC2086
  [ -z "$pids" ] || kill $pids 2>/dev/null || true
  for _ in $(seq 1 50); do
    [ -n "$(server_pids)" ] || break
    sleep 0.2
  done
  [ -z "$(server_pids)" ] || { echo "the server did not stop" >&2; return 1; }
  # prepare-repo-server.sh writes into the staged directory again.
  chmod -R u+w "$STAGE/home" "$STAGE/hostkeys" 2>/dev/null || true
}

# repo_server_setup — account, keys, client list, known_hosts; then the server.
# Clients: cluster-a (all permissions, the key in /root/.ssh/id_ed25519),
# reader (read-only) and keeper (no-delete), both for cluster-a's directory.
repo_server_setup() {
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
