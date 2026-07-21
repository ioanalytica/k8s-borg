# shellcheck shell=bash
#
# Shared bats setup: locate the rootfs in the checkout, point the wrappers at it
# via BORG_LIB_DIR/BORG_BIN_DIR, and provide a fake borg binary.

ROOTFS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/docker/rootfs"
BIN="$ROOTFS/usr/local/bin"
export BORG_LIB_DIR="$ROOTFS/usr/local/lib"
export BORG_BIN_DIR="$BIN"

# Every test gets a clean environment: the wrappers read a lot of BORG_* env, and
# a leaked value from the shell running the tests would silently change behaviour.
common_setup() {
  TMP="$(mktemp -d)"
  unset BORG_VERSION BORG_REMOTE_PATH BORG_TREAT_WARNINGS_AS_ERRORS \
        BORG1_DEFAULT_PARAMS BORG2_DEFAULT_PARAMS S3_ENABLED
  export BORG1_BINARY="$TMP/fake-borg" BORG2_BINARY="$TMP/fake-borg"
}

common_teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

# fail MESSAGE — bats-core has no assertion library bundled; this is the one
# helper the tests need beyond plain [ ] checks.
fail() { printf '%s\n' "$*" >&2; return 1; }

# make_fake_borg RC [STDOUT] [STDERR] — install a stub in place of the real borg
# binary. It records its argv one-per-line in $TMP/argv so tests can assert on
# what the wrapper actually passed through.
#
# The payloads go through files, never into the generated script text: a JSON
# payload contains double quotes and would otherwise break the stub's quoting.
make_fake_borg() {
  local rc="${1:-0}"
  printf '%s' "${2:-}" >"$TMP/out"
  printf '%s' "${3:-}" >"$TMP/err"
  cat >"$TMP/fake-borg" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TMP/argv"
cat "$TMP/out"
cat "$TMP/err" >&2
exit $rc
EOF
  chmod +x "$TMP/fake-borg"
}

# argv_line N — the Nth argument the fake borg received (1-based).
argv_line() { sed -n "${1}p" "$TMP/argv"; }

# argv_joined — all arguments on one line, for whole-command assertions.
argv_joined() { tr '\n' ' ' <"$TMP/argv"; }
