#!/usr/bin/env bats
#
# `borg-mount`: the exit code is Borg's, not the one of the closing message.
# For Borg 2 it runs the mount in the foreground and puts it into the
# background itself; `mountpoint` is a stub here that answers by a marker file
# the fake Borg creates. Whether a mount works is part of tests/e2e, which has
# FUSE.

bats_require_minimum_version 1.5.0

setup_file() {
  # A Borg 2 mount that kept the descriptors of `run` would hang the test.
  export BATS_TEST_TIMEOUT=60
}

setup() {
  load helpers/common
  common_setup
  mkdir -p "$TMP/bin"
  PATH="$TMP/bin:$BIN:$PATH"
  export BORG_REPO=ssh://user@host/repo
  cat >"$TMP/bin/mountpoint" <<EOF
#!/usr/bin/env bash
[ -e "$TMP/mounted" ]
EOF
  chmod +x "$TMP/bin/mountpoint"
  # macOS has no setsid(1); CI and the image do.
  if ! command -v setsid >/dev/null; then
    cat >"$TMP/bin/setsid" <<'EOF'
#!/usr/bin/env perl
use POSIX ();
POSIX::setsid();
exec @ARGV or die "setsid: $ARGV[0]: $!\n";
EOF
    chmod +x "$TMP/bin/setsid"
  fi
}

teardown() {
  # Only the fake Borg this test started.
  if [ -f "$TMP/pid" ]; then
    kill "$(cat "$TMP/pid")" 2>/dev/null || true
  fi
  common_teardown
}

# make_mounting_borg mount|hang — a fake Borg 2 that writes to both streams and
# then stays until the unmount ($TMP/unmounted), like `borg mount -f`. With
# "mount" it mounts first ($TMP/mounted); with "hang" it never does. It records
# its argv, its pid and its process group.
make_mounting_borg() {
  cat >"$TMP/fake-borg" <<EOF
#!/usr/bin/env bash
if [ "\$*" = "--version" ]; then echo "borg 2.0.0b25"; exit 0; fi
printf '%s\n' "\$@" >"$TMP/argv"
echo "\$\$" >"$TMP/pid"
ps -o pgid= -p "\$\$" | tr -d ' ' >"$TMP/pgid"
echo "from borg on stdout"
echo "from borg on stderr" >&2
[ "$1" = hang ] || touch "$TMP/mounted"
while [ ! -e "$TMP/unmounted" ]; do sleep 0.1; done
rm -f "$TMP/mounted"
EOF
  chmod +x "$TMP/fake-borg"
}

fake_alive() { kill -0 "$(cat "$TMP/pid")" 2>/dev/null; }

@test "a failed mount ends with Borg's exit code and says so on stderr" {
  for version in 1 2; do
    make_fake_borg 13 "out of borg" "err of borg"
    BORG_VERSION=$version run --separate-stderr "$BIN/borg-mount" archive
    [ "$status" -eq 13 ] || fail "borg $version: status $status"
    [[ "$stderr" == *"failed"* ]] || fail "borg $version: $stderr"
    [[ "$stderr" == *"err of borg"* ]] || fail "borg $version: stderr: $stderr"
    [[ "$output" == *"out of borg"* ]] || fail "borg $version: stdout: $output"
    [[ "$output" != *"err of borg"* ]] || fail "borg $version: stderr on stdout: $output"
    [[ "$output" != *"successfully mounted"* ]] || fail "borg $version: $output"
  done
}

@test "a Borg 1 mount ends with 0" {
  make_fake_borg 0
  BORG_VERSION=1 run "$BIN/borg-mount" archive
  [ "$status" -eq 0 ] || fail "status $status"
  [[ "$output" == *"successfully mounted"* ]] || fail "$output"
  [ "$(argv_joined)" = "mount ssh://user@host/repo::archive /mnt/borg " ] || fail "$(argv_joined)"
}

@test "a Borg 1 warning that the wrapper hands on still counts as mounted" {
  make_fake_borg 1
  BORG_VERSION=1 BORG_TREAT_WARNINGS_AS_ERRORS=true run "$BIN/borg-mount" archive
  [ "$status" -eq 0 ] || fail "status $status"
  [[ "$output" == *"successfully mounted"* ]] || fail "$output"
}

@test "Borg 2 mounts in the foreground of a session of its own, and borg-mount returns once it is mounted" {
  make_mounting_borg mount
  BORG_VERSION=2 run --separate-stderr "$BIN/borg-mount" archive
  [ "$status" -eq 0 ] || fail "status $status: $stderr"
  [[ "$output" == *"successfully mounted"* ]] || fail "$output"
  [ "$(argv_joined)" = "mount -f -a archive /mnt/borg " ] || fail "$(argv_joined)"
  # What Borg wrote until the mount was there, each stream on its own.
  [[ "$output" == *"from borg on stdout"* ]] || fail "stdout: $output"
  [[ "$stderr" == *"from borg on stderr"* ]] || fail "stderr: $stderr"
  [[ "$output" != *"on stderr"* ]] || fail "stderr on stdout: $output"
  fake_alive || fail "the mount did not outlive borg-mount"
  [ "$(cat "$TMP/pgid")" != "$(ps -o pgid= -p $$ | tr -d ' ')" ] \
    || fail "the mount runs in the process group of its caller"
  # The unmount ends it.
  touch "$TMP/unmounted"
  for _ in $(seq 1 50); do fake_alive || break; sleep 0.1; done
  ! fake_alive || fail "the mount process is left after the unmount"
}

@test "a Borg 2 mount that ends without mounting fails, also with 0 or a warning" {
  for rc in 0 100; do
    make_fake_borg "$rc"
    BORG_VERSION=2 BORG_TREAT_WARNINGS_AS_ERRORS=true run --separate-stderr "$BIN/borg-mount" archive
    expected=$rc; [ "$rc" -ne 0 ] || expected=1
    [ "$status" -eq "$expected" ] || fail "rc $rc: status $status"
    [[ "$stderr" == *"ended without mounting"* ]] || fail "rc $rc: $stderr"
    [[ "$output" != *"successfully mounted"* ]] || fail "rc $rc: $output"
  done
}

@test "a Borg 2 mount that does not come up in time is ended" {
  make_mounting_borg hang
  BORG_VERSION=2 BORG_MOUNT_TIMEOUT=1 run --separate-stderr "$BIN/borg-mount" archive
  [ "$status" -eq 2 ] || fail "status $status"
  [[ "$stderr" == *"within 1s"*"BORG_MOUNT_TIMEOUT"* ]] || fail "$stderr"
  [[ "$stderr" == *"failed"* ]] || fail "$stderr"
  [[ "$output" != *"successfully mounted"* ]] || fail "$output"
  for _ in $(seq 1 20); do fake_alive || break; sleep 0.1; done
  ! fake_alive || fail "the mount process was not ended"
}

@test "Borg 2 does not mount over a mount that is there already" {
  make_mounting_borg mount
  touch "$TMP/mounted"
  BORG_VERSION=2 run --separate-stderr "$BIN/borg-mount" archive
  [ "$status" -eq 2 ] || fail "status $status"
  [[ "$stderr" == *"mounted already"* ]] || fail "$stderr"
  ! borg_ran || fail "borg ran: $(argv_joined)"
}
