#!/usr/bin/env bash
#
# Container entrypoint of the repository server: sshd in the foreground, as an
# unprivileged user.
#
# Host key and authorized_keys were staged by prepare-repo-server.sh; this
# container only reads them. Nothing in here can change who may log in.
#
#   BORG_REPO_SERVER_PORT      port sshd listens on          (2222)
#   BORG_REPO_SERVER_RUN_DIR   the staged directory          (/run/borg-repo-server)
#
set -euo pipefail

die() { echo "FATAL: $*" >&2; exit 1; }

PORT="${BORG_REPO_SERVER_PORT:-2222}"
RUN_DIR="${BORG_REPO_SERVER_RUN_DIR:-/run/borg-repo-server}"
SSHD_CONFIG="${BORG_REPO_SERVER_SSHD_CONFIG:-/etc/borg-repo-server/sshd_config}"
PASSWD_FILE="${BORG_REPO_SERVER_PASSWD:-/etc/passwd}"
SSHD="${BORG_REPO_SERVER_SSHD:-/usr/sbin/sshd}"

uid="$(id -u)"
[ "$uid" != "0" ] || die "the repository server runs as an unprivileged user, not as root"
user="$(awk -F: -v uid="$uid" '$3 == uid { print $1; exit }' "$PASSWD_FILE")"
[ -n "$user" ] || die "uid $uid has no entry in $PASSWD_FILE"

host_key="$RUN_DIR/hostkeys/ssh_host_key"
authorized_keys="$RUN_DIR/home/.ssh/authorized_keys"
[ -s "$host_key" ] || die "$host_key is missing — did prepare-repo-server.sh run?"
[ -s "$authorized_keys" ] || die "$authorized_keys is missing — did prepare-repo-server.sh run?"

echo "Repository server: sshd as $user ($uid:$(id -g)) on port $PORT, $(wc -l < "$authorized_keys" | tr -d ' ') authorized key(s)"

# sshd re-executes itself and therefore has to be started by its full path.
exec "$SSHD" -D -e -f "$SSHD_CONFIG" \
  -p "$PORT" \
  -h "$host_key" \
  -o "AuthorizedKeysFile=$authorized_keys" \
  -o "AllowUsers=$user"
