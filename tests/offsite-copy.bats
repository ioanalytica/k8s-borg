#!/usr/bin/env bats
#
# borg-offsite-copy mirrors the repositories below the repository server's data
# directory to an rclone remote. rclone is a stub here that records every call;
# what rclone itself does with them is the end-to-end suite's business
# (e2e/repo-server-offsite.bats). Pinned here: which directories count as
# repositories, the order of the three passes and their filters, that a
# repository that changed or was locked during the copy is not taken as copied,
# and that nothing is ever deleted on the remote for a repository that does not
# exist locally.

bats_require_minimum_version 1.5.0

setup() {
  load helpers/common
  common_setup
  DATA="$TMP/repos"
  mkdir -p "$DATA"
  # The stub logs one line per call, its arguments joined by "|", and then runs
  # $TMP/hook if there is one: the hook plays the client that writes while the
  # copy runs. An existing $TMP/rclone-fails makes every call fail.
  cat >"$TMP/rclone" <<STUB
#!/usr/bin/env bash
(IFS='|'; echo "\$*") >> "$TMP/calls"
[ -x "$TMP/hook" ] && "$TMP/hook"
[ ! -e "$TMP/rclone-fails" ]
STUB
  chmod +x "$TMP/rclone"
  : >"$TMP/calls"
  export BORG_OFFSITE_SOURCE="$DATA" BORG_OFFSITE_TARGET="offsite:k8s-borg" \
         BORG_OFFSITE_RCLONE="$TMP/rclone" BORG_OFFSITE_RETRIES=3 BORG_OFFSITE_RETRY_DELAY=0
}

teardown() { common_teardown; }

# borg1_repository PATH / borg2_repository PATH — what each major leaves on disk,
# as far as the job looks at it.
borg1_repository() {
  mkdir -p "$DATA/$1/data/0"
  printf 'This is a Borg Backup repository.\nSee https://borgbackup.readthedocs.io/\n' >"$DATA/$1/README"
  echo "[repository]" >"$DATA/$1/config"
  echo segment >"$DATA/$1/data/0/1"
  echo index >"$DATA/$1/index.1"
}

borg2_repository() {
  mkdir -p "$DATA/$1/packs/00" "$DATA/$1/archives" "$DATA/$1/index" "$DATA/$1/config" "$DATA/$1/locks"
  echo pack >"$DATA/$1/packs/00/aa"
  echo config >"$DATA/$1/config/config"
}

copy() { run --separate-stderr "$BIN/borg-offsite-copy" "$@"; }

# calls_for DEST — the recorded calls for one destination.
calls_for() { grep -F "|$1|" "$TMP/calls" || true; }

LOCKS='--filter|- /lock.roster|--filter|- /lock.exclusive/**|--filter|- /locks/**'

# --- what is copied, and how ---------------------------------------------------

@test "a Borg 1 repository is copied data first, then the rest, then synced" {
  borg1_repository cluster-a/node01
  copy
  [ "$status" -eq 0 ] || fail "$output $stderr"
  local src="$DATA/cluster-a/node01" dest="offsite:k8s-borg/cluster-a/node01"
  [ "$(cat "$TMP/calls")" = "copy|$src|$dest|$LOCKS|--filter|+ /data/**|--filter|- **
copy|$src|$dest|$LOCKS|--filter|- /data/**
sync|$src|$dest|$LOCKS" ] || fail "$(cat "$TMP/calls")"
  [[ "$output" == *"cluster-a/node01: copied (Borg 1, attempt 1)"* ]]
}

@test "a Borg 2 repository is copied packs first, then the rest, then synced" {
  borg2_repository cluster-a/node01
  copy
  [ "$status" -eq 0 ] || fail "$output $stderr"
  local src="$DATA/cluster-a/node01" dest="offsite:k8s-borg/cluster-a/node01"
  [ "$(cat "$TMP/calls")" = "copy|$src|$dest|$LOCKS|--filter|+ /packs/**|--filter|- **
copy|$src|$dest|$LOCKS|--filter|- /packs/**
sync|$src|$dest|$LOCKS" ] || fail "$(cat "$TMP/calls")"
}

@test "repositories are found at any depth, and nothing below a repository is searched" {
  borg1_repository a/one
  borg2_repository b/nested/deep/two
  borg2_repository b/nested/deep/two/packs/inner   # inside a repository: not one of its own
  mkdir -p "$DATA/c/not-a-repository/data"
  copy
  [ "$status" -eq 0 ] || fail "$output $stderr"
  [ "$(cut -d'|' -f3 "$TMP/calls" | sort -u)" = "offsite:k8s-borg/a/one
offsite:k8s-borg/b/nested/deep/two" ] || fail "$(cat "$TMP/calls")"
  [[ "$output" == *"all 2 repositories copied"* ]]
}

@test "a directory with a README that is not Borg's is not a Borg 1 repository" {
  mkdir -p "$DATA/x/data"
  echo "[repository]" >"$DATA/x/config"
  echo "Something else." >"$DATA/x/README"
  copy
  [ "$status" -eq 0 ]
  [ ! -s "$TMP/calls" ]
}

@test "a symlinked directory is not followed" {
  borg2_repository real/repo
  mkdir -p "$TMP/outside"
  borg2_repository real/elsewhere
  mv "$DATA/real/elsewhere" "$TMP/outside/repo"
  ln -s "$TMP/outside" "$DATA/link"
  copy
  [ "$status" -eq 0 ] || fail "$output $stderr"
  [ -z "$(calls_for offsite:k8s-borg/link/repo)" ] || fail "followed the symlink: $(cat "$TMP/calls")"
  [ -n "$(calls_for offsite:k8s-borg/real/repo)" ]
}

@test "rclone options reach every call" {
  borg2_repository r
  copy --transfers=8 "--bwlimit=08:00,2M 20:00,off"
  [ "$status" -eq 0 ] || fail "$output $stderr"
  [ "$(grep -c -- '|--transfers=8|--bwlimit=08:00,2M 20:00,off$' "$TMP/calls")" -eq 3 ] || fail "$(cat "$TMP/calls")"
}

@test "a target that is a bare remote takes the paths as they are" {
  borg2_repository cluster-a/r
  BORG_OFFSITE_TARGET="box:" copy
  [ "$status" -eq 0 ] || fail "$output $stderr"
  [ -n "$(calls_for box:cluster-a/r)" ] || fail "$(cat "$TMP/calls")"
}

@test "a trailing slash on the target does not double" {
  borg2_repository cluster-a/r
  BORG_OFFSITE_TARGET="offsite:bucket/k8s-borg/" copy
  [ "$status" -eq 0 ] || fail "$output $stderr"
  [ -n "$(calls_for offsite:bucket/k8s-borg/cluster-a/r)" ] || fail "$(cat "$TMP/calls")"
}

# --- consistency ---------------------------------------------------------------

@test "a repository a client writes to during the copy is copied again" {
  borg2_repository r
  # The first call of the first attempt sees a new pack appear.
  cat >"$TMP/hook" <<HOOK
#!/usr/bin/env bash
[ -e "$TMP/written" ] && exit 0
touch "$TMP/written"
echo new >"$DATA/r/packs/00/bb"
HOOK
  chmod +x "$TMP/hook"
  copy
  [ "$status" -eq 0 ] || fail "$output $stderr"
  [ "$(wc -l <"$TMP/calls" | tr -d ' ')" -eq 6 ] || fail "$(cat "$TMP/calls")"
  [[ "$output" == *"r: changed during the copy (attempt 1 of 3)"* ]]
  [[ "$output" == *"r: copied (Borg 2, attempt 2)"* ]]
}

@test "a repository that keeps changing fails the run, the others are still copied" {
  borg2_repository busy
  borg2_repository quiet
  cat >"$TMP/hook" <<HOOK
#!/usr/bin/env bash
date +%s%N >"$DATA/busy/packs/00/\$RANDOM"
HOOK
  chmod +x "$TMP/hook"
  copy
  [ "$status" -eq 1 ]
  [[ "$output" == *"busy: changed during the copy (attempt 3 of 3)"* ]]
  [[ "$output" == *"busy: NOT copied"* ]]
  [[ "$output" == *"quiet: copied"* ]]
  [[ "$output" == *"1 of 2 repositories not copied: busy"* ]]
}

@test "a Borg 1 repository held by a client is not copied" {
  borg1_repository locked
  mkdir "$DATA/locked/lock.exclusive"
  copy
  [ "$status" -eq 1 ]
  [ ! -s "$TMP/calls" ] || fail "copied while locked: $(cat "$TMP/calls")"
  [[ "$output" == *"locked: locked by a client (attempt 3 of 3)"* ]]
}

@test "a Borg 2 repository with a lock object is not copied" {
  borg2_repository locked
  echo sealed >"$DATA/locked/locks/0123"
  copy
  [ "$status" -eq 1 ]
  [ ! -s "$TMP/calls" ] || fail "copied while locked: $(cat "$TMP/calls")"
}

@test "a client still holding a lock when the copy ends makes it count as not copied" {
  borg2_repository r
  # Taken during the first pass and not released: a write may still follow.
  cat >"$TMP/hook" <<HOOK
#!/usr/bin/env bash
echo sealed >"$DATA/r/locks/0123"
HOOK
  chmod +x "$TMP/hook"
  BORG_OFFSITE_RETRIES=1 copy
  [ "$status" -eq 1 ] || fail "$output"
  [[ "$output" == *"r: changed during the copy"* ]]
}

@test "a lock that came and went without a write does not matter" {
  # A client that only read: the copy is what it would have been without it.
  borg2_repository r
  cat >"$TMP/hook" <<HOOK
#!/usr/bin/env bash
echo x >>"$TMP/n"
case \$(wc -l <"$TMP/n" | tr -d ' ') in
  1) echo sealed >"$DATA/r/locks/0123" ;;
  2) rm "$DATA/r/locks/0123" ;;
esac
HOOK
  chmod +x "$TMP/hook"
  BORG_OFFSITE_RETRIES=1 copy
  [ "$status" -eq 0 ] || fail "$output"
}

@test "an rclone failure is retried, and fails the run when it persists" {
  borg2_repository r
  touch "$TMP/rclone-fails"
  copy
  [ "$status" -eq 1 ]
  # One call per attempt: the later passes do not run after a failed one.
  [ "$(wc -l <"$TMP/calls" | tr -d ' ')" -eq 3 ] || fail "$(cat "$TMP/calls")"
  [[ "$output" == *"r: rclone failed (attempt 3 of 3)"* ]]
}

# --- nothing is ever lost on the remote -----------------------------------------

@test "an empty data directory copies nothing and deletes nothing" {
  copy
  [ "$status" -eq 0 ] || fail "$output $stderr"
  [ ! -s "$TMP/calls" ]
  [[ "$output" == *"no repository below $DATA"* ]]
}

@test "a missing data directory stops the job before rclone runs" {
  BORG_OFFSITE_SOURCE="$TMP/not-mounted" copy
  [ "$status" -eq 2 ]
  [ ! -s "$TMP/calls" ]
  [[ "$stderr" == *"data directory $TMP/not-mounted does not exist"* ]]
}

# --- configuration ---------------------------------------------------------------

@test "the job refuses to start without a target, or with one that is no rclone remote" {
  borg2_repository r
  BORG_OFFSITE_TARGET="" copy
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"BORG_OFFSITE_TARGET is not set"* ]]
  BORG_OFFSITE_TARGET="/tmp/copy" copy
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"is not an rclone remote"* ]]
  [ ! -s "$TMP/calls" ]
}

@test "retries and their delay must be numbers" {
  BORG_OFFSITE_RETRIES=0 copy
  [ "$status" -eq 2 ]
  BORG_OFFSITE_RETRY_DELAY=soon copy
  [ "$status" -eq 2 ]
}
