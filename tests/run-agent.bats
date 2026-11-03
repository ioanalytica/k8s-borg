#!/usr/bin/env bats
#
# run-agent.sh: the record of the check schedule set-check-schedule set itself
# (BORG_CHECK_SCHEDULE_OWNED) holds only for the server that knows this agent.
# An agent that enrols anew (no config, or one the server no longer knows: a
# new or rebuilt Borg UI) drops it before set-check-schedule runs, so that a
# schedule there is never taken for its own.
# A pod that dumps databases (BORG_DB_ENGINES) creates DB_BACKUP_LOCATION
# before it registers its plan, which takes only the roots that exist: the
# dumps are written later, by the plan's own pre-backup hooks.
#
# curl, borg-ui-agent and the provisioning commands are stubs. The server knows
# the agent once $TMP/known exists; `borg-ui-agent register` creates it.
# set-check-schedule notes in $TMP/record whether the record was there, and
# register-backup-plan in $TMP/dumps whether DB_BACKUP_LOCATION was.

setup() {
  load helpers/common
  common_setup
  unset BORG_UI_JWT BORG_UI_ADMIN_USER BORG_UI_ADMIN_PASS BORG_REGISTER_PLAN BORG_DB_ENGINES DB_BACKUP_LOCATION
  export BORG_UI_AGENT=true BORG_UI_SERVER=http://ui BORG_UI_ADMIN_PAT=borgui_x \
         BORG_UI_AGENT_NAME=console BORG_UI_CONFIG="$TMP/config.toml" \
         BORG_CHECK_SCHEDULE_OWNED="$TMP/owned"
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/curl" <<EOF2
#!/usr/bin/env bash
method=GET url=
while [ \$# -gt 0 ]; do
  case "\$1" in
    -X) method="\$2"; shift ;;
    -H|-d|-o|-w) shift ;;
    http*) url="\$1" ;;
  esac
  shift
done
case "\$method \$url" in
  "GET http://ui/api/auth/me") printf 200 ;;
  "GET http://ui/api/managed-machines/agents")
    if [ -f "$TMP/known" ]; then printf '[{"id": 3, "name": "console", "status": "online"}]'
    else printf '[]'; fi ;;
  "POST http://ui/api/managed-machines/enrollment-tokens") printf '{"token": "t"}' ;;
  *) echo "unexpected \$method \$url" >&2; exit 22 ;;
esac
EOF2
  cat >"$TMP/bin/borg-ui-agent" <<EOF2
#!/usr/bin/env bash
[ "\$3" != register ] || { touch "\$2" "$TMP/known"; }
exit 0
EOF2
  cat >"$TMP/bin/set-check-schedule" <<EOF2
#!/usr/bin/env bash
if [ -e "\$BORG_CHECK_SCHEDULE_OWNED" ]; then echo kept; else echo gone; fi >"$TMP/record"
EOF2
  printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/bin/register-repo"
  cat >"$TMP/bin/register-backup-plan" <<EOF2
#!/usr/bin/env bash
if [ -d "\${DB_BACKUP_LOCATION:-}" ]; then echo there; else echo missing; fi >"$TMP/dumps"
EOF2
  chmod +x "$TMP/bin/"*
  PATH="$TMP/bin:$PATH"
  echo "4 0 3 * * 0" >"$TMP/owned"
}

teardown() { common_teardown; }

@test "an agent the server knows keeps the check-schedule record" {
  touch "$TMP/config.toml" "$TMP/known"
  run "$ROOTFS/run-agent.sh"
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"skipping enrollment"* ]] || fail "$output"
  [ "$(cat "$TMP/record")" = kept ] || fail "record: $(cat "$TMP/record")"
}

@test "an agent the server no longer knows drops the record before it enrols" {
  touch "$TMP/config.toml"
  run "$ROOTFS/run-agent.sh"
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"Stale enrolment"* ]] || fail "$output"
  [ "$(cat "$TMP/record")" = gone ] || fail "record: $(cat "$TMP/record")"
}

@test "an agent without config drops the record too" {
  run "$ROOTFS/run-agent.sh"
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"Enrolled (agent id 3)."* ]] || fail "$output"
  [ "$(cat "$TMP/record")" = gone ] || fail "record: $(cat "$TMP/record")"
}

# --- the database dumps' directory ------------------------------------------

@test "a pod that dumps databases creates their directory before it registers its plan" {
  touch "$TMP/config.toml" "$TMP/known"
  BORG_DB_ENGINES="postgres" DB_BACKUP_LOCATION="$TMP/mnt/db-backup" run "$ROOTFS/run-agent.sh"
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(cat "$TMP/dumps")" = there ] || fail "dumps: $(cat "$TMP/dumps")"
}

@test "a pod without database engines, or without a plan, creates no dump directory" {
  touch "$TMP/config.toml" "$TMP/known"
  BORG_DB_ENGINES="" DB_BACKUP_LOCATION="$TMP/mnt/db-backup" run "$ROOTFS/run-agent.sh"
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(cat "$TMP/dumps")" = missing ] || fail "dumps: $(cat "$TMP/dumps")"
  BORG_REGISTER_PLAN=false BORG_DB_ENGINES="postgres" DB_BACKUP_LOCATION="$TMP/mnt/db-backup" \
    run "$ROOTFS/run-agent.sh"
  [ "$status" -eq 0 ] || fail "$output"
  [ ! -e "$TMP/mnt/db-backup" ] || fail "created without a plan"
}

@test "a dump directory that cannot be created is named, and the plan registered anyway" {
  touch "$TMP/config.toml" "$TMP/known" "$TMP/file"
  BORG_DB_ENGINES="postgres" DB_BACKUP_LOCATION="$TMP/file/db-backup" run "$ROOTFS/run-agent.sh"
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" == *"WARNING: could not create $TMP/file/db-backup (borg.dbBackupLocation)"* ]] || fail "$output"
  [ "$(cat "$TMP/dumps")" = missing ] || fail "dumps: $(cat "$TMP/dumps")"
}
