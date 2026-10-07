#!/usr/bin/env bats
#
# register-backup-plan: the pre-backup hooks it sends with the cluster plan.
# Every name in BORG_PLAN_PRE_AGENT_SCRIPTS becomes an agent-script hook in
# that order; the names also in BORG_PLAN_PRE_AGENT_SCRIPTS_CONTINUE carry
# continue_on_error, so that Borg UI runs the backup when they fail and shows
# the failure as a warning. Without names the plan carries no hooks, and Borg UI
# keeps the ones it has.
#
# curl is a stub that answers the endpoints the script talks to and keeps the
# plan payload in $TMP/payload.

bats_require_minimum_version 1.5.0

setup() {
  load helpers/common
  common_setup
  unset BORG_UI_JWT BORG_UI_ADMIN_USER BORG_UI_ADMIN_PASS BORG_BACKUP_CRON \
        BORG_PLAN_PRE_AGENT_SCRIPTS BORG_PLAN_PRE_AGENT_SCRIPTS_CONTINUE BORG_PLAN_CUSTOM_FLAGS
  export BORG_UI_SERVER=http://ui BORG_UI_ADMIN_PAT=borgui_x BORG_UI_AGENT_NAME=console \
         BORG_REPO="ssh://borg@host/./repos/console" BORG_MODE=cluster \
         BORG_PATTERNS_DIR="$TMP/patterns" BORG_BACKUP_SCHEDULE_DIR="$TMP/schedules"
  mkdir -p "$TMP/patterns" "$TMP/bin"
  echo "R $TMP" >"$TMP/patterns/cluster-include.patterns"
  : >"$TMP/patterns/cluster-exclude.patterns"
  cat >"$TMP/bin/curl" <<EOF2
#!/usr/bin/env bash
method=GET url= data= out=
while [ \$# -gt 0 ]; do
  case "\$1" in
    -X) method="\$2"; shift ;;
    -d) data="\$2"; shift ;;
    -o) out="\$2"; shift ;;
    -w) shift ;;
    http*) url="\$1" ;;
  esac
  shift
done
case "\$method \$url" in
  "GET http://ui/api/auth/me")       printf 200 ;;
  "GET http://ui/api/repositories/") printf '{"repositories": [{"id": 4, "name": "console", "path": "%s", "agent_machine_id": 7}]}' "\$BORG_REPO" ;;
  "GET http://ui/api/backup-plans/") printf '{"backup_plans": []}' ;;
  "POST http://ui/api/backup-plans/") printf '%s' "\$data" >"$TMP/payload"; printf '{"id": 1}' >"\$out"; printf 201 ;;
  *) echo "unexpected \$method \$url" >&2; exit 22 ;;
esac
EOF2
  chmod +x "$TMP/bin/curl"
  PATH="$TMP/bin:$BIN:$PATH"
}

teardown() { common_teardown; }

# hooks — the plan's hooks as "order name continue_on_error" lines.
hooks() {
  python3 -c '
import json, sys
for h in json.load(open(sys.argv[1])).get("script_hooks", []):
    print(h["execution_order"], h["agent_script_name"], h["hook_type"], h["continue_on_error"])' "$TMP/payload"
}

@test "the S3 check continues on error, the database dumps do not" {
  BORG_PLAN_PRE_AGENT_SCRIPTS="s3-check-mounts backup-cluster-postgres" \
  BORG_PLAN_PRE_AGENT_SCRIPTS_CONTINUE="s3-check-mounts" \
    run "$BIN/register-backup-plan"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(hooks)" = "1 s3-check-mounts pre-backup True
2 backup-cluster-postgres pre-backup False" ] || fail "$(hooks)"
}

@test "without BORG_PLAN_PRE_AGENT_SCRIPTS_CONTINUE every hook stops the run on failure" {
  BORG_PLAN_PRE_AGENT_SCRIPTS="backup-cluster-mariadb" run "$BIN/register-backup-plan"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(hooks)" = "1 backup-cluster-mariadb pre-backup False" ] || fail "$(hooks)"
}

@test "without pre-backup scripts the plan carries no hooks" {
  run "$BIN/register-backup-plan"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  python3 -c 'import json,sys; sys.exit("script_hooks" in json.load(open(sys.argv[1])))' "$TMP/payload" \
    || fail "$(cat "$TMP/payload")"
}
