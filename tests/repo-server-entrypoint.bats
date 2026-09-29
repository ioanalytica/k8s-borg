#!/usr/bin/env bats
#
# prepare-repo-server.sh rewrites the clients' plain authorized_keys into lines
# that bind every key to one path, and stages the host key; run-repo-server.sh
# starts sshd on what was staged. What is written decides who may reach which
# path, so the tests pin the exact lines — and that anything malformed stops the
# start instead of being skipped.

setup() {
  load helpers/common
  common_setup
  command -v ssh-keygen >/dev/null || fail "ssh-keygen is required for these tests"

  export BORG_REPO_SERVER_ROOT="$TMP/repos"
  export BORG_REPO_SERVER_RUN_DIR="$TMP/run"
  export BORG_REPO_SERVER_CLIENTS="$TMP/clients"
  export BORG_REPO_SERVER_AUTHORIZED_KEYS="$TMP/ssh/authorized_keys"
  export BORG_REPO_SERVER_HOST_KEY="$TMP/ssh/ssh_host_ed25519_key"
  export BORG_REPO_SERVER_PASSWD="$TMP/passwd"
  export BORG_REPO_SERVER_SSHD_CONFIG="$ROOTFS/etc/borg-repo-server/sshd_config"
  export BORG_REPO_SERVER_SERVE="/usr/local/bin/borg-repo-serve"
  export BORG_REPO_SERVER_SSHD="$TMP/fake-sshd"
  export BORG_REPO_SERVER_PORT=2222
  unset BORG_REPO_SERVER_DEFAULT_PERMISSIONS BORG_REPO_SERVER_BORG1
  HOME_DIR="$BORG_REPO_SERVER_RUN_DIR/home"
  STAGED="$HOME_DIR/.ssh/authorized_keys"

  mkdir -p "$BORG_REPO_SERVER_ROOT" "$BORG_REPO_SERVER_RUN_DIR" "$TMP/ssh"
  printf 'root:x:0:0:root:/root:/bin/sh\nborg:x:%s:%s:repo:%s:/bin/sh\n' \
    "$(id -u)" "$(id -g)" "$HOME_DIR" > "$BORG_REPO_SERVER_PASSWD"
  ssh-keygen -q -t ed25519 -N "" -C "" -f "$BORG_REPO_SERVER_HOST_KEY"

  cat >"$BORG_REPO_SERVER_SSHD" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TMP/argv"
STUB
  chmod +x "$BORG_REPO_SERVER_SSHD"

  add_key cluster-a
}

teardown() { common_teardown; }

# add_key NAME — a fresh key with NAME as its comment, appended to authorized_keys.
add_key() {
  ssh-keygen -q -t ed25519 -N "" -C "$1" -f "$TMP/client-$1"
  cat "$TMP/client-$1.pub" >> "$BORG_REPO_SERVER_AUTHORIZED_KEYS"
}

# configure NAME PATH PERMISSIONS — a line of the client list.
configure() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$BORG_REPO_SERVER_CLIENTS"; }

key_blob() { awk '{ print $2 }' "$TMP/client-$1.pub"; }

# staged_line NAME PATH PERMISSIONS [MODES] — what the key of NAME has to become.
staged_line() {
  printf 'command="/usr/local/bin/borg-repo-serve %s %s %s %s",restrict ssh-ed25519 %s %s' \
    "$BORG_REPO_SERVER_ROOT" "$2" "$3" "${4:-1,2}" "$(key_blob "$1")" "$1"
}

# mode FILE — permission bits, on Linux and macOS.
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# start — the init step, then the server, as the pod runs them.
start() {
  run "$ROOTFS/prepare-repo-server.sh"
  [ "$status" -eq 0 ] || return 0
  prepared="$output"
  run "$ROOTFS/run-repo-server.sh"
  output="$prepared"$'\n'"$output"
}

# --- what a key becomes -------------------------------------------------------

@test "a key is bound to the directory named after its client" {
  start
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(cat "$STAGED")" = "$(staged_line cluster-a cluster-a all)" ] || fail "got: $(cat "$STAGED")"
}

@test "a new client is one more line in authorized_keys" {
  add_key cluster-b
  start
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(wc -l < "$STAGED" | tr -d ' ')" = "2" ]
  grep -qxF "$(staged_line cluster-b cluster-b all)" "$STAGED"
  [ -d "$BORG_REPO_SERVER_ROOT/cluster-b" ]
}

@test "the client list sets another path and other permissions for a name" {
  add_key restore-test
  configure restore-test cluster-a read-only
  start
  [ "$status" -eq 0 ] || fail "$output"
  grep -qxF "$(staged_line restore-test cluster-a read-only)" "$STAGED"
  grep -qxF "$(staged_line cluster-a cluster-a all)" "$STAGED"
  [ ! -e "$BORG_REPO_SERVER_ROOT/restore-test" ]
}

@test "names are compared as text, not as numbers" {
  add_key 10
  configure 10.0 elsewhere read-only
  add_key 10.0
  start
  [ "$status" -eq 0 ] || fail "$output"
  grep -qxF "$(staged_line 10 10 all)" "$STAGED" || fail "$(cat "$STAGED")"
  grep -qxF "$(staged_line 10.0 elsewhere read-only)" "$STAGED"
}

@test "a path can be several directories deep" {
  configure cluster-a site/cluster-a no-delete
  start
  [ "$status" -eq 0 ] || fail "$output"
  grep -qxF "$(staged_line cluster-a site/cluster-a no-delete)" "$STAGED"
  [ -d "$BORG_REPO_SERVER_ROOT/site/cluster-a" ]
}

@test "clients that are not listed get the default permissions" {
  export BORG_REPO_SERVER_DEFAULT_PERMISSIONS=no-delete
  start
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(cat "$STAGED")" = "$(staged_line cluster-a cluster-a no-delete)" ]
}

@test "two keys with the same name are the same client" {
  ssh-keygen -q -t ed25519 -N "" -C "cluster-a" -f "$TMP/second"
  cat "$TMP/second.pub" >> "$BORG_REPO_SERVER_AUTHORIZED_KEYS"
  configure cluster-a shared no-delete
  start
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(grep -c 'shared no-delete 1,2",restrict' "$STAGED")" = "2" ]
}

@test "only the first word of a comment is the name" {
  printf '%s and more words\n' "$(cut -d' ' -f1,2 "$TMP/client-cluster-a.pub") cluster-a" > "$BORG_REPO_SERVER_AUTHORIZED_KEYS"
  start
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(cat "$STAGED")" = "$(staged_line cluster-a cluster-a all)" ]
}

@test "comment lines and empty lines are skipped" {
  { echo "# the clients"; echo; cat "$TMP/client-cluster-a.pub"; } > "$BORG_REPO_SERVER_AUTHORIZED_KEYS"
  start
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(wc -l < "$STAGED" | tr -d ' ')" = "1" ]
}

@test "a file without a final newline is read completely" {
  printf '%s' "$(cat "$TMP/client-cluster-a.pub")" > "$BORG_REPO_SERVER_AUTHORIZED_KEYS"
  start
  [ "$status" -eq 0 ] || fail "$output"
  grep -q "$(key_blob cluster-a)" "$STAGED"
}

@test "a server without Borg 1 says so in every line" {
  export BORG_REPO_SERVER_BORG1=false
  start
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(cat "$STAGED")" = "$(staged_line cluster-a cluster-a all 2)" ]
}

# --- what is staged -----------------------------------------------------------

@test "what sshd checks with StrictModes is private to the user" {
  start
  [ "$(mode "$HOME_DIR")" = "700" ]
  [ "$(mode "$HOME_DIR/.ssh")" = "700" ]
  [ "$(mode "$STAGED")" = "600" ]
  [ "$(mode "$BORG_REPO_SERVER_RUN_DIR/hostkeys/ssh_host_key")" = "600" ]
}

@test "the data directory is private to the server's user afterwards" {
  chmod 0755 "$BORG_REPO_SERVER_ROOT"
  start
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(mode "$BORG_REPO_SERVER_ROOT")" = "700" ]
  [ "$(mode "$BORG_REPO_SERVER_ROOT/cluster-a")" = "700" ]
}

@test "sshd is started in the foreground with the staged host key" {
  start
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(argv_joined)" = "-D -e -f $BORG_REPO_SERVER_SSHD_CONFIG -p 2222 -h $BORG_REPO_SERVER_RUN_DIR/hostkeys/ssh_host_key -o AuthorizedKeysFile=$STAGED -o AllowUsers=borg " ]
}

@test "the server starts on a staged directory it cannot write" {
  run "$ROOTFS/prepare-repo-server.sh"
  [ "$status" -eq 0 ] || fail "$output"
  chmod -R a-w "$BORG_REPO_SERVER_RUN_DIR"
  run "$ROOTFS/run-repo-server.sh"
  chmod -R u+w "$BORG_REPO_SERVER_RUN_DIR"
  [ "$status" -eq 0 ] || fail "$output"
  [ -f "$TMP/argv" ]
}

@test "the server does not start on a directory nothing was staged into" {
  run "$ROOTFS/run-repo-server.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"did prepare-repo-server.sh run"* ]] || fail "$output"
  [ ! -f "$TMP/argv" ]
}

@test "the public host key is printed for the clients' known_hosts" {
  start
  [[ "$output" == *"Host key: $(cut -d' ' -f1,2 "$BORG_REPO_SERVER_HOST_KEY.pub")"* ]] || fail "$output"
}

@test "a host key that lost its final newline is still usable" {
  printf '%s' "$(cat "$BORG_REPO_SERVER_HOST_KEY")" > "$TMP/stripped"
  export BORG_REPO_SERVER_HOST_KEY="$TMP/stripped"
  start
  [ "$status" -eq 0 ] || fail "$output"
}

@test "a restart keeps the host key and does not double the keys" {
  start
  first="$(cksum < "$BORG_REPO_SERVER_RUN_DIR/hostkeys/ssh_host_key")"
  start
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(cksum < "$BORG_REPO_SERVER_RUN_DIR/hostkeys/ssh_host_key")" = "$first" ]
  [ "$(wc -l < "$STAGED" | tr -d ' ')" = "1" ]
}

# --- refusals -----------------------------------------------------------------

refused() {
  start
  [ "$status" -ne 0 ] || fail "started although it should not: $output"
  [ ! -f "$TMP/argv" ] || fail "sshd was started"
  [[ "$output" == *"$1"* ]] || fail "expected \"$1\" in: $output"
}

@test "a line carrying options is refused" {
  printf 'no-pty %s\n' "$(cat "$TMP/client-cluster-a.pub")" > "$BORG_REPO_SERVER_AUTHORIZED_KEYS"
  refused "options are not allowed"
}

@test "a forced command smuggled in with the key is refused" {
  printf 'command="/bin/sh" %s\n' "$(cat "$TMP/client-cluster-a.pub")" > "$BORG_REPO_SERVER_AUTHORIZED_KEYS"
  refused "options are not allowed"
}

@test "one bad line refuses the whole file" {
  add_key cluster-b
  echo 'command="/bin/sh" ssh-ed25519 AAAA x' >> "$BORG_REPO_SERVER_AUTHORIZED_KEYS"
  refused "line 3"
}

@test "a damaged public key is refused" {
  echo "ssh-ed25519 AAAAnotakey cluster-a" > "$BORG_REPO_SERVER_AUTHORIZED_KEYS"
  refused "invalid public key"
}

@test "a key without a comment is refused" {
  cut -d' ' -f1,2 "$TMP/client-cluster-a.pub" > "$BORG_REPO_SERVER_AUTHORIZED_KEYS"
  refused "the comment names the client"
}

@test "a comment that cannot be a directory name is refused" {
  for name in 'someone@somewhere' '../outside' '.hidden' '-rf' 'a/b' '$(id)'; do
    printf '%s %s\n' "$(cut -d' ' -f1,2 "$TMP/client-cluster-a.pub")" "$name" > "$BORG_REPO_SERVER_AUTHORIZED_KEYS"
    refused "does not name a client"
  done
}

@test "missing or empty authorized_keys is refused" {
  : > "$BORG_REPO_SERVER_AUTHORIZED_KEYS"
  refused "missing or empty"
  echo "# nobody" > "$BORG_REPO_SERVER_AUTHORIZED_KEYS"
  refused "no public key"
}

@test "a configured path that leaves the data directory is refused" {
  for path in ../outside cluster-a/../../outside /absolute . cluster-a/ 'a;b' '$(id)'; do
    printf 'cluster-a %s all\n' "$path" > "$BORG_REPO_SERVER_CLIENTS"
    refused "must be relative"
  done
}

@test "unknown permissions are refused" {
  configure cluster-a cluster-a everything
  refused "permissions"
}

@test "unknown default permissions are refused" {
  export BORG_REPO_SERVER_DEFAULT_PERMISSIONS=everything
  refused "default permissions"
}

@test "a client configured twice is refused" {
  configure cluster-a one all
  configure cluster-a two read-only
  refused "listed twice"
}

@test "a configured client without a key is refused" {
  # Most likely a typo — and then the key it was meant for would silently run
  # with the defaults.
  configure cluster-A cluster-a read-only
  refused "no key in"
}

@test "a host key that is none is refused" {
  echo "not a key" > "$BORG_REPO_SERVER_HOST_KEY"
  refused "not a usable private key"
}

@test "a missing host key is refused" {
  rm "$BORG_REPO_SERVER_HOST_KEY"
  refused "missing or empty"
}

@test "a uid without an account is refused" {
  printf 'root:x:0:0:root:/root:/bin/sh\n' > "$BORG_REPO_SERVER_PASSWD"
  refused "has no entry"
}

@test "a home directory outside the staged directory is refused" {
  printf 'borg:x:%s:%s:repo:/repos:/bin/sh\n' "$(id -u)" "$(id -g)" > "$BORG_REPO_SERVER_PASSWD"
  refused "home directory of borg must be"
}

@test "a data directory of another user is refused" {
  [ "$(id -u)" != "0" ] || skip "needs a directory that is not ours"
  export BORG_REPO_SERVER_ROOT=/usr
  refused "belongs to uid 0"
}

@test "a missing data directory is refused" {
  export BORG_REPO_SERVER_ROOT="$TMP/nowhere"
  refused "does not exist"
}

@test "a data directory with a space in its name is refused" {
  mkdir -p "$TMP/my repos"
  export BORG_REPO_SERVER_ROOT="$TMP/my repos"
  refused "absolute path"
}
