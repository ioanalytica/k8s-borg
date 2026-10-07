#!/usr/bin/env bats
#
# reconcile-borgui, failures: every request is bounded in time, a failed run
# says why (curl's message, or the HTTP status with what the server said, never
# the rejected input or a known secret), and the reason outlives the Job in the
# reconcile-status ConfigMap (data.lastError), which the next successful run
# clears.
#
# The server — Borg UI and, through K8S_API, the k8s API — is
# tests/helpers/fake-borgui.py, logging every request to $TMP/requests.

bats_require_minimum_version 1.5.0   # run --separate-stderr

setup() {
  load helpers/common
  common_setup
  command -v jq >/dev/null || fail "jq is required for these tests"
  unset BORG_UI_NOTIFICATIONS OIDC_DISCOVERY_URL REDIS_URL REDIS_HOST CACHE_TTL_MINUTES \
        BORG_UI_ENTITLEMENT BORG_UI_LICENSE_KEY BORG_UI_SSH_IMPORT_PRIVATE_PATH \
        BORG_UI_REMOTE_MACHINES RECONCILE_STATUS_CONFIGMAP RECONCILE_TOKEN PAT_SECRET_NAME \
        BORG_UI_ADMIN_PASS OIDC_CLIENT_SECRET
  export BORG_UI_ADMIN_PAT=good-pat RECONCILE_WAIT_SECONDS=10
  # The pod's ServiceAccount mount, for the requests to the k8s API.
  export SA_DIR="$TMP/sa"
  mkdir -p "$SA_DIR"
  printf backup >"$SA_DIR/namespace"
  printf sa-token >"$SA_DIR/token"
  : >"$SA_DIR/ca.crt"
}

teardown() {
  if [ -n "${FAKE_PID:-}" ]; then kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null || true; fi
  common_teardown
}

# start_server — start the fake server; FAKE_* in the caller's environment
# configure it. Points both BORG_UI_SERVER and K8S_API at it.
start_server() {
  FAKE_DIR="$TMP" python3 "$BATS_TEST_DIRNAME/helpers/fake-borgui.py" 3>&- &
  FAKE_PID=$!
  local i
  for i in $(seq 50); do [ -f "$TMP/port" ] && break; sleep 0.1; done
  [ -f "$TMP/port" ] || fail "the fake server did not start"
  export BORG_UI_SERVER="http://127.0.0.1:$(cat "$TMP/port")"
  export K8S_API="$BORG_UI_SERVER"
}

# gated — run with the reconcile gate on: this revision is "7".
gated() { export RECONCILE_STATUS_CONFIGMAP=rel-reconcile-status RECONCILE_TOKEN=7; }

# status_cm — the status ConfigMap's data, as JSON.
status_cm() { jq -c '.data' "$TMP/k8s-configmaps-rel-reconcile-status.json"; }

reconcile() { run --separate-stderr "$BIN/reconcile-borgui"; }

@test "failure: an unreachable server ends the wait with curl's reason" {
  # Nothing listens on port 1, so every attempt is refused at once.
  BORG_UI_SERVER=http://127.0.0.1:1 RECONCILE_WAIT_SECONDS=1 reconcile
  [ "$status" -eq 1 ] || fail "status $status: $output $stderr"
  [[ "$stderr" == *"FATAL: server not healthy within 1s — GET /health: curl: (7) "* ]] || fail "$stderr"
}

@test "failure: a server that answers but is not healthy ends the wait with the status and its detail" {
  FAKE_HEALTH=503 start_server
  RECONCILE_WAIT_SECONDS=1 reconcile
  [ "$status" -eq 1 ] || fail "status $status: $output $stderr"
  [[ "$stderr" == *"FATAL: server not healthy within 1s — GET /health: HTTP 503: starting"* ]] || fail "$stderr"
}

@test "failure: every request is bounded in time, the health check more tightly" {
  # curl is replaced by a wrapper that records its argv and runs the real one.
  start_server
  mkdir -p "$TMP/bin"
  real="$(command -v curl)"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/argv-log"\nexec "%s" "$@"\n' "$TMP" "$real" >"$TMP/bin/curl"
  chmod +x "$TMP/bin/curl"
  unset BORG_UI_ADMIN_PAT
  gated
  PATH="$TMP/bin:$PATH" BORG_UI_ADMIN_PASS=admin-pw PAT_SECRET_NAME=rel-pat reconcile
  [ "$status" -eq 0 ] || fail "$output $stderr"
  [ "$(grep -c . "$TMP/argv-log")" -ge 6 ] || fail "too few requests: $(cat "$TMP/argv-log")"
  health="$(grep '/health$' "$TMP/argv-log")"
  [[ "$health" == *"--connect-timeout 10 --max-time 60 "*"--connect-timeout 5 --max-time 10 "* ]] \
    || fail "health check: $health"
  ! grep -v -e '--connect-timeout 10 --max-time 60 ' "$TMP/argv-log" || fail "a request without the limits"
}

@test "failure: a rejected request names the status and the validation message, never the rejected input" {
  # The fake echoes the request body, client secret included, in detail[].input.
  FAKE_FAIL="PUT /api/settings/system" start_server
  OIDC_DISCOVERY_URL=https://id.example.com OIDC_CLIENT_SECRET=very-secret-value reconcile
  [ "$status" -eq 1 ] || fail "status $status: $output $stderr"
  [[ "$stderr" == *"FATAL: OIDC configuration failed — PUT /api/settings/system: HTTP 422: request: invalid"* ]] \
    || fail "$stderr"
  [[ "$output$stderr" != *"very-secret-value"* ]] || fail "the client secret was printed"
}

@test "failure: a known secret in what the server said is masked, also URL-encoded" {
  FAKE_FAIL="PUT /api/settings/system" FAKE_FAIL_CODE=500 \
    FAKE_FAIL_BODY='{"detail": "cannot reach id.example.com with very-secret-value/x or very-secret-value%2Fx"}' \
    start_server
  OIDC_DISCOVERY_URL=https://id.example.com OIDC_CLIENT_SECRET=very-secret-value/x reconcile
  [ "$status" -eq 1 ] || fail "status $status: $output $stderr"
  [[ "$stderr" == *"HTTP 500: cannot reach id.example.com with *** or ***"* ]] || fail "$stderr"
}

@test "failure: a long or non-JSON answer is put on one line and cut short" {
  FAKE_FAIL="PUT /api/settings/system" FAKE_FAIL_CODE=502 \
    FAKE_FAIL_BODY="<html>
<body>Bad Gateway $(printf 'x%.0s' $(seq 400))</body></html>" start_server
  OIDC_DISCOVERY_URL=https://id.example.com reconcile
  [ "$status" -eq 1 ] || fail "status $status: $output $stderr"
  line="$(grep FATAL <<<"$stderr")"
  [[ "$line" == *"HTTP 502: <html> <body>Bad Gateway xxx"*"…" ]] || fail "$line"
  [ "${#line}" -lt 420 ] || fail "not cut short: ${#line} characters"
}

@test "failure: a refused k8s write names what the API said" {
  FAKE_FAIL="PATCH /api/v1/namespaces/backup/secrets/rel-pat" FAKE_FAIL_CODE=403 \
    FAKE_FAIL_BODY='{"kind": "Status", "message": "secrets \"rel-pat\" is forbidden: cannot patch", "reason": "Forbidden"}' \
    start_server
  unset BORG_UI_ADMIN_PAT
  BORG_UI_ADMIN_PASS=admin-pw PAT_SECRET_NAME=rel-pat reconcile
  [ "$status" -eq 1 ] || fail "status $status: $output $stderr"
  [[ "$stderr" == *'FATAL: writing the PAT to secret rel-pat failed — PATCH secrets/rel-pat: HTTP 403: secrets "rel-pat" is forbidden: cannot patch'* ]] \
    || fail "$stderr"
  # stdout names the minted PAT by its prefix, which is the whole of the fake's.
  [[ "$stderr" != *"new-pat"* && "$output$stderr" != *"admin-pw"* ]] || fail "a credential was printed"
}

@test "failure: a failed login names the server's reason" {
  start_server
  unset BORG_UI_ADMIN_PAT
  BORG_UI_ADMIN_PASS=wrong reconcile
  [ "$status" -eq 1 ] || fail "status $status: $output $stderr"
  [[ "$stderr" == *"FATAL: cannot log in as 'admin' with the configured or default password — POST /api/auth/login: HTTP 401: backend.errors.auth.invalidCredentials"* ]] \
    || fail "$stderr"
}

@test "failure: the reason is kept in the status ConfigMap with the revision" {
  FAKE_FAIL="PUT /api/settings/system" start_server
  gated
  OIDC_DISCOVERY_URL=https://id.example.com reconcile
  [ "$status" -eq 1 ] || fail "status $status: $output $stderr"
  err="$(status_cm | jq -r .lastError)"
  [[ "$err" =~ ^revision\ 7\ at\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z:\ FATAL:\ OIDC\ configuration\ failed\ —\ PUT\ /api/settings/system:\ HTTP\ 422 ]] \
    || fail "$err"
  [ "$(status_cm | jq -r '.reconciled // "unset"')" = unset ] || fail "marked reconciled: $(status_cm)"
}

@test "failure: a missing setting is kept in the status ConfigMap as well" {
  start_server
  gated
  unset BORG_UI_ADMIN_PAT
  reconcile
  [ "$status" -eq 1 ] || fail "status $status: $output $stderr"
  [[ "$(status_cm | jq -r .lastError)" == "revision 7 at "*": FATAL: set BORG_UI_ADMIN_PASS to mint a PAT" ]] \
    || fail "$(status_cm)"
}

@test "failure: a successful run marks the revision and drops the earlier failure" {
  FAKE_FAIL="PUT /api/settings/system" start_server
  gated
  OIDC_DISCOVERY_URL=https://id.example.com reconcile
  [ "$status" -eq 1 ] || fail "the first run did not fail"
  [ -n "$(status_cm | jq -r '.lastError // ""')" ] || fail "no lastError: $(status_cm)"

  unset OIDC_DISCOVERY_URL
  reconcile
  [ "$status" -eq 0 ] || fail "$output $stderr"
  [ "$(status_cm)" = '{"reconciled":"7"}' ] || fail "$(status_cm)"
}

@test "failure: a rejected notification channel names what the server said, without the URL" {
  FAKE_FAIL="POST /api/notifications" FAKE_FAIL_BODY='{"detail": "invalid URL json://hooks.example.com/t0ken-abc"}' \
    start_server
  URL1="json://hooks.example.com/t0ken-abc" \
    BORG_UI_NOTIFICATIONS='[{"name":"chat","urlEnv":"URL1","settings":{"enabled":true}}]' reconcile
  [ "$status" -eq 0 ] || fail "$output $stderr"
  [[ "$stderr" == *"WARNING: channel 'chat' could not be written (HTTP 422: invalid URL ***)"* ]] || fail "$stderr"
  [[ "$output$stderr" != *"t0ken-abc"* ]] || fail "the URL was printed"
}
