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
        BORG1_DEFAULT_PARAMS BORG2_DEFAULT_PARAMS S3_ENABLED \
        BORG_REPO BORG_ENCRYPTION
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

# make_fake_borg2 VERSION [RC] — a stub that answers `--version` like a Borg of
# that version and otherwise behaves like make_fake_borg. The version probe is
# counted in $TMP/probes and leaves $TMP/argv alone, so that a test can tell
# whether the wrapper asked, and whether Borg ran after it. It also records the
# BORG_REMOTE_PATH it was started with. VERSION "" makes the probe fail.
make_fake_borg2() {
  local version="${1:-}" rc="${2:-0}"
  rm -f "$TMP/argv" "$TMP/probes" "$TMP/remote-path"
  cat >"$TMP/fake-borg" <<EOF
#!/usr/bin/env bash
if [ "\$*" = "--version" ]; then
  echo probe >> "$TMP/probes"
  [ -n "$version" ] || exit 2
  echo "borg $version"
  exit 0
fi
printf '%s\n' "\$@" > "$TMP/argv"
printf '%s' "\${BORG_REMOTE_PATH-unset}" > "$TMP/remote-path"
exit $rc
EOF
  chmod +x "$TMP/fake-borg"
}

# probes — how often the wrapper asked the stub for its version.
probes() { if [ -f "$TMP/probes" ]; then grep -c . "$TMP/probes"; else echo 0; fi; }

# borg_ran — succeed iff the stub was started for anything but its version.
borg_ran() { [ -f "$TMP/argv" ]; }

# argv_line N — the Nth argument the fake borg received (1-based).
argv_line() { sed -n "${1}p" "$TMP/argv"; }

# argv_joined — all arguments on one line, for whole-command assertions.
argv_joined() { tr '\n' ' ' <"$TMP/argv"; }
