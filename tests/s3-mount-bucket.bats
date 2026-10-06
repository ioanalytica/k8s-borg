#!/usr/bin/env bats
#
# `s3-mount-bucket`: the s3fs options (region or not), and that a bucket which
# does not answer stops the start instead of leaving a mount behind that blocks
# its first reader. s3fs, ls, umount and pkill are stubs here; the behaviour of
# the real s3fs against a server that checks the region is described in the
# script's header.

bats_require_minimum_version 1.5.0

setup() {
  load helpers/common
  common_setup
  mkdir -p "$TMP/stubs"
  PATH="$TMP/stubs:$BIN:$PATH"
  export S3_ENDPOINT=http://s3.example:3900 S3_MOUNTPOINT="$TMP/s3" \
         S3FS_PASSWD_FILE="$TMP/passwd" S3_PROBE_TIMEOUT=1
  unset S3_REGION
  make_stubs ok
}

teardown() {
  # A hanging listing that the script failed to end would keep bats waiting.
  [ -f "$TMP/ls.pid" ] && kill -KILL "$(cat "$TMP/ls.pid")" 2>/dev/null
  common_teardown
}

# make_stubs LISTING — s3fs records its argv; ls answers "ok", fails with
# "fail", or blocks with "hang"; umount and pkill record their arguments.
make_stubs() {
  cat >"$TMP/stubs/s3fs" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TMP/s3fs.argv"
exit \${FAKE_S3FS_RC:-0}
EOF
  case "$1" in
    ok)   body='exit 0' ;;
    fail) body='echo "ls: $2: Input/output error" >&2; exit 1' ;;
    hang) body="echo \$\$ > '$TMP/ls.pid'; exec sleep 20" ;;
  esac
  printf '#!/usr/bin/env bash\necho ls >> "%s/calls"\n%s\n' "$TMP" "$body" >"$TMP/stubs/ls"
  for cmd in umount pkill; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/calls"\n' "$cmd" "$TMP" >"$TMP/stubs/$cmd"
  done
  chmod +x "$TMP/stubs/"*
}

s3fs_options() { sed -n 4p "$TMP/s3fs.argv"; }
called() { grep -qxF -- "$1" "$TMP/calls" 2>/dev/null; }

@test "without a region the options are the ones s3fs got before" {
  run "$BIN/s3-mount-bucket" pg-backups
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(sed -n 1,3p "$TMP/s3fs.argv" | tr '\n' ' ')" = "pg-backups $TMP/s3/pg-backups -o " ] \
    || fail "$(cat "$TMP/s3fs.argv")"
  [ "$(s3fs_options)" = "passwd_file=$TMP/passwd,use_path_request_style,listobjectsv2,url=http://s3.example:3900" ] \
    || fail "$(s3fs_options)"
  [ -d "$TMP/s3/pg-backups" ] || fail "mountpoint not created"
}

@test "an empty region is the same as none" {
  S3_REGION= run "$BIN/s3-mount-bucket" pg-backups
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [[ "$(s3fs_options)" != *endpoint=* ]] || fail "$(s3fs_options)"
}

@test "a region goes to s3fs as endpoint=" {
  S3_REGION=eu-central-1 run "$BIN/s3-mount-bucket" pg-backups
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [[ "$(s3fs_options)" == *",url=http://s3.example:3900,endpoint=eu-central-1" ]] || fail "$(s3fs_options)"
  [[ "$(s3fs_options)" != *region=* ]] || fail "s3fs has no region= option: $(s3fs_options)"
}

@test "a bucket that answers is left mounted" {
  run "$BIN/s3-mount-bucket" pg-backups
  [ "$status" -eq 0 ] || fail "status $status: $output"
  called ls || fail "no listing"
  ! grep -qE '^(umount|pkill)' "$TMP/calls" || fail "cleaned up a good mount: $(cat "$TMP/calls")"
}

@test "a listing that fails stops the start, names the bucket and quotes the error" {
  make_stubs fail
  S3_REGION=eu-central-1 run --separate-stderr "$BIN/s3-mount-bucket" pg-backups
  [ "$status" -eq 1 ] || fail "status $status"
  [[ "$stderr" == "FATAL: S3 bucket 'pg-backups' at http://s3.example:3900, region eu-central-1 cannot be listed: "*"Input/output error"* ]] \
    || fail "$stderr"
}

@test "a listing that does not come back stops the start within the time limit" {
  make_stubs hang
  SECONDS=0
  run --separate-stderr "$BIN/s3-mount-bucket" pg-backups
  [ "$status" -eq 1 ] || fail "status $status"
  [ "$SECONDS" -le 5 ] || fail "took ${SECONDS}s"
  [[ "$stderr" == *"'pg-backups'"*"did not answer within 1s"* ]] || fail "$stderr"
  [[ "$stderr" == *"region us-east-1 (s3fs default, s3.region empty)"* ]] || fail "$stderr"
  ! kill -0 "$(cat "$TMP/ls.pid")" 2>/dev/null || fail "the listing is still running"
}

@test "a failed mount is aborted, s3fs ended and the mount detached, in that order" {
  make_stubs hang
  run "$BIN/s3-mount-bucket" pg-backups
  [ "$status" -eq 1 ] || fail "status $status"
  expected="ls
umount -f $TMP/s3/pg-backups
pkill -KILL -f ^s3fs pg-backups $TMP/s3/pg-backups( |\$)
umount -l $TMP/s3/pg-backups"
  [ "$(cat "$TMP/calls")" = "$expected" ] || fail "$(cat "$TMP/calls")"
}

@test "an s3fs that refuses to mount stops the start before any listing" {
  FAKE_S3FS_RC=1 run "$BIN/s3-mount-bucket" pg-backups
  [ "$status" -ne 0 ] || fail "status $status"
  ! called ls || fail "listed a mount that s3fs refused"
}

@test "a time limit that is not a positive number is refused before s3fs runs" {
  for value in 0 -1 abc 1.5; do
    S3_PROBE_TIMEOUT=$value run --separate-stderr "$BIN/s3-mount-bucket" pg-backups
    [ "$status" -eq 1 ] || fail "$value: status $status"
    [[ "$stderr" == *"S3_PROBE_TIMEOUT"* ]] || fail "$value: $stderr"
    [ ! -f "$TMP/s3fs.argv" ] || fail "$value: s3fs ran"
  done
}
