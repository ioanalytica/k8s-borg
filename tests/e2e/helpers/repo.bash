# shellcheck shell=bash
#
# Setup for the end-to-end tests: a throwaway Borg repository on the container's
# own filesystem, plus the pattern files borg-backup expects.
#
# One suite, both Borg majors: BORG_TEST_VERSION selects which one, and run.sh
# runs the suite twice. The scripts under test branch on BORG_VERSION, so this
# is the one knob that has to differ.

e2e_setup() {
  export BORG_VERSION="${BORG_TEST_VERSION:-1}"
  export BORG_PASSPHRASE=e2e-test-passphrase
  export NODE_NAME=e2e-node
  export BORG_MODE=cluster

  TMP="$(mktemp -d)"
  SRC="$TMP/src"

  # Borg 2 addresses a local repository through the posixfs backend, i.e. a
  # file:// URL; Borg 1 takes a plain path.
  if [ "$BORG_VERSION" = "2" ]; then
    export BORG_REPO="file://$TMP/repo"
  else
    export BORG_REPO="$TMP/repo"
  fi

  mkdir -p "$SRC/nested"
  echo "hello from the e2e suite" >"$SRC/hello.txt"
  echo "nested payload" >"$SRC/nested/deep.txt"

  write_patterns "R $SRC"
}

e2e_teardown() {
  # A failed mount test must not leave the next test wedged on a dead mountpoint.
  if mountpoint -q /mnt/borg 2>/dev/null; then
    borg umount /mnt/borg 2>/dev/null || umount /mnt/borg 2>/dev/null || true
  fi
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
  return 0
}

# archive_ref NAME — how a single archive is addressed on the command line.
# Borg 2 dropped REPO::ARCHIVE and takes a bare name with the repo from the env;
# Borg 1 wants the qualified form. The scripts under test do the same branch,
# so the tests cannot simply hardcode one of them.
archive_ref() {
  if [ "$BORG_VERSION" = "2" ]; then printf '%s' "$1"; else printf '%s::%s' "$BORG_REPO" "$1"; fi
}

# write_patterns [LINE...] — borg-backup reads these from fixed paths under
# /root/.borg (the chart mounts them from a ConfigMap). Called with no arguments
# it writes a file with only a comment, which is the "operator configured no
# source roots" case.
write_patterns() {
  mkdir -p /root/.borg
  {
    echo "# written by the e2e suite"
    for line in "$@"; do echo "$line"; done
  } >"/root/.borg/${BORG_MODE}-include.patterns"
  echo "# no excludes" >"/root/.borg/${BORG_MODE}-exclude.patterns"
}

# archive_names — one archive NAME per line. Borg 1's --short prints names, but
# Borg 2's repo-list --short prints archive IDs, so ask for the name explicitly.
archive_names() {
  if [ "$BORG_VERSION" = "2" ]; then
    borg-list --format '{archive}{NL}' 2>/dev/null
  else
    borg-list --short 2>/dev/null
  fi
}

archive_count() { archive_names | grep -c . || true; }

# first_archive — name of the oldest archive, for commands that take one.
first_archive() { archive_names | head -1; }

# mounted_path PATH — where an archived absolute path shows up under /mnt/borg.
# Borg 1 mounts one archive at the root; Borg 2 selects with -a and gives each
# matched archive its own subdirectory.
mounted_path() {
  if [ "$BORG_VERSION" = "2" ]; then
    printf '/mnt/borg/%s%s' "$(first_archive)" "$1"
  else
    printf '/mnt/borg%s' "$1"
  fi
}

fail() { printf '%s\n' "$*" >&2; return 1; }

# The image's own exit-code helpers, so a test can classify a real borg failure
# the same way the scripts do.
# shellcheck source=/dev/null
. /usr/local/lib/borg-rc.sh
