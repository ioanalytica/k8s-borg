#!/usr/bin/env bats
#
# register-backup-plan: the hooks it sends with a plan. Every name in
# BORG_PLAN_PRE_AGENT_SCRIPTS becomes an agent-script hook in that order; the
# names also in BORG_PLAN_PRE_AGENT_SCRIPTS_CONTINUE carry continue_on_error, so
# that Borg UI runs the backup when they fail and shows the failure as a
# warning. BORG_PLAN_POST_AGENT_SCRIPTS run after the backup, whatever its
# result. Without names the plan carries no hooks, and Borg UI keeps the ones it
# has. With BORG_PLAN_OWNED_AGENT_SCRIPTS (the node plan's datastore snapshot)
# only the owned hooks are replaced or removed; the plan keeps the others.
# A node plan carries --one-file-system in its custom flags, a cluster plan
# does not. A node with no existing root left disables its plan instead of
# leaving it unchanged; a cluster plan is left unchanged.
#
# curl is a stub that answers the endpoints the script talks to and keeps the
# plan payload in $TMP/payload. An existing plan (id 1) is $TMP/plan, disabled
# when $TMP/plan-disabled exists; a toggle of it is counted in $TMP/toggled.

bats_require_minimum_version 1.5.0

setup() {
  load helpers/common
  common_setup
  unset BORG_UI_JWT BORG_UI_ADMIN_USER BORG_UI_ADMIN_PASS BORG_BACKUP_CRON \
        BORG_PLAN_PRE_AGENT_SCRIPTS BORG_PLAN_PRE_AGENT_SCRIPTS_CONTINUE BORG_PLAN_CUSTOM_FLAGS \
        BORG_PLAN_POST_AGENT_SCRIPTS BORG_PLAN_OWNED_AGENT_SCRIPTS
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
  "GET http://ui/api/backup-plans/")
    if [ -f "$TMP/plan-disabled" ]; then printf '{"backup_plans": [{"id": 1, "name": "backup-console", "enabled": false}]}'
    elif [ -f "$TMP/plan" ]; then printf '{"backup_plans": [{"id": 1, "name": "backup-console", "enabled": true}]}'
    else printf '{"backup_plans": []}'; fi ;;
  "GET http://ui/api/backup-plans/1") cat "$TMP/plan" ;;
  "POST http://ui/api/backup-plans/1/toggle") echo toggle >>"$TMP/toggled"; printf '{"id": 1, "enabled": false}' ;;
  "POST http://ui/api/backup-plans/") printf '%s' "\$data" >"$TMP/payload"; printf '{"id": 1}' >"\$out"; printf 201 ;;
  "PUT http://ui/api/backup-plans/1") printf '%s' "\$data" >"$TMP/payload"; printf '{"id": 1}' >"\$out"; printf 200 ;;
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

# hooks_with_library — like hooks, with a library script as "lib:<id>".
hooks_with_library() {
  python3 -c '
import json, sys
for h in json.load(open(sys.argv[1])).get("script_hooks", []):
    name = h.get("agent_script_name") or "lib:%s" % h["script_id"]
    print(h["execution_order"], name, h["hook_type"], h["continue_on_error"])' "$TMP/payload"
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

@test "post-backup scripts run after the backup whatever its result" {
  BORG_PLAN_PRE_AGENT_SCRIPTS="datastore-snapshot" \
  BORG_PLAN_PRE_AGENT_SCRIPTS_CONTINUE="datastore-snapshot" \
  BORG_PLAN_POST_AGENT_SCRIPTS="datastore-snapshot-clean" \
    run "$BIN/register-backup-plan"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(hooks)" = "1 datastore-snapshot pre-backup True
1 datastore-snapshot-clean post-backup False" ] || fail "$(hooks)"
  python3 -c '
import json, sys
post = [h for h in json.load(open(sys.argv[1]))["script_hooks"] if h["hook_type"] == "post-backup"]
sys.exit(post[0].get("custom_run_on") != "always")' "$TMP/payload" || fail "$(cat "$TMP/payload")"
}

# existing_plan HOOK… — plan 1 exists with these hooks, each "type name order".
existing_plan() {
  python3 - "$TMP/plan" "$@" <<'PY'
import json, sys
hooks = []
for spec in sys.argv[2:]:
    kind, name, order = spec.split()
    hook = {"id": len(hooks) + 10, "hook_type": kind, "execution_order": float(order),
            "enabled": True, "custom_timeout": None, "custom_run_on": None,
            "continue_on_error": False, "skip_on_failure": False, "parameter_values": None,
            "script_id": None, "agent_script_name": None}
    if name.startswith("lib:"):
        hook["script_id"] = int(name[4:])
        hook["parameter_values"] = {"KEY": "v"}
    else:
        hook["agent_script_name"] = name
    hooks.append(hook)
json.dump({"id": 1, "name": "backup-console", "script_hooks": hooks}, open(sys.argv[1], "w"))
PY
}

owned=(BORG_PLAN_OWNED_AGENT_SCRIPTS="datastore-snapshot datastore-snapshot-clean")

@test "owned hooks: the plan keeps its other hooks, ours run last before and first after" {
  existing_plan "pre-backup notify-start 1" "pre-backup lib:7 2" "post-backup notify-end 1"
  env "${owned[@]}" \
    BORG_PLAN_PRE_AGENT_SCRIPTS="datastore-snapshot" \
    BORG_PLAN_PRE_AGENT_SCRIPTS_CONTINUE="datastore-snapshot" \
    BORG_PLAN_POST_AGENT_SCRIPTS="datastore-snapshot-clean" \
    "$BIN/register-backup-plan" >/dev/null || fail "register-backup-plan failed"
  [ "$(hooks_with_library)" = "1 notify-start pre-backup False
2 lib:7 pre-backup False
3 datastore-snapshot pre-backup True
1 datastore-snapshot-clean post-backup False
2 notify-end post-backup False" ] || fail "$(hooks_with_library)"
  python3 -c '
import json, sys
lib = [h for h in json.load(open(sys.argv[1]))["script_hooks"] if h.get("script_id") == 7][0]
sys.exit(lib["parameter_values"] != {"KEY": "v"} or "id" in lib)' "$TMP/payload" \
    || fail "$(cat "$TMP/payload")"
}

@test "owned hooks: a second run replaces ours instead of adding them again" {
  existing_plan "pre-backup notify-start 1" "pre-backup datastore-snapshot 2" "post-backup datastore-snapshot-clean 1"
  env "${owned[@]}" \
    BORG_PLAN_PRE_AGENT_SCRIPTS="datastore-snapshot" \
    BORG_PLAN_POST_AGENT_SCRIPTS="datastore-snapshot-clean" \
    "$BIN/register-backup-plan" >/dev/null || fail "register-backup-plan failed"
  [ "$(hooks_with_library)" = "1 notify-start pre-backup False
2 datastore-snapshot pre-backup False
1 datastore-snapshot-clean post-backup False" ] || fail "$(hooks_with_library)"
}

@test "owned hooks: switched off, ours are removed and the others stay" {
  existing_plan "pre-backup datastore-snapshot 1" "pre-backup notify-start 2" "post-backup datastore-snapshot-clean 1"
  env "${owned[@]}" "$BIN/register-backup-plan" >/dev/null || fail "register-backup-plan failed"
  [ "$(hooks_with_library)" = "1 notify-start pre-backup False" ] || fail "$(hooks_with_library)"
}

@test "owned hooks: none configured and none on the plan leaves the plan's hooks alone" {
  existing_plan "pre-backup notify-start 1"
  env "${owned[@]}" "$BIN/register-backup-plan" >/dev/null || fail "register-backup-plan failed"
  python3 -c 'import json,sys; sys.exit("script_hooks" in json.load(open(sys.argv[1])))' "$TMP/payload" \
    || fail "$(cat "$TMP/payload")"
}

@test "owned hooks on a new plan: just ours" {
  env "${owned[@]}" BORG_PLAN_PRE_AGENT_SCRIPTS="datastore-snapshot" \
    "$BIN/register-backup-plan" >/dev/null || fail "register-backup-plan failed"
  [ "$(hooks_with_library)" = "1 datastore-snapshot pre-backup False" ] || fail "$(hooks_with_library)"
}


# --- node plans: --one-file-system (#64) ---------------------------------------

# custom_flags — the plan's custom_flags, empty when it has none.
custom_flags() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("custom_flags") or "")' "$TMP/payload"
}

node_patterns() {
  {
    for line in "$@"; do echo "$line"; done
  } >"$TMP/patterns/node-include.patterns"
  : >"$TMP/patterns/node-exclude.patterns"
}

@test "a node plan stays on the node's own file systems" {
  node_patterns "R $TMP"
  BORG_MODE=node run "$BIN/register-backup-plan"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(custom_flags)" = "--one-file-system" ] || fail "$(custom_flags)"
}

@test "a node plan keeps the operator's flags first and adds --one-file-system once" {
  node_patterns "R $TMP"
  BORG_MODE=node BORG_PLAN_CUSTOM_FLAGS="--exclude-caches" run "$BIN/register-backup-plan"
  [ "$(custom_flags)" = "--exclude-caches --one-file-system" ] || fail "$(custom_flags)"
  BORG_MODE=node BORG_PLAN_CUSTOM_FLAGS="--one-file-system --exclude-caches" run "$BIN/register-backup-plan"
  [ "$(custom_flags)" = "--one-file-system --exclude-caches" ] || fail "$(custom_flags)"
  BORG_MODE=node BORG_PLAN_CUSTOM_FLAGS="-x" run "$BIN/register-backup-plan"
  [ "$(custom_flags)" = "-x" ] || fail "$(custom_flags)"
}

@test "a cluster plan follows mounts" {
  run "$BIN/register-backup-plan"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ -z "$(custom_flags)" ] || fail "$(custom_flags)"
}

# --- no source left (#58) ------------------------------------------------------

@test "a node with no existing root disables its plan, without a PUT" {
  existing_plan
  node_patterns "R $TMP/gone" "# only a comment"
  BORG_MODE=node run "$BIN/register-backup-plan"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [[ "$output" == *"Backup plan 'backup-console' disabled: no existing 'R <root>' source paths on this node"* ]] \
    || fail "$output"
  [ "$(cat "$TMP/toggled")" = "toggle" ] || fail "toggled: $(cat "$TMP/toggled" 2>/dev/null)"
  [ ! -e "$TMP/payload" ] || fail "plan sent: $(cat "$TMP/payload")"
}

@test "a node plan already disabled is not toggled again" {
  existing_plan
  touch "$TMP/plan-disabled"
  node_patterns
  BORG_MODE=node run "$BIN/register-backup-plan"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [[ "$output" == *"Backup plan 'backup-console' stays disabled"* ]] || fail "$output"
  [ ! -e "$TMP/toggled" ] || fail "toggled"
}

@test "a node with no existing root and no plan creates none" {
  node_patterns "R $TMP/gone"
  BORG_MODE=node run "$BIN/register-backup-plan"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [[ "$output" == *"Backup plan 'backup-console' not created"* ]] || fail "$output"
  [ ! -e "$TMP/payload" ] && [ ! -e "$TMP/toggled" ] || fail "plan touched"
}

@test "a disabled node plan is enabled again once a root exists" {
  existing_plan
  touch "$TMP/plan-disabled"
  node_patterns "R $TMP"
  BORG_MODE=node run "$BIN/register-backup-plan"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  python3 -c 'import json,sys; sys.exit(json.load(open(sys.argv[1]))["enabled"] is not True)' "$TMP/payload" \
    || fail "$(cat "$TMP/payload")"
}

@test "a cluster plan with no existing root is left unchanged" {
  existing_plan
  echo "R $TMP/gone" >"$TMP/patterns/cluster-include.patterns"
  run "$BIN/register-backup-plan"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [[ "$output" == *"leaving backup plan unchanged"* ]] || fail "$output"
  [ ! -e "$TMP/payload" ] && [ ! -e "$TMP/toggled" ] || fail "plan touched"
}

@test "a node plan names the node's partitions below a root that --one-file-system skips" {
  node_patterns "R $TMP"
  printf '1 0 8:0 / / rw - ext4 /dev/sda1 rw\n2 1 8:1 / %s rw - ext4 /dev/sdb1 rw\n3 1 0:9 / %s rw - tmpfs tmpfs rw\n' \
    "$TMP/patterns" "$TMP/schedules" >"$TMP/mountinfo"
  BORG_MODE=node NODE_MOUNTINFO="$TMP/mountinfo" run "$BIN/register-backup-plan"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [[ "$output" == *"WARNING: file systems of the node below a root are skipped by --one-file-system"* ]] || fail "$output"
  [[ "$output" == *"$TMP/patterns (ext4 /dev/sdb1)"* ]] || fail "$output"
  [[ "$output" != *"$TMP/schedules"* ]] || fail "$output"
}
