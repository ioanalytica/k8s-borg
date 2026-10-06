#!/usr/bin/env bats
#
# register-repo records this node's repository in Borg UI. Two things matter
# here:
# - the encryption mode it sends: the one borg-init created the repository
#   with, under the name Borg UI gives that mode. Borg UI's import route stores
#   the mode without checking it, so a wrong one would go unnoticed.
# - which record it acts on: a record that has the path is left alone; the
#   node's own record with another path is moved to BORG_REPO; everything else
#   that does not fit together stops the pod instead of starting it on a stale
#   record.
#
# curl is replaced by a stub that answers the endpoints the script talks to,
# records every request line in $TMP/requests, the import payload in
# $TMP/payload and every PUT as "PUT URL BODY" in $TMP/put.

bats_require_minimum_version 1.5.0

setup() {
  load helpers/common
  common_setup
  unset BORG_UI_SERVER BORG_UI_ADMIN_PAT BORG_UI_ADMIN_USER BORG_UI_ADMIN_PASS \
        BORG_UI_JWT BORG_UI_AGENT_NAME REPO_NAME BORGUI_REPO_MATCH BORG_COMPRESSION
  export BORG_UI_SERVER=http://ui BORG_UI_ADMIN_PAT=borgui_x BORG_UI_AGENT_NAME=node-a
  export BORG_REPO="ssh://borg@host/./repos/node-a" BORG_PASSPHRASE=secret
  export BORG_UI_LOGIN_RETRY_SLEEP=0
  export FAKE_REPOS='{"repositories": []}'
  make_fake_curl
  # borg-init finds `borg` on PATH, as in the image.
  PATH="$TMP/bin:$BIN:$PATH"
  make_fake_borg 0
}

teardown() { common_teardown; }

# make_fake_curl — FAKE_REPOS is the body of GET /api/repositories/,
# FAKE_PUT_CODE the HTTP code of PUT /api/repositories/<id> (default 200).
make_fake_curl() {
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
method=GET url= data= wfmt=
while [ \$# -gt 0 ]; do
  case "\$1" in
    -X) method="\$2"; shift ;;
    -d) data="\$2"; shift ;;
    -w) wfmt="\$2"; shift ;;
    http*) url="\$1" ;;
  esac
  shift
done
echo "\$method \$url" >> "$TMP/requests"
case "\$url" in
  */api/auth/me)                  printf 200 ;;
  */api/repositories/)            printf '%s' "\$FAKE_REPOS" ;;
  */api/managed-machines/agents)  printf '[{"id": 3, "name": "node-a", "status": "online"}]' ;;
  */api/repositories/import)      printf '%s' "\$data" > "$TMP/payload"; printf '{"id": 9}' ;;
  */resync)                       printf '{"run_id": "r", "operations": [1]}' ;;
  */api/repositories/[0-9]*)
    [ "\$method" = PUT ] || exit 0
    echo "\$method \$url \$data" >> "$TMP/put"
    code="\${FAKE_PUT_CODE:-200}"
    if [ "\$code" = 200 ]; then
      printf '{"success": true}'
    else
      printf '{"detail": {"key": "backend.errors.repo.failedToVerifyRepository"}}'
    fi
    [ -z "\$wfmt" ] || printf '\n%s' "\$code"
    ;;
esac
EOF
  chmod +x "$TMP/bin/curl"
}

# sent FIELD — that field of the import payload.
sent() {
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$TMP/payload" "$1"
}

# register VERSION [MODE] — run register-repo; MODE "" leaves BORG_ENCRYPTION unset.
register() {
  rm -f "$TMP/payload" "$TMP/requests"
  if [ -n "${2:-}" ]; then
    BORG_VERSION="$1" BORG_ENCRYPTION="$2" run "$BIN/register-repo"
  else
    BORG_VERSION="$1" run "$BIN/register-repo"
  fi
}

@test "register-repo: the pairs of issue #10 — what borg-init creates, register-repo records" {
  # VERSION  BORG_ENCRYPTION  borg-init's arguments              register-repo's mode
  while IFS='|' read -r version mode created recorded; do
    if [ -n "$mode" ]; then
      BORG_VERSION="$version" BORG_ENCRYPTION="$mode" run "$BIN/borg-init"
    else
      BORG_VERSION="$version" run "$BIN/borg-init"
    fi
    [ "$status" -eq 0 ] || fail "$version/$mode: borg-init: $output"
    [ "$(argv_joined)" = "$created" ] || fail "$version/$mode: created with $(argv_joined)"
    register "$version" "$mode"
    [ "$status" -eq 0 ] || fail "$version/$mode: register-repo: $output"
    [ "$(sent encryption)" = "$recorded" ] || fail "$version/$mode: recorded $(sent encryption)"
    [ "$(sent borg_version)" = "$version" ] || fail "$version/$mode: borg_version $(sent borg_version)"
  done <<'PAIRS'
1||init --encryption=repokey-blake2 |repokey-blake2
2||repo-create --encryption aes256-ocb --key-location repokey |repokey-aes-ocb
2|authenticated|repo-create --encryption authenticated-sha256 |authenticated
PAIRS
}

@test "register-repo, borg 2: every mode borg-init accepts is recorded under Borg UI's name" {
  # Borg UI's names are BORG2_ENCRYPTION_MODES in borg-ui app/core/borg2.py.
  while read -r mode recorded; do
    register 2 "$mode"
    [ "$status" -eq 0 ] || fail "$mode: $output"
    [ "$(sent encryption)" = "$recorded" ] || fail "$mode: recorded $(sent encryption)"
  done <<'MODES'
repokey-aes-ocb repokey-aes-ocb
repokey-chacha20-poly1305 repokey-chacha20-poly1305
keyfile-aes-ocb keyfile-aes-ocb
keyfile-chacha20-poly1305 keyfile-chacha20-poly1305
authenticated authenticated
authenticated-sha256 authenticated
MODES
}

@test "register-repo, borg 1: the mode is recorded as it is" {
  for mode in repokey-blake2 keyfile-blake2 repokey authenticated authenticated-blake2 none; do
    register 1 "$mode"
    [ "$status" -eq 0 ] || fail "$mode: $output"
    [ "$(sent encryption)" = "$mode" ] || fail "$mode: recorded $(sent encryption)"
  done
}

@test "register-repo, borg 2: a mode borg-init refuses is refused before Borg UI is contacted" {
  for mode in none authenticated-blake3 repokey-blake2; do
    register 2 "$mode"
    [ "$status" -eq 1 ] || fail "$mode: status $status: $output"
    [[ "$output" == *"BORG_ENCRYPTION=$mode"* ]] || fail "$mode: $output"
    [ ! -e "$TMP/requests" ] || fail "$mode: contacted Borg UI: $(cat "$TMP/requests")"
  done
}

@test "register-repo: a repository already recorded is left alone" {
  FAKE_REPOS='{"repositories": [{"id": 7, "name": "other", "path": "ssh://borg@host/./repos/node-a"}]}' \
    register 2
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"already registered"* ]] || fail "$output"
  [ ! -e "$TMP/payload" ] || fail "imported: $(cat "$TMP/payload")"
}

# repos ROW… — a GET /api/repositories/ body from "id|name|path|major|agent" rows
repos() {
  local out="" row id name path major agent
  for row in "$@"; do
    IFS='|' read -r id name path major agent <<<"$row"
    out+="${out:+, }{\"id\": $id, \"name\": \"$name\", \"path\": \"$path\", \"borg_version\": $major, \"agent_machine_id\": ${agent:-null}}"
  done
  printf '{"repositories": [%s]}' "$out"
}

OLD="ssh://borg@host/./old-base/node-a"

no_write() {
  [ ! -e "$TMP/payload" ] || fail "imported: $(cat "$TMP/payload")"
  [ ! -e "$TMP/put" ] || fail "moved: $(cat "$TMP/put")"
}

@test "register-repo: a record with the node's name and path is left alone" {
  FAKE_REPOS="$(repos "7|node-a|$BORG_REPO|2|3")" register 2
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"already registered"* ]] || fail "$output"
  no_write
}

@test "register-repo: the node's own record with another path moves to BORG_REPO and is resynced" {
  FAKE_REPOS="$(repos "7|node-a|$OLD|2|3")" register 2
  [ "$status" -eq 0 ] || fail "$output"
  # only the path: Borg UI refuses keys it does not apply
  grep -qx "PUT http://ui/api/repositories/7 {\"path\": \"$BORG_REPO\"}" "$TMP/put" \
    || fail "no path-only PUT for record 7: $(cat "$TMP/put" 2>/dev/null)"
  [[ "$output" == *"$OLD -> $BORG_REPO"* ]] || fail "$output"
  grep -qx 'POST http://ui/api/repositories/7/resync' "$TMP/requests" || fail "no resync"
  [ ! -e "$TMP/payload" ] || fail "imported: $(cat "$TMP/payload")"
}

@test "register-repo: a record with the node's name that belongs to another agent stops the pod" {
  FAKE_REPOS="$(repos "7|node-a|$OLD|2|4")" register 2
  [ "$status" -eq 1 ] || fail "status $status: $output"
  [[ "$output" == *"$OLD"* && "$output" == *"$BORG_REPO"* ]] || fail "$output"
  [[ "$output" == *"agent 4"* ]] || fail "$output"
  no_write
}

@test "register-repo: a record with the node's name and no agent stops the pod" {
  FAKE_REPOS="$(repos "7|node-a|$OLD|2|")" register 2
  [ "$status" -eq 1 ] || fail "status $status: $output"
  [[ "$output" == *"no agent"* ]] || fail "$output"
  no_write
}

@test "register-repo: a record of the other Borg major is not moved" {
  FAKE_REPOS="$(repos "7|node-a|$OLD|1|3")" register 2
  [ "$status" -eq 1 ] || fail "status $status: $output"
  [[ "$output" == *"Borg 1"* && "$output" == *"Borg 2"* ]] || fail "$output"
  no_write
}

@test "register-repo: BORG_REPO held by another record while the node's record points elsewhere stops the pod" {
  FAKE_REPOS="$(repos "7|node-a|$OLD|2|3" "9|other|$BORG_REPO|2|4")" register 2
  [ "$status" -eq 1 ] || fail "status $status: $output"
  [[ "$output" == *"'other'"* && "$output" == *"$OLD"* ]] || fail "$output"
  no_write
}

@test "register-repo: a local BORG_REPO is not moved (Borg UI would check it on the server)" {
  export BORG_REPO=/repos/new/node-a
  FAKE_REPOS="$(repos "7|node-a|/repos/old/node-a|2|3")" register 2
  [ "$status" -eq 1 ] || fail "status $status: $output"
  [[ "$output" == *"/repos/old/node-a"* && "$output" == *"/repos/new/node-a"* ]] || fail "$output"
  no_write
}

@test "register-repo: a move Borg UI refuses stops the pod with its answer" {
  FAKE_REPOS="$(repos "7|node-a|$OLD|2|3")" FAKE_PUT_CODE=400 register 2
  [ "$status" -eq 1 ] || fail "status $status: $output"
  [[ "$output" == *"HTTP 400"* && "$output" == *"failedToVerifyRepository"* ]] || fail "$output"
  ! grep -q '/resync' "$TMP/requests" || fail "resynced after a refused move"
}
