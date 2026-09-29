#!/usr/bin/env bats
#
# borg-repo-serve is the forced command behind every client key of the
# repository server. It decides whether Borg is started at all, and which one;
# which path is served, and with which rights, is pinned by its arguments.

bats_require_minimum_version 1.5.0   # run --separate-stderr

setup() {
  load helpers/common
  common_setup
  ROOT_DIR="$TMP/repos"
  mkdir -p "$ROOT_DIR/cluster-a"
  # One stub per major. Each records argv, the directory it was started in and
  # where Borg would keep its own files.
  for major in 1 2; do
    cat >"$TMP/fake-borg$major" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TMP/argv"
echo $major > "$TMP/major"
pwd -P > "$TMP/cwd"
printf '%s' "\${BORG_BASE_DIR:-}" > "$TMP/base-dir"
echo "protocol"
STUB
    chmod +x "$TMP/fake-borg$major"
  done
  export BORG1_BINARY="$TMP/fake-borg1" BORG2_BINARY="$TMP/fake-borg2"
  unset SSH_ORIGINAL_COMMAND
  BORG2_REQUEST="borg serve --rest --backend FILE:cluster-a/node01"
  BORG1_REQUEST="borg serve --umask=077"
}

teardown() { common_teardown; }

# serve [PERMISSIONS [MODES]]
serve() { run --separate-stderr "$BIN/borg-repo-serve" "$ROOT_DIR" cluster-a "${1:-all}" "${2:-1,2}"; }

started() { [ -f "$TMP/argv" ]; }

# --- Borg 2 -------------------------------------------------------------------

@test "a Borg 2 request starts Borg 2 with the pinned restriction and permissions" {
  export SSH_ORIGINAL_COMMAND="$BORG2_REQUEST"
  serve no-delete
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/major")" = "2" ]
  [ "$(argv_joined)" = "serve --rest --restrict-to-path $ROOT_DIR/cluster-a --permissions no-delete " ]
}

@test "Borg starts in the data directory, so relative repository paths resolve below it" {
  export SSH_ORIGINAL_COMMAND="$BORG2_REQUEST"
  serve
  [ "$(cat "$TMP/cwd")" = "$(cd "$ROOT_DIR" && pwd -P)" ]
}

@test "Borg keeps its own files out of the read-only home directory" {
  export SSH_ORIGINAL_COMMAND="$BORG2_REQUEST"
  serve
  [ "$(cat "$TMP/base-dir")" = "/tmp/borg" ]
}

@test "the client's own options never reach Borg's command line" {
  # Borg reads them from SSH_ORIGINAL_COMMAND and takes only what it allows.
  export SSH_ORIGINAL_COMMAND="borg serve --rest --permissions all --restrict-to-path / --backend FILE:/etc"
  serve read-only
  [ "$status" -eq 0 ]
  [ "$(argv_joined)" = "serve --rest --restrict-to-path $ROOT_DIR/cluster-a --permissions read-only " ]
}

@test "another remote path name is accepted" {
  export SSH_ORIGINAL_COMMAND="/usr/local/bin/borg2 serve --rest --backend FILE:cluster-a/node01"
  serve
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/major")" = "2" ]
}

@test "leading environment assignments are skipped, not interpreted" {
  export SSH_ORIGINAL_COMMAND="BORG_FOO=bar $BORG2_REQUEST"
  serve
  [ "$status" -eq 0 ]
  started
}

@test "Borg 2 is served whether or not Borg 1 is" {
  export SSH_ORIGINAL_COMMAND="$BORG2_REQUEST"
  serve all 2
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/major")" = "2" ]
}

# --- Borg 1 -------------------------------------------------------------------

@test "a Borg 1 request starts Borg 1 with the pinned restriction" {
  export SSH_ORIGINAL_COMMAND="$BORG1_REQUEST"
  serve
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/major")" = "1" ]
  [ "$(argv_joined)" = "serve --restrict-to-path $ROOT_DIR/cluster-a " ]
}

@test "no-delete becomes append-only for Borg 1" {
  export SSH_ORIGINAL_COMMAND="$BORG1_REQUEST"
  serve no-delete
  [ "$status" -eq 0 ]
  [ "$(argv_joined)" = "serve --restrict-to-path $ROOT_DIR/cluster-a --append-only " ]
}

@test "a key that may only read or only write gets no Borg 1 access" {
  export SSH_ORIGINAL_COMMAND="$BORG1_REQUEST"
  for permissions in read-only write-only; do
    serve "$permissions"
    [ "$status" -eq 1 ] || fail "$permissions: status $status"
    [[ "$stderr" == *"cannot use Borg 1"* ]]
    ! started || fail "$permissions: Borg was started"
  done
}

@test "a server that does not serve Borg 1 refuses the request" {
  export SSH_ORIGINAL_COMMAND="$BORG1_REQUEST"
  serve all 2
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"does not serve Borg 1"* ]]
  ! started
}

# --- refusals -----------------------------------------------------------------

@test "a foreign command is refused and Borg is not started" {
  export SSH_ORIGINAL_COMMAND="whoami"
  serve
  [ "$status" -eq 1 ]
  [ -z "$output" ] || fail "stdout must stay empty, got: $output"
  [[ "$stderr" == *rejected* ]]
  ! started
}

@test "a login without a command is refused" {
  serve
  [ "$status" -eq 1 ]
  ! started
}

@test "a shell construct in the request is not evaluated" {
  export SSH_ORIGINAL_COMMAND="borg serve; touch $TMP/pwned"
  serve
  [ ! -e "$TMP/pwned" ]
}

@test "wildcards in the request are not expanded" {
  cd "$ROOT_DIR"
  export SSH_ORIGINAL_COMMAND="* serve --rest --backend FILE:cluster-a/node01"
  serve
  [ "$status" -eq 0 ]
}

@test "a missing data directory is an error, not a start somewhere else" {
  export SSH_ORIGINAL_COMMAND="$BORG2_REQUEST"
  run --separate-stderr "$BIN/borg-repo-serve" "$TMP/missing" cluster-a all 1,2
  [ "$status" -ne 0 ]
  ! started
}

@test "the wrong number of arguments is a usage error" {
  export SSH_ORIGINAL_COMMAND="$BORG2_REQUEST"
  run "$BIN/borg-repo-serve" "$ROOT_DIR" cluster-a all
  [ "$status" -eq 2 ]
  ! started
}
