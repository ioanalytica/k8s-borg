#!/usr/bin/env bats
#
# register-repo records this node's repository in Borg UI. What matters here is
# the encryption mode it sends: the one borg-init created the repository with,
# under the name Borg UI gives that mode. Borg UI's import route stores the mode
# without checking it, so a wrong one would go unnoticed.
#
# curl is replaced by a stub that answers the endpoints the script talks to,
# records every request line in $TMP/requests and the import payload in
# $TMP/payload.

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

# make_fake_curl — FAKE_REPOS is the body of GET /api/repositories/.
make_fake_curl() {
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
method=GET url= data=
while [ \$# -gt 0 ]; do
  case "\$1" in
    -X) method="\$2"; shift ;;
    -d) data="\$2"; shift ;;
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
