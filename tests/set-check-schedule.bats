#!/usr/bin/env bats
#
# set-check-schedule: the check schedule it sets in Borg UI, and the one it
# removes. It records the cron it set as "<repo id> <cron>" in
# BORG_CHECK_SCHEDULE_OWNED; with no cron configured it removes the schedule
# only while Borg UI still has that cron. A schedule set by hand in Borg UI, or
# given another cron there, is left alone. The value "off" removes any schedule
# and keeps the pod off the default.
#
# curl is a stub that answers the endpoints the script talks to: the
# repository is id 4, its current schedule is $TMP/schedule (none without the
# file, unreadable with $TMP/schedule-unreadable). Each PUT payload is a line in
# $TMP/puts, each request one in $TMP/requests.

bats_require_minimum_version 1.5.0

setup() {
  load helpers/common
  common_setup
  unset BORG_UI_JWT BORG_UI_ADMIN_USER BORG_UI_ADMIN_PASS BORG_CHECK_CRON BORG_CHECK_TIMEZONE TZ
  export BORG_UI_SERVER=http://ui BORG_UI_ADMIN_PAT=borgui_x BORG_UI_AGENT_NAME=console \
         BORG_REPO="ssh://borg@host/./repos/console" \
         BORG_CHECK_SCHEDULE_DIR="$TMP/schedules" BORG_CHECK_SCHEDULE_OWNED="$TMP/owned"
  mkdir -p "$TMP/schedules" "$TMP/bin"
  cat >"$TMP/bin/curl" <<EOF2
#!/usr/bin/env bash
method=GET url= data=
while [ \$# -gt 0 ]; do
  case "\$1" in
    -X) method="\$2"; shift ;;
    -d) data="\$2"; shift ;;
    -H|-o|-w) shift ;;
    http*) url="\$1" ;;
  esac
  shift
done
echo "\$method \$url" >>"$TMP/requests"
case "\$method \$url" in
  "GET http://ui/api/auth/me")       printf 200 ;;
  "GET http://ui/api/repositories/") printf '{"repositories": [{"id": 4, "name": "console", "path": "%s", "agent_machine_id": 7}]}' "\$BORG_REPO" ;;
  "GET http://ui/api/repositories/4/check-schedule")
    [ ! -f "$TMP/schedule-unreadable" ] || exit 22
    if [ -f "$TMP/schedule" ]; then cat "$TMP/schedule"
    else printf '{"check_cron_expression": null, "enabled": false}'; fi ;;
  "PUT http://ui/api/repositories/4/check-schedule") printf '%s\n' "\$data" >>"$TMP/puts"; printf '{"success": true}' ;;
  *) echo "unexpected \$method \$url" >&2; exit 22 ;;
esac
EOF2
  chmod +x "$TMP/bin/curl"
  PATH="$TMP/bin:$BIN:$PATH"
}

teardown() { common_teardown; }

# in_borg_ui CRON [ENABLED] — the repository's current check schedule.
in_borg_ui() {
  printf '{"check_cron_expression": "%s", "enabled": %s}' "$1" "${2:-true}" >"$TMP/schedule"
}

# configured KEY VALUE — a key of the check-schedules ConfigMap.
configured() { printf '%s' "$2" >"$TMP/schedules/$1_check_schedule"; }

# puts — the PUT payloads, one per line ("" when there was none).
puts() { cat "$TMP/puts" 2>/dev/null || true; }

# --- setting -------------------------------------------------------------------

@test "a configured cron is set and recorded as its own" {
  configured default "0 3 * * 0"
  run "$BIN/set-check-schedule"
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(puts)" = '{"cron_expression": "0 3 * * 0", "schedule_enabled": true}' ] || fail "$(puts)"
  [ "$(cat "$TMP/owned")" = "4 0 3 * * 0" ] || fail "$(cat "$TMP/owned")"
}

@test "a cron already set is recorded as its own, without a PUT" {
  # As after an update from a version that kept no record.
  configured console "0 3 * * 0"
  in_borg_ui "0 3 * * 0"
  run "$BIN/set-check-schedule"
  [ "$status" -eq 0 ] || fail "$output"
  [ -z "$(puts)" ] || fail "$(puts)"
  [ "$(cat "$TMP/owned")" = "4 0 3 * * 0" ] || fail "$(cat "$TMP/owned")"
}

@test "a changed cron replaces the one set before, and its record" {
  configured console "0 4 * * 0"
  in_borg_ui "0 3 * * 0"
  echo "4 0 3 * * 0" >"$TMP/owned"
  run "$BIN/set-check-schedule"
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(puts)" = '{"cron_expression": "0 4 * * 0", "schedule_enabled": true}' ] || fail "$(puts)"
  [ "$(cat "$TMP/owned")" = "4 0 4 * * 0" ] || fail "$(cat "$TMP/owned")"
}

@test "a record that cannot be written leaves a warning, the schedule is set" {
  export BORG_CHECK_SCHEDULE_OWNED="$TMP/no-such-dir/owned"
  configured default "0 3 * * 0"
  run "$BIN/set-check-schedule"
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(puts)" = '{"cron_expression": "0 3 * * 0", "schedule_enabled": true}' ] || fail "$(puts)"
  [[ "$output" == *"WARN: could not write $TMP/no-such-dir/owned"* ]] || fail "$output"
}

# --- removed from the values ---------------------------------------------------

@test "removed from the values: its own schedule is removed" {
  in_borg_ui "0 3 * * 0"
  echo "4 0 3 * * 0" >"$TMP/owned"
  run "$BIN/set-check-schedule"
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(puts)" = '{"cron_expression": ""}' ] || fail "$(puts)"
  [ ! -e "$TMP/owned" ] || fail "the record is still there"
  [[ "$output" == *"Check schedule '0 3 * * 0' removed for 'console'"* ]] || fail "$output"
}

@test "removed from the values: its own schedule is removed also when paused" {
  in_borg_ui "0 3 * * 0" false
  echo "4 0 3 * * 0" >"$TMP/owned"
  run "$BIN/set-check-schedule"
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(puts)" = '{"cron_expression": ""}' ] || fail "$(puts)"
}

@test "removed from the values: a schedule given another cron in Borg UI since is left alone" {
  in_borg_ui "0 4 * * 0"
  echo "4 0 3 * * 0" >"$TMP/owned"
  run "$BIN/set-check-schedule"
  [ "$status" -eq 0 ] || fail "$output"
  [ -z "$(puts)" ] || fail "$(puts)"
  # It is no longer ours: setting the old cron again by hand stays too.
  [ ! -e "$TMP/owned" ] || fail "the record is still there"
}

@test "removed from the values: the record of another repository does not count" {
  # E.g. Borg UI set up anew, the repository registered again under a new id.
  in_borg_ui "0 3 * * 0"
  echo "9 0 3 * * 0" >"$TMP/owned"
  run "$BIN/set-check-schedule"
  [ "$status" -eq 0 ] || fail "$output"
  [ -z "$(puts)" ] || fail "$(puts)"
  [ ! -e "$TMP/owned" ] || fail "the record is still there"
}

@test "removed from the values: a schedule already gone needs no PUT" {
  echo "4 0 3 * * 0" >"$TMP/owned"
  run "$BIN/set-check-schedule"
  [ "$status" -eq 0 ] || fail "$output"
  [ -z "$(puts)" ] || fail "$(puts)"
  [ ! -e "$TMP/owned" ] || fail "the record is still there"
}

@test "removed from the values: an unreadable schedule keeps the record for the next start" {
  in_borg_ui "0 3 * * 0"
  touch "$TMP/schedule-unreadable"
  echo "4 0 3 * * 0" >"$TMP/owned"
  run "$BIN/set-check-schedule"
  [ "$status" -ne 0 ] || fail "$output"
  [ -z "$(puts)" ] || fail "$(puts)"
  [ "$(cat "$TMP/owned")" = "4 0 3 * * 0" ] || fail "the record is gone"
}

# --- never set from the values -------------------------------------------------

@test "without a cron or a record a schedule set by hand is left alone, Borg UI not asked" {
  in_borg_ui "0 5 * * *"
  run "$BIN/set-check-schedule"
  [ "$status" -eq 0 ] || fail "$output"
  [ ! -e "$TMP/requests" ] || fail "requests: $(cat "$TMP/requests")"
  [ ! -e "$TMP/owned" ] || fail "a record was written"
}

# --- off -----------------------------------------------------------------------

@test "off removes a schedule set by hand" {
  configured console off
  in_borg_ui "0 5 * * *"
  run "$BIN/set-check-schedule"
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(puts)" = '{"cron_expression": ""}' ] || fail "$(puts)"
  [ ! -e "$TMP/owned" ] || fail "a record was written"
}

@test "off removes its own schedule and the record" {
  configured default off
  in_borg_ui "0 3 * * 0"
  echo "4 0 3 * * 0" >"$TMP/owned"
  run "$BIN/set-check-schedule"
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(puts)" = '{"cron_expression": ""}' ] || fail "$(puts)"
  [ ! -e "$TMP/owned" ] || fail "the record is still there"
}

@test "off keeps the pod off the default" {
  configured default "0 3 * * 0"
  configured console off
  run "$BIN/set-check-schedule"
  [ "$status" -eq 0 ] || fail "$output"
  [ -z "$(puts)" ] || fail "$(puts)"
  [[ "$output" == *"No check schedule set for 'console' — nothing to remove."* ]] || fail "$output"
}
