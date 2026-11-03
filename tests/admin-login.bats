#!/usr/bin/env bats
#
# The admin login of reconcile-borgui and of the agents' password fallback
# (borgui-common.sh) with a password that has surrounding whitespace, like the
# final newline a value read with --set-file or --from-file keeps (#109). Borg
# UI 2.3.0 on creates the first admin from INITIAL_ADMIN_PASSWORD without that
# whitespace, older releases and a password change keep it, and a login is
# compared as sent: so the password is tried as it is first, then stripped.
#
# The server is tests/helpers/fake-borgui.py, logging every request to
# $TMP/requests; FAKE_ADMIN_PASS is the admin's password there.

bats_require_minimum_version 1.5.0   # run --separate-stderr

setup() {
  load helpers/common
  common_setup
  command -v jq >/dev/null || fail "jq is required for these tests"
  unset BORG_UI_NOTIFICATIONS OIDC_DISCOVERY_URL REDIS_URL REDIS_HOST CACHE_TTL_MINUTES \
        BORG_UI_ENTITLEMENT BORG_UI_LICENSE_KEY BORG_UI_SSH_IMPORT_PRIVATE_PATH \
        BORG_UI_REMOTE_MACHINES RECONCILE_STATUS_CONFIGMAP RECONCILE_TOKEN PAT_SECRET_NAME \
        BORG_UI_ADMIN_PAT BORG_UI_ADMIN_PASS BORG_UI_ADMIN_DEFAULT_PASS BORG_UI_JWT \
        OIDC_CLIENT_SECRET
  export BORG_UI_ADMIN_USER=admin RECONCILE_WAIT_SECONDS=10 BORG_UI_LOGIN_RETRY_SLEEP=0
}

teardown() {
  if [ -n "${FAKE_PID:-}" ]; then kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null || true; fi
  common_teardown
}

# start_server — start the fake server; FAKE_* in the caller's environment
# configure it.
start_server() {
  FAKE_DIR="$TMP" python3 "$BATS_TEST_DIRNAME/helpers/fake-borgui.py" 3>&- &
  FAKE_PID=$!
  local i
  for i in $(seq 50); do [ -f "$TMP/port" ] && break; sleep 0.1; done
  [ -f "$TMP/port" ] || fail "the fake server did not start"
  export BORG_UI_SERVER="http://127.0.0.1:$(cat "$TMP/port")"
}

# logins — the passwords the logins sent, in order, one JSON string per line.
logins() { jq -r 'select(.path == "/api/auth/login") | .body.password | @json' "$TMP/requests"; }

# changes — the password changes sent, one JSON object per line.
changes() { jq -c 'select(.path == "/api/auth/change-password") | .body' "$TMP/requests"; }

reconcile() { run --separate-stderr "$BIN/reconcile-borgui"; }

# bearer — borgui_bearer as an agent-side command runs it.
bearer() {
  run --separate-stderr bash -c 'set -euo pipefail; . "$BORG_LIB_DIR/borgui-common.sh"; borgui_bearer'
}

@test "reconcile: the configured password is tried once when it works" {
  start_server
  BORG_UI_ADMIN_PASS=admin-pw reconcile
  [ "$status" -eq 0 ] || fail "status $status: $output $stderr"
  [[ "$output" == *"Admin login OK (configured password)."* ]] || fail "$output"
  [ "$(logins)" = '"admin-pw"' ] || fail "logins: $(logins)"
  [[ "$stderr" != *WARNING* ]] || fail "$stderr"
}

@test "reconcile: a password with its final newline logs in to an admin Borg UI created without it" {
  start_server
  BORG_UI_ADMIN_PASS=$'admin-pw\n' reconcile
  [ "$status" -eq 0 ] || fail "status $status: $output $stderr"
  [[ "$output" == *"Admin login OK (configured password without its surrounding whitespace, as Borg UI created the admin)."* ]] \
    || fail "$output"
  [[ "$output" == *"Minted admin PAT"* ]] || fail "$output"
  [ "$(logins)" = $'"admin-pw\\n"\n"admin-pw"' ] || fail "logins: $(logins)"
  [ -z "$(changes)" ] || fail "the password was changed: $(changes)"
}

@test "reconcile: an admin created with the newline logs in with it at the first try" {
  # Borg UI before 2.3.0 (k8s-borg 1.1.6 and older) kept it.
  FAKE_ADMIN_PASS=$'admin-pw\n' start_server
  BORG_UI_ADMIN_PASS=$'admin-pw\n' reconcile
  [ "$status" -eq 0 ] || fail "status $status: $output $stderr"
  [[ "$output" == *"Admin login OK (configured password)."* ]] || fail "$output"
  [ "$(logins)" = '"admin-pw\n"' ] || fail "logins: $(logins)"
}

@test "reconcile: whitespace on both sides is dropped as Borg UI drops it" {
  start_server
  BORG_UI_ADMIN_PASS=$' \tadmin-pw\r\n' reconcile
  [ "$status" -eq 0 ] || fail "status $status: $output $stderr"
  [ "$(logins | tail -n 1)" = '"admin-pw"' ] || fail "logins: $(logins)"
}

@test "reconcile: the default password is rotated to the configured one without its whitespace" {
  FAKE_ADMIN_PASS=admin123 start_server
  BORG_UI_ADMIN_PASS=$'admin-pw\n' reconcile
  [ "$status" -eq 0 ] || fail "status $status: $output $stderr"
  [[ "$output" == *"Admin password rotated to the configured value."* ]] || fail "$output"
  [ "$(changes)" = '{"current_password":"admin123","new_password":"admin-pw"}' ] || fail "changes: $(changes)"
  # The configured password as it is, stripped, the default, then the re-login.
  [ "$(logins)" = $'"admin-pw\\n"\n"admin-pw"\n"admin123"\n"admin-pw"' ] || fail "logins: $(logins)"
}

@test "reconcile: a wrong password is not tried twice" {
  start_server
  BORG_UI_ADMIN_PASS=wrong reconcile
  [ "$status" -eq 1 ] || fail "status $status: $output $stderr"
  [[ "$stderr" == *"FATAL: cannot log in as 'admin' with the configured or default password"* ]] || fail "$stderr"
  [ "$(logins)" = $'"wrong"\n"admin123"' ] || fail "logins: $(logins)"
}

@test "reconcile: a password of whitespace only is never sent empty" {
  FAKE_ADMIN_PASS=admin123 start_server
  BORG_UI_ADMIN_PASS='  ' reconcile
  [ "$status" -eq 0 ] || fail "status $status: $output $stderr"
  [ "$(logins)" = $'"  "\n"admin123"\n"  "' ] || fail "logins: $(logins)"
  [ "$(changes)" = '{"current_password":"admin123","new_password":"  "}' ] || fail "changes: $(changes)"
}

@test "reconcile: a configured password that is the default one is accepted with a warning" {
  FAKE_ADMIN_PASS=admin123 start_server
  for pass in admin123 $'admin123\n'; do
    : >"$TMP/requests"
    BORG_UI_ADMIN_PASS="$pass" reconcile
    [ "$status" -eq 0 ] || fail "status $status: $output $stderr"
    [[ "$stderr" == *"WARNING: the configured admin password is the default one (surrounding whitespace aside) — change the admin's password in Borg UI, then configure the new one"* ]] \
      || fail "$stderr"
    [ -z "$(changes)" ] || fail "the password was changed: $(changes)"
  done
}

@test "reconcile: the default password is warned about also when the PAT is reused" {
  start_server
  BORG_UI_ADMIN_PAT=good-pat BORG_UI_ADMIN_PASS=admin123 reconcile
  [ "$status" -eq 0 ] || fail "status $status: $output $stderr"
  [[ "$output" == *"Existing PAT still valid"* ]] || fail "$output"
  [[ "$stderr" == *"WARNING: the configured admin password is the default one"* ]] || fail "$stderr"
  [ -z "$(logins)" ] || fail "logins: $(logins)"
}

@test "reconcile: the stripped password is masked in what the server said" {
  FAKE_FAIL="POST /api/auth/login" FAKE_FAIL_CODE=401 \
    FAKE_FAIL_BODY='{"detail": "no admin with password admin-pw"}' start_server
  BORG_UI_ADMIN_PASS=$'admin-pw\n' BORG_UI_ADMIN_DEFAULT_PASS=default-pw reconcile
  [ "$status" -eq 1 ] || fail "status $status: $output $stderr"
  [[ "$stderr" == *"HTTP 401: no admin with password ***"* ]] || fail "$stderr"
  [[ "$output$stderr" != *"admin-pw"* ]] || fail "the password was printed"
}

@test "agents: the password fallback logs in without the final newline" {
  start_server
  BORG_UI_ADMIN_PASS=$'admin-pw\n' bearer
  [ "$status" -eq 0 ] || fail "status $status: $output $stderr"
  [ "$output" = jwt-1 ] || fail "$output"
  [ "$(logins)" = $'"admin-pw\\n"\n"admin-pw"' ] || fail "logins: $(logins)"
}

@test "agents: an admin created with the newline logs in with it at the first try" {
  FAKE_ADMIN_PASS=$'admin-pw\n' start_server
  BORG_UI_ADMIN_PASS=$'admin-pw\n' bearer
  [ "$status" -eq 0 ] || fail "status $status: $output $stderr"
  [ "$output" = jwt-1 ] || fail "$output"
  [ "$(logins)" = '"admin-pw\n"' ] || fail "logins: $(logins)"
}

@test "agents: a wrong password is tried once per attempt" {
  start_server
  BORG_UI_ADMIN_PASS=wrong BORG_UI_LOGIN_RETRIES=2 bearer
  [ "$status" -eq 1 ] || fail "status $status: $output $stderr"
  [ "$(logins)" = $'"wrong"\n"wrong"' ] || fail "logins: $(logins)"
}
