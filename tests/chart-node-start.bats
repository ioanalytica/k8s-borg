#!/usr/bin/env bats
#
# The start command of the node pods. In interval mode it runs /run.sh again
# after node.backupIntervalSeconds, whatever the run returned. As an agent,
# /run.sh returns only when the start (borg-init, the enrolment, the repository
# or the plan) or the agent failed: the container then ends with its status,
# so that the kubelet starts it again with its back-off, instead of the pod
# sleeping for the interval. sh stays the parent of /run.sh (PID 1 in the
# pod), which reaps orphaned processes.
#
# The rendered script runs under /bin/sh with /run.sh, hostname and sleep as
# stubs. The run.sh stub notes its arguments and its parent's PID in
# $TMP/runs, exits with the status in $TMP/rc and kills its parent from the
# second run on, which ends the loop; sleep notes its argument in $TMP/slept.

setup() {
  load helpers/common
  common_setup
  command -v helm >/dev/null || fail "helm is required for the chart tests"
  CHART="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/chart"
  VALUES="$BATS_TEST_TMPDIR/values.yaml"
  cat >"$VALUES" <<'YAML'
borg:
  passphrase:
    value: "test"
  repoBase:
    value: "ssh://borg@backup.example.com/./cluster"
ssh:
  privateKey: "test"
  publicKey: "test"
  knownHosts: "test"
YAML
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\n' >"$TMP/bin/hostname"
  cat >"$TMP/bin/sleep" <<EOF
#!/bin/sh
echo "\$1" >> "$TMP/slept"
EOF
  cat >"$TMP/run.sh" <<EOF
#!/bin/sh
echo "\$* \$PPID" >> "$TMP/runs"
[ "\$(wc -l < "$TMP/runs")" -lt 2 ] || kill -KILL "\$PPID"
exit "\$(cat "$TMP/rc")"
EOF
  chmod +x "$TMP/bin/hostname" "$TMP/bin/sleep" "$TMP/run.sh"
}

teardown() { common_teardown; }

agent=(--set node.backupMode=agent --set borgUI.agentConnection.server=http://ui.example:8081
       --set borgUI.adminPassword.value=pw)

# container FIELD [HELM ARGS…] — that field of the node container, as JSON.
container() {
  local field=$1; shift
  helm template rel "$CHART" -n backup -f "$VALUES" "$@" | python3 -c '
import json, sys, yaml
for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc.get("kind") == "DaemonSet":
        print(json.dumps(doc["spec"]["template"]["spec"]["containers"][0][sys.argv[1]]))' "$field"
}

# start RC [HELM ARGS…] — run the start script with run.sh exiting RC; sets
# $status to the script's and $pid to the shell's PID.
start() {
  local script
  printf '%s' "$1" >"$TMP/rc"; shift
  script=$(container args "$@" | python3 -c 'import json, sys; print(json.load(sys.stdin)[0])')
  [ -n "$script" ] || fail "no start script rendered"
  script=${script//\/run.sh/$TMP/run.sh}
  status=0
  PATH="$TMP/bin:$PATH" /bin/sh -c "$script" &
  pid=$!
  wait "$pid" || status=$?
}

@test "the start script runs under /bin/sh" {
  [ "$(container command)" = '["/bin/sh", "-c"]' ] || fail "$(container command)"
  [ "$(container command "${agent[@]}")" = '["/bin/sh", "-c"]' ] || fail "$(container command "${agent[@]}")"
}

@test "as an agent, a failed start ends the container with its status" {
  start 3 "${agent[@]}"
  [ "$status" -eq 3 ] || fail "status $status"
  [ "$(cat "$TMP/runs")" = "run $pid" ] || fail "runs: $(cat "$TMP/runs"), shell $pid"
  [ ! -e "$TMP/slept" ] || fail "slept $(cat "$TMP/slept")"
}

@test "as an agent, also an agent that ended without an error" {
  start 0 "${agent[@]}"
  [ "$status" -eq 0 ] || fail "status $status"
  [ "$(cat "$TMP/runs")" = "run $pid" ] || fail "runs: $(cat "$TMP/runs"), shell $pid"
  [ ! -e "$TMP/slept" ] || fail "slept $(cat "$TMP/slept")"
}

@test "in interval mode, /run.sh runs again after the interval, also after a failed run" {
  start 3 --set node.backupIntervalSeconds=42
  [ "$(cat "$TMP/runs")" = "run $pid
run $pid" ] || fail "runs: $(cat "$TMP/runs"), shell $pid"
  [ "$(cat "$TMP/slept")" = 42 ] || fail "slept $(cat "$TMP/slept")"
}
