# shellcheck shell=bash
#
# Shared by the database tests. run.sh starts the servers of one version on a
# network of their own, reachable as `src` (seeded, dumped), `dst` (empty, for
# the restore of the whole instance) and `dst2` (empty, for the other
# restores into a fresh server); DB_PASSWORD is the password of each server's
# administrator, DB_VERSION the server version.

fail() { printf '%s\n' "$*" >&2; return 1; }

# wait_for SECONDS COMMAND… — retry COMMAND once a second until it succeeds,
# for SECONDS of wall time: a try that itself takes seconds (a client's
# connect timeout) does not stretch the wait.
wait_for() {
  local seconds=$1 end=$((SECONDS + $1))
  shift
  until "$@" >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$end" ] || { fail "not ready after ${seconds}s: $*"; return; }
    sleep 1
  done
}

# mode_of FILE — the permission bits, e.g. 600.
mode_of() { stat -c %a "$1"; }

# assert_same EXPECTED ACTUAL — two files with the same content, or the diff.
assert_same() {
  diff -u "$1" "$2" >&2 || fail "$2 differs from $1"
}

# assert_dump_dir DIR NAME… — DIR holds exactly the files NAME…, each mode 600.
assert_dump_dir() {
  local dir=$1 file
  shift
  [ "$(cd "$dir" && ls -1 | LC_ALL=C sort)" = "$(printf '%s\n' "$@" | LC_ALL=C sort)" ] \
    || fail "$dir holds: $(cd "$dir" && ls -1 | tr '\n' ' '), expected: $*"
  for file in "$@"; do
    [ "$(mode_of "$dir/$file")" = 600 ] || fail "$dir/$file has mode $(mode_of "$dir/$file"), not 600"
  done
}

# Borg 1, the chart's default, with the compression borg-backup uses. The
# dumps go through a real archive before anything is restored from them.
export BORG_VERSION=1

# borg_create REPO ARCHIVE DIR — archive DIR; prints the archive's
# deduplicated size, i.e. what it added to the repository.
borg_create() {
  [ -d "$1" ] || borg init --encryption=none "$1" >/dev/null
  borg create --json --compression auto,lz4 "$1::$2" "$3" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["archive"]["stats"]["deduplicated_size"])'
}

# borg_extract REPO ARCHIVE DIR — extract the archive below DIR (which Borg 1
# does with the archived path, its leading / removed).
borg_extract() {
  mkdir -p "$3"
  (cd "$3" && borg extract "$1::$2")
}
