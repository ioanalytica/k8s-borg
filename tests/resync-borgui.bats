#!/usr/bin/env bats
#
# resync-borgui asks Borg UI to resync this node's repository after a backup
# that ran outside Borg UI. The contract that matters to borg-backup: nothing to
# do is exit 0, a Borg UI that cannot be reached or refuses is exit 1, and the
# resync is requested for the repository with this node's BORG_REPO path.
#
# curl is replaced by a stub that answers the three endpoints the script talks
# to and records every request line in $TMP/requests.

setup() {
  load helpers/common
  common_setup
  unset BORG_UI_SERVER BORG_UI_ADMIN_PAT BORG_UI_ADMIN_USER BORG_UI_ADMIN_PASS \
        BORG_UI_JWT BORG_UI_AGENT_NAME REPO_NAME NODE_NAME BORGUI_REPO_MATCH
  export BORG_REPO="ssh://borg@host/./repos/cluster-a"
  export BORG_UI_LOGIN_RETRY_SLEEP=0
  make_fake_curl
  PATH="$TMP/bin:$PATH"
}

teardown() { common_teardown; }

# make_fake_curl — the stub reads its behaviour from the environment:
#   FAKE_DOWN=1       every request fails like an unreachable server (rc 7)
#   FAKE_ME_CODE      HTTP code for GET /api/auth/me (default 200)
#   FAKE_REPOS        body for GET /api/repositories/
#   FAKE_RESYNC_RC    exit code for POST …/resync (default 0)
make_fake_curl() {
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
method=GET url=
while [ \$# -gt 0 ]; do
  case "\$1" in
    -X) method="\$2"; shift ;;
    http*) url="\$1" ;;
  esac
  shift
done
echo "\$method \$url" >> "$TMP/requests"
[ -n "\${FAKE_DOWN:-}" ] && exit 7
case "\$url" in
  */api/auth/me)        printf '%s' "\${FAKE_ME_CODE:-200}" ;;
  */api/auth/login)     exit 22 ;;
  */api/repositories/)  printf '%s' "\${FAKE_REPOS:-[]}" ;;
  */resync)             [ "\${FAKE_RESYNC_RC:-0}" -eq 0 ] || exit "\${FAKE_RESYNC_RC}"
                        printf '{"run_id": 1, "operations": [1]}' ;;
esac
EOF
  chmod +x "$TMP/bin/curl"
}

REPOS='{"repositories": [
  {"id": 4, "name": "other", "path": "ssh://borg@host/./repos/other"},
  {"id": 7, "name": "cluster-a", "path": "ssh://borg@host/./repos/cluster-a"}]}'

@test "resync: without BORG_UI_SERVER it skips and contacts nothing" {
  run "$BIN/resync-borgui"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping"* ]]
  [ ! -e "$TMP/requests" ]
}

@test "resync: posts the resync for the repository with the BORG_REPO path" {
  BORG_UI_SERVER=http://ui BORG_UI_ADMIN_PAT=borgui_x NODE_NAME=cluster-a \
    FAKE_REPOS="$REPOS" run "$BIN/resync-borgui"
  [ "$status" -eq 0 ]
  grep -qx "POST http://ui/api/repositories/7/resync" "$TMP/requests" \
    || fail "no resync for repository 7: $(cat "$TMP/requests")"
}

@test "resync: the record's name does not have to match the node" {
  BORG_UI_SERVER=http://ui BORG_UI_ADMIN_PAT=borgui_x NODE_NAME=renamed \
    FAKE_REPOS="$REPOS" run "$BIN/resync-borgui"
  [ "$status" -eq 0 ]
  grep -qx "POST http://ui/api/repositories/7/resync" "$TMP/requests"
}

@test "resync: a record that only shares the node's name is not resynced" {
  # After a repository move the old record keeps the name; resyncing it would
  # report success while the repository just written stays invisible.
  stale='{"repositories": [
    {"id": 3, "name": "cluster-a", "path": "ssh://borg@host/./repos/old-location"}]}'
  BORG_UI_SERVER=http://ui BORG_UI_ADMIN_PAT=borgui_x NODE_NAME=cluster-a \
    FAKE_REPOS="$stale" run "$BIN/resync-borgui"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping"* ]]
  ! grep -q "resync" "$TMP/requests"
}

@test "resync: a same-named record listed first does not shadow the path match" {
  stale='{"repositories": [
    {"id": 3, "name": "cluster-a", "path": "ssh://borg@host/./repos/old-location"},
    {"id": 7, "name": "cluster-a-new", "path": "ssh://borg@host/./repos/cluster-a"}]}'
  BORG_UI_SERVER=http://ui BORG_UI_ADMIN_PAT=borgui_x NODE_NAME=cluster-a \
    FAKE_REPOS="$stale" run "$BIN/resync-borgui"
  [ "$status" -eq 0 ]
  grep -qx "POST http://ui/api/repositories/7/resync" "$TMP/requests" \
    || fail "resynced the wrong repository: $(cat "$TMP/requests")"
}

@test "resync: a repository unknown to Borg UI is a skip, not a failure" {
  BORG_UI_SERVER=http://ui BORG_UI_ADMIN_PAT=borgui_x NODE_NAME=cluster-a \
    BORG_REPO=ssh://borg@host/./repos/unregistered \
    FAKE_REPOS='{"repositories": []}' run "$BIN/resync-borgui"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping"* ]]
  ! grep -q "resync" "$TMP/requests"
}

@test "resync: an unreachable Borg UI fails after a single attempt" {
  BORG_UI_SERVER=http://ui BORG_UI_ADMIN_PAT=borgui_x NODE_NAME=cluster-a \
    FAKE_DOWN=1 run "$BIN/resync-borgui"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not authenticate"* ]]
  [ "$(grep -c "/api/auth/me" "$TMP/requests")" -eq 1 ]
}

@test "resync: a rejected PAT without a password login fails" {
  BORG_UI_SERVER=http://ui BORG_UI_ADMIN_PAT=borgui_x NODE_NAME=cluster-a \
    FAKE_ME_CODE=401 run "$BIN/resync-borgui"
  [ "$status" -eq 1 ]
  ! grep -q "resync" "$TMP/requests"
}

@test "resync: a failing resync request is exit 1" {
  BORG_UI_SERVER=http://ui BORG_UI_ADMIN_PAT=borgui_x NODE_NAME=cluster-a \
    FAKE_REPOS="$REPOS" FAKE_RESYNC_RC=22 run "$BIN/resync-borgui"
  [ "$status" -eq 1 ]
  [[ "$output" == *"resync failed"* ]]
}
