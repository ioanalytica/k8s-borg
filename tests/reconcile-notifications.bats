#!/usr/bin/env bats
#
# reconcile-borgui, notification channels: each channel in BORG_UI_NOTIFICATIONS
# is matched by name, created when missing, updated with only the fields that
# differ, and left alone otherwise. Channels under other names are never
# touched, nothing is deleted, and a channel that cannot be written is a
# warning, not a failed reconcile. The service URL never reaches the log.
#
# The server is tests/helpers/fake-borgui.py: a real HTTP server holding the
# channels in memory and logging every request to $TMP/requests.

bats_require_minimum_version 1.5.0   # run --separate-stderr

setup() {
  load helpers/common
  common_setup
  command -v jq >/dev/null || fail "jq is required for these tests"
  unset BORG_UI_NOTIFICATIONS OIDC_DISCOVERY_URL REDIS_URL REDIS_HOST CACHE_TTL_MINUTES \
        BORG_UI_ENTITLEMENT BORG_UI_LICENSE_KEY BORG_UI_SSH_IMPORT_PRIVATE_PATH \
        BORG_UI_REMOTE_MACHINES RECONCILE_STATUS_CONFIGMAP RECONCILE_TOKEN PAT_SECRET_NAME
  export BORG_UI_ADMIN_PAT=good-pat RECONCILE_WAIT_SECONDS=10
  export URL0="mailtos://alerts:s3cr3t-pw@smtp.example.com:587"
  export URL1="json://hooks.example.com/t0ken-abc"
  # A password with every character that has a meaning in a URL.
  export SMTP_PW='s3cr3t-pw/@:?&=%+ #,'
}

teardown() {
  if [ -n "${FAKE_PID:-}" ]; then kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null || true; fi
  common_teardown
}

# start_server [CHANNELS_JSON] — start the fake server with those channels;
# FAKE_FAIL in the caller's environment selects the routes that answer 422.
start_server() {
  FAKE_DIR="$TMP" FAKE_CHANNELS="${1:-[]}" FAKE_FAIL="${FAKE_FAIL:-}" python3 "$BATS_TEST_DIRNAME/helpers/fake-borgui.py" 3>&- &
  FAKE_PID=$!
  local i
  for i in $(seq 50); do [ -f "$TMP/port" ] && break; sleep 0.1; done
  [ -f "$TMP/port" ] || fail "the fake server did not start"
  export BORG_UI_SERVER="http://127.0.0.1:$(cat "$TMP/port")"
}

# reconcile — run the reconciler, keeping stdout and stderr apart.
reconcile() { run --separate-stderr "$BIN/reconcile-borgui"; }

# writes — the POST/PUT/DELETE requests to the notification routes, one per line.
writes() {
  jq -c 'select(.method != "GET" and (.path | startswith("/api/notifications")))' "$TMP/requests"
}

# channel NAME — the server's channel of that name, as JSON.
channel() { jq -c --arg n "$1" '.[] | select(.name == $n)' "$TMP/channels.json"; }

# no_secret_in_output — neither URL is in what the reconciler printed.
no_secret_in_output() {
  local all="$output$stderr"
  [[ "$all" != *"s3cr3t"* && "$all" != *"t0ken-abc"* ]] || fail "a credential was printed: $all"
}

ONE='[{"name":"ops-mail","urlEnv":"URL0","settings":{"enabled":true}}]'

@test "notifications: without channels in the values, the API is not asked" {
  start_server
  reconcile
  [ "$status" -eq 0 ] || fail "$output $stderr"
  ! grep -q '/api/notifications' "$TMP/requests" || fail "$(cat "$TMP/requests")"

  BORG_UI_NOTIFICATIONS='[]' reconcile
  [ "$status" -eq 0 ] || fail "$output $stderr"
  ! grep -q '/api/notifications' "$TMP/requests" || fail "$(cat "$TMP/requests")"
}

@test "notifications: a missing channel is created with the API's event defaults" {
  start_server
  BORG_UI_NOTIFICATIONS="$ONE" reconcile
  [ "$status" -eq 0 ] || fail "$output $stderr"
  [ "$(writes | jq -c '[.method, .path, .body]')" \
    = "[\"POST\",\"/api/notifications\",{\"name\":\"ops-mail\",\"service_url\":\"$URL0\",\"enabled\":true}]" ] \
    || fail "$(writes)"
  c="$(channel ops-mail)"
  [ "$(jq -r '[.enabled, .notify_on_backup_failure, .notify_on_schedule_failure, .notify_on_stale_backup, .notify_on_backup_success] | map(tostring) | join(",")' <<<"$c")" \
    = "true,true,true,true,false" ] || fail "$c"
  [[ "$output" == *"ops-mail: created"* ]] || fail "$output"
  no_secret_in_output
}

@test "notifications: an unchanged channel causes no write" {
  start_server "[{\"id\": 3, \"name\": \"ops-mail\", \"service_url\": \"$URL0\"}]"
  BORG_UI_NOTIFICATIONS="$ONE" reconcile
  [ "$status" -eq 0 ] || fail "$output $stderr"
  [ -z "$(writes)" ] || fail "$(writes)"
  [[ "$output" == *"ops-mail: unchanged"* ]] || fail "$output"
}

@test "notifications: a changed URL or flag is updated with only the fields that differ" {
  start_server "[{\"id\": 3, \"name\": \"ops-mail\", \"service_url\": \"json://old.example.com/x\"}]"
  BORG_UI_NOTIFICATIONS='[{"name":"ops-mail","urlEnv":"URL0","settings":{"enabled":true,"notify_on_backup_success":true}}]' reconcile
  [ "$status" -eq 0 ] || fail "$output $stderr"
  [ "$(writes | jq -c '[.method, .path, .body]')" \
    = "[\"PUT\",\"/api/notifications/3\",{\"service_url\":\"$URL0\",\"notify_on_backup_success\":true}]" ] \
    || fail "$(writes)"
  [[ "$output" == *"ops-mail: updated (service_url, notify_on_backup_success)"* ]] || fail "$output"
  no_secret_in_output
}

@test "notifications: a flag the values do not set is left as the UI set it" {
  start_server "[{\"id\": 3, \"name\": \"ops-mail\", \"service_url\": \"$URL0\", \"notify_on_backup_warning\": true, \"notify_on_stale_backup\": false}]"
  BORG_UI_NOTIFICATIONS="$ONE" reconcile
  [ "$status" -eq 0 ] || fail "$output $stderr"
  [ -z "$(writes)" ] || fail "$(writes)"
}

@test "notifications: a disabled channel is enabled again" {
  start_server "[{\"id\": 3, \"name\": \"ops-mail\", \"service_url\": \"$URL0\", \"enabled\": false}]"
  BORG_UI_NOTIFICATIONS="$ONE" reconcile
  [ "$status" -eq 0 ] || fail "$output $stderr"
  [ "$(writes | jq -c '[.method, .path, .body]')" = '["PUT","/api/notifications/3",{"enabled":true}]' ] || fail "$(writes)"
}

@test "notifications: channels under other names are never touched, nothing is deleted" {
  start_server "[{\"id\": 1, \"name\": \"hand-made\", \"service_url\": \"json://ui.example.com/x\", \"enabled\": false},
                 {\"id\": 2, \"name\": \"chat\", \"service_url\": \"json://old.example.com/y\"}]"
  BORG_UI_NOTIFICATIONS='[{"name":"ops-mail","urlEnv":"URL0","settings":{"enabled":true}},
                          {"name":"chat","urlEnv":"URL1","settings":{"enabled":true}}]' reconcile
  [ "$status" -eq 0 ] || fail "$output $stderr"
  [ "$(writes | jq -r '.method + " " + .path' | sort | tr '\n' ' ')" = "POST /api/notifications PUT /api/notifications/2 " ] \
    || fail "$(writes)"
  [ "$(channel hand-made | jq -c '[.service_url, .enabled]')" = '["json://ui.example.com/x",false]' ] || fail "$(channel hand-made)"
  no_secret_in_output
}

@test "notifications: two channels with the same name are ambiguous and left alone" {
  start_server "[{\"id\": 1, \"name\": \"ops-mail\", \"service_url\": \"json://a.example.com/x\"},
                 {\"id\": 2, \"name\": \"ops-mail\", \"service_url\": \"json://b.example.com/x\"}]"
  BORG_UI_NOTIFICATIONS="$ONE" reconcile
  [ "$status" -eq 0 ] || fail "$output $stderr"
  [ -z "$(writes)" ] || fail "$(writes)"
  [[ "$stderr" == *"WARNING"*"ops-mail"*"2 channels"* ]] || fail "$stderr"
}

@test "notifications: a rejected channel is a warning, the reconcile completes, the URL stays out of the log" {
  # The fake answers 422 and echoes the request body, URL included, as
  # FastAPI's validation errors do.
  FAKE_FAIL="POST /api/notifications" start_server
  BORG_UI_NOTIFICATIONS="$ONE" reconcile
  [ "$status" -eq 0 ] || fail "$output $stderr"
  [[ "$stderr" == *"WARNING"*"ops-mail"*"HTTP 422"* ]] || fail "$stderr"
  [[ "$output" == *"Reconciliation complete."* ]] || fail "$output"
  no_secret_in_output
}

@test "notifications: one failing channel does not stop the next one" {
  FAKE_FAIL="PUT /api/notifications/3" \
    start_server "[{\"id\": 3, \"name\": \"ops-mail\", \"service_url\": \"json://old.example.com/x\"}]"
  BORG_UI_NOTIFICATIONS='[{"name":"ops-mail","urlEnv":"URL0","settings":{"enabled":true}},
                          {"name":"chat","urlEnv":"URL1","settings":{"enabled":true}}]' reconcile
  [ "$status" -eq 0 ] || fail "$output $stderr"
  [ -n "$(channel chat)" ] || fail "chat was not created"
  [[ "$stderr" == *"ops-mail"*"HTTP 422"* ]] || fail "$stderr"
  no_secret_in_output
}

@test "notifications: an unreadable channel list is a warning, not a failure" {
  FAKE_FAIL="GET /api/notifications" start_server
  BORG_UI_NOTIFICATIONS="$ONE" reconcile
  [ "$status" -eq 0 ] || fail "$output $stderr"
  [ -z "$(writes)" ] || fail "$(writes)"
  [[ "$stderr" == *"WARNING"*"HTTP 422"* ]] || fail "$stderr"
}

@test "notifications: a channel without its URL is skipped with a warning" {
  start_server
  unset URL0
  BORG_UI_NOTIFICATIONS="$ONE" reconcile
  [ "$status" -eq 0 ] || fail "$output $stderr"
  [ -z "$(writes)" ] || fail "$(writes)"
  [[ "$stderr" == *"WARNING"*"ops-mail"*"no service URL"* ]] || fail "$stderr"
}

@test "notifications: the URL is never on a command line" {
  # curl is replaced by a wrapper that records its argv and then runs the real
  # one; the reconciler's own curl calls must not carry the URL.
  start_server
  mkdir -p "$TMP/bin"
  real="$(command -v curl)"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/argv-log"\nexec "%s" "$@"\n' "$TMP" "$real" >"$TMP/bin/curl"
  chmod +x "$TMP/bin/curl"
  PATH="$TMP/bin:$PATH" BORG_UI_NOTIFICATIONS="$ONE" reconcile
  [ "$status" -eq 0 ] || fail "$output $stderr"
  [ -n "$(channel ops-mail)" ] || fail "not created"
  ! grep -q 's3cr3t-pw' "$TMP/argv-log" || fail "the URL was on a curl command line"
}

MAIL='[{"name":"ops-mail","passwordEnv":"SMTP_PW","settings":{"enabled":true},
        "email":{"smtpHost":"smtp.example.com","port":587,"mode":"starttls","username":"alerts@example.com",
                 "from":"alerts@example.com","fromName":"Borg UI & co","to":["ops@example.com","oncall@example.com"],
                 "cc":["audit@example.com"],"bcc":["x@example.com"],"replyTo":"noreply@example.com"}}]'
MAIL_URL='mailtos://smtp.example.com:587?smtp=smtp.example.com&mode=starttls&user=alerts%40example.com&pass=s3cr3t-pw%2F%40%3A%3F%26%3D%25%2B%20%23%2C&from=alerts%40example.com&name=Borg%20UI%20%26%20co&to=ops%40example.com%2Concall%40example.com&cc=audit%40example.com&bcc=x%40example.com&reply=noreply%40example.com'

# query_param URL NAME — the value of that query parameter, decoded.
query_param() {
  python3 -c 'import sys, urllib.parse as u; print(u.parse_qs(u.urlsplit(sys.argv[1]).query)[sys.argv[2]][0])' "$1" "$2"
}

@test "notifications: an email channel is assembled into one encoded Apprise URL" {
  start_server
  BORG_UI_NOTIFICATIONS="$MAIL" reconcile
  [ "$status" -eq 0 ] || fail "$output $stderr"
  got="$(writes | jq -r .body.service_url)"
  [ "$got" = "$MAIL_URL" ] || fail "$got"
  [ "$(query_param "$got" pass)" = "$SMTP_PW" ] || fail "the password does not round-trip"
  [ "$(query_param "$got" name)" = "Borg UI & co" ] || fail "the sender name does not round-trip"
  [[ "$output" == *"ops-mail: created"* ]] || fail "$output"
  no_secret_in_output
}

@test "notifications: without a port, login or extras the URL carries only what is set" {
  start_server
  BORG_UI_NOTIFICATIONS='[{"name":"relay","settings":{"enabled":true},
    "email":{"smtpHost":"relay.example.com","mode":"insecure","from":"alerts@example.com","to":["ops@example.com"]}}]' reconcile
  [ "$status" -eq 0 ] || fail "$output $stderr"
  [ "$(writes | jq -r .body.service_url)" \
    = "mailto://relay.example.com?smtp=relay.example.com&mode=insecure&from=alerts%40example.com&to=ops%40example.com" ] \
    || fail "$(writes)"
}

@test "notifications: an email channel that matches the server causes no write" {
  start_server "[{\"id\": 3, \"name\": \"ops-mail\", \"service_url\": \"$MAIL_URL\"}]"
  BORG_UI_NOTIFICATIONS="$MAIL" reconcile
  [ "$status" -eq 0 ] || fail "$output $stderr"
  [ -z "$(writes)" ] || fail "$(writes)"
  [[ "$output" == *"ops-mail: unchanged"* ]] || fail "$output"
}

@test "notifications: an email channel whose password is missing is skipped with a warning" {
  start_server
  unset SMTP_PW
  BORG_UI_NOTIFICATIONS="$MAIL" reconcile
  [ "$status" -eq 0 ] || fail "$output $stderr"
  [ -z "$(writes)" ] || fail "$(writes)"
  [[ "$stderr" == *"WARNING"*"ops-mail"*"no password"*"SMTP_PW is empty"* ]] || fail "$stderr"
}
