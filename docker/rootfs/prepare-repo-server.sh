#!/usr/bin/env bash
#
# Init step of the repository server: stage what sshd needs, with the ownership
# and modes sshd insists on, into a directory the server itself only gets to
# read.
#
#   <stage>/hostkeys/ssh_host_key       the host key                     0600
#   <stage>/home/.ssh/authorized_keys   one line per client key          0600
#
# The clients come as a plain authorized_keys file: `<type> <key> <name>`, the
# comment naming the client. Every key is rewritten into a line that binds it to
# `borg-repo-serve` for one path below the data directory — by default the
# directory named after the client, with the default permissions. The client
# list can set another path or other permissions for a name.
#
# Nothing is generated at random: the host key is handed in, so it is the same
# after every restart.
#
# Runs as the unprivileged user the server runs as.
#
# Inputs (all paths can be overridden, which is what the tests do):
#   BORG_REPO_SERVER_ROOT                 data directory             (/repos)
#   BORG_REPO_SERVER_AUTHORIZED_KEYS      the clients' public keys
#                                         (/etc/borg-repo-server/ssh/authorized_keys)
#   BORG_REPO_SERVER_HOST_KEY             ssh host key, private part
#                                         (/etc/borg-repo-server/ssh/ssh_host_ed25519_key)
#   BORG_REPO_SERVER_CLIENTS              optional, one client per line:
#                                           NAME PATH PERMISSIONS
#                                         (/etc/borg-repo-server/clients/clients)
#   BORG_REPO_SERVER_DEFAULT_PERMISSIONS  for clients not listed     (all)
#   BORG_REPO_SERVER_BORG1                also serve Borg 1          (true)
#   BORG_REPO_SERVER_RUN_DIR              the directory to stage into
#                                         (/run/borg-repo-server)
#
set -euo pipefail

die() { echo "FATAL: $*" >&2; exit 1; }

ROOT="${BORG_REPO_SERVER_ROOT:-/repos}"
KEYS="${BORG_REPO_SERVER_AUTHORIZED_KEYS:-/etc/borg-repo-server/ssh/authorized_keys}"
HOST_KEY="${BORG_REPO_SERVER_HOST_KEY:-/etc/borg-repo-server/ssh/ssh_host_ed25519_key}"
CLIENTS="${BORG_REPO_SERVER_CLIENTS:-/etc/borg-repo-server/clients/clients}"
DEFAULT_PERMISSIONS="${BORG_REPO_SERVER_DEFAULT_PERMISSIONS:-all}"
BORG1="${BORG_REPO_SERVER_BORG1:-true}"
RUN_DIR="${BORG_REPO_SERVER_RUN_DIR:-/run/borg-repo-server}"
PASSWD_FILE="${BORG_REPO_SERVER_PASSWD:-/etc/passwd}"
SERVE="${BORG_REPO_SERVER_SERVE:-/usr/local/bin/borg-repo-serve}"

# Everything written here and below the data directory is private to the
# server's user.
umask 077

# owner FILE / mode FILE — GNU and busybox stat first, BSD stat for the tests.
owner() { stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1"; }
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

valid_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
# Relative, no empty, "." or ".." segment, nothing a shell or sshd would read as
# more than a plain word.
valid_path() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*(/[A-Za-z0-9_][A-Za-z0-9._-]*)*$ ]]; }
valid_permissions() {
  case "$1" in
    all|no-delete|write-only|read-only) return 0 ;;
    *) return 1 ;;
  esac
}

uid="$(id -u)"
[ "$uid" != "0" ] || die "the repository server runs as an unprivileged user, not as root"

# sshd looks the login user up by name, so the uid needs an account.
user="$(awk -F: -v uid="$uid" '$3 == uid { print $1; exit }' "$PASSWD_FILE")"
home="$(awk -F: -v uid="$uid" '$3 == uid { print $6; exit }' "$PASSWD_FILE")"
[ -n "$user" ] || die "uid $uid has no entry in $PASSWD_FILE"
# sshd checks every directory from authorized_keys up to the home directory, and
# the volume itself is writable by anyone. The home directory therefore has to
# be a directory of our own inside it.
[ "$home" = "$RUN_DIR/home" ] || die "the home directory of $user must be $RUN_DIR/home (got \"$home\")"

valid_permissions "$DEFAULT_PERMISSIONS" \
  || die "default permissions \"$DEFAULT_PERMISSIONS\" must be one of all, no-delete, write-only, read-only"
case "$BORG1" in
  true) modes="1,2" ;;
  false) modes="2" ;;
  *) die "BORG_REPO_SERVER_BORG1 must be true or false (got \"$BORG1\")" ;;
esac

echo "Repository server: user $user ($uid:$(id -g)), data directory $ROOT, serving Borg $modes"

# --- data directory -----------------------------------------------------------
# ROOT ends up inside the forced command, so it has to be a plain word.
[[ "$ROOT" =~ ^/[A-Za-z0-9._/-]*$ ]] || die "data directory \"$ROOT\" must be an absolute path without special characters"
[ -d "$ROOT" ] || die "data directory $ROOT does not exist"
[ "$(owner "$ROOT")" = "$uid" ] \
  || die "data directory $ROOT belongs to uid $(owner "$ROOT"), the server runs as $uid — hand the directory over or run the server as its owner"
if [ "$(mode "$ROOT")" != "700" ]; then
  echo "  data directory had mode $(mode "$ROOT"), now 700: only $user reads the repositories"
  chmod 0700 "$ROOT"
fi

if [ ! -d "$RUN_DIR" ] || [ ! -w "$RUN_DIR" ]; then
  die "$RUN_DIR must be a writable volume"
fi

# --- host key -----------------------------------------------------------------
[ -s "$HOST_KEY" ] || die "host key $HOST_KEY is missing or empty — the ssh Secret needs a key ssh_host_ed25519_key"
install -d -m 0700 "$RUN_DIR/hostkeys"
host_key="$RUN_DIR/hostkeys/ssh_host_key"
# A key pasted into a Secret often lost its final newline, which ssh-keygen and
# sshd reject as "invalid format".
{ cat "$HOST_KEY"; [ -z "$(tail -c 1 "$HOST_KEY")" ] || echo; } > "$host_key"
host_pub="$(ssh-keygen -y -f "$host_key" 2>/dev/null </dev/null)" \
  || die "host key $HOST_KEY is not a usable private key (one without a passphrase is required)"
# The public part, for the clients' known_hosts.
read -r host_type host_blob _ <<<"$host_pub"
echo "Host key: $host_type $host_blob"

# --- client list --------------------------------------------------------------
# Checked as a whole before any key is looked at: a line that is wrong here
# would otherwise only show once its client appears.
configured=""
if [ -r "$CLIENTS" ]; then
  while read -r name path permissions rest || [ -n "${name:-}" ]; do
    case "$name" in ''|'#'*) continue ;; esac
    [ -z "${rest:-}" ] || die "client $name: unexpected field \"$rest\" in $CLIENTS"
    valid_name "$name" \
      || die "client name \"$name\" must start with a letter or digit and consist of letters, digits, \".\", \"_\" and \"-\""
    valid_path "${path:-}" \
      || die "client $name: path \"${path:-}\" must be relative, without \"..\", made of letters, digits, \".\", \"_\", \"-\" and \"/\""
    valid_permissions "${permissions:-}" \
      || die "client $name: permissions \"${permissions:-}\" must be one of all, no-delete, write-only, read-only"
    case " $configured " in *" $name "*) die "client $name is listed twice in $CLIENTS" ;; esac
    configured="$configured $name"
  done < "$CLIENTS"
fi

# --- authorized_keys ----------------------------------------------------------
[ -s "$KEYS" ] || die "$KEYS is missing or empty — the ssh Secret needs a key authorized_keys with the clients' public keys"
install -d -m 0700 "$home" "$home/.ssh"
authorized_keys="$home/.ssh/authorized_keys"
# Written from scratch: a restarted init container finds the last one's file.
: > "$authorized_keys"
probe="$RUN_DIR/key-probe"

seen=""
keys=0
line=0
while read -r type blob name _rest || [ -n "${type:-}" ]; do
  line=$((line + 1))
  case "${type:-}" in ''|'#'*) continue ;; esac
  # A public key line starts with its type. Anything else is an option, and an
  # option could lift the restriction this script is about to add.
  case "$type" in
    ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) ;;
    sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ;;
    *) die "$KEYS line $line: \"$type\" is not a public key type — a line is \"<type> <key> <name>\", options are not allowed" ;;
  esac
  printf '%s %s\n' "$type" "${blob:-}" > "$probe"
  ssh-keygen -l -f "$probe" >/dev/null 2>&1 </dev/null || die "$KEYS line $line: invalid public key"
  [ -n "${name:-}" ] || die "$KEYS line $line: the key has no comment — the comment names the client"
  valid_name "$name" \
    || die "$KEYS line $line: \"$name\" does not name a client — start with a letter or digit, then letters, digits, \".\", \"_\" and \"-\""

  path="$name"
  permissions="$DEFAULT_PERMISSIONS"
  if [ -n "$configured" ]; then
    # Compared as text: awk would otherwise take "10" and "10.0" for the same name.
    read -r listed_path listed_permissions \
      <<<"$(awk -v name="$name" '($1 "") == (name "") { print $2, $3; exit }' "$CLIENTS")"
    if [ -n "${listed_path:-}" ]; then
      path="$listed_path"
      permissions="$listed_permissions"
    fi
  fi

  printf 'command="%s %s %s %s %s",restrict %s %s %s\n' \
    "$SERVE" "$ROOT" "$path" "$permissions" "$modes" "$type" "$blob" "$name" >> "$authorized_keys"
  mkdir -p "$ROOT/$path" || die "client $name: cannot create $ROOT/$path"
  echo "  client $name: path $path, permissions $permissions"
  seen="$seen $name"
  keys=$((keys + 1))
done < "$KEYS"
rm -f "$probe"
[ "$keys" -gt 0 ] || die "no public key in $KEYS"

# A name that matches no key is most likely a typo — and then the key it was
# meant for runs with the defaults instead of what was configured for it.
for name in $configured; do
  case " $seen " in
    *" $name "*) ;;
    *) die "client $name is configured, but no key in $KEYS carries that name" ;;
  esac
done

echo "Staged the host key and $keys authorized key(s) in $RUN_DIR"
