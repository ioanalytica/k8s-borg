#!/usr/bin/env bats
#
# node.tmpDir, cluster.tmpDir: the scratch volume of a managed agent. The agent
# extracts a restore check into a temporary directory, the whole archive in
# Full Archive mode. The node pods (node.backupMode=agent) and the console pod
# (cluster.mode=agent) get a volume for it, with TMPDIR pointing there, instead
# of the container's writable layer: an emptyDir, with a size limit or in
# memory when set, or any other volume. The volume outlives the container, so
# the pod's start script empties the directory before /run.sh. Pods that run
# no agent get none, and /tmp stays free for a mount of the install's own.

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
borgUI:
  agentConnection:
    server: http://ui.example:8081
  adminPassword:
    value: pw
YAML
}

teardown() { common_teardown; }

node_agent=(--set node.backupMode=agent)
cluster_agent=(--set cluster.mode=agent)

# q KIND EXPR [HELM ARGS…] — a Python expression over the first document of
# KIND (as `d`), its pod spec (`spec`), its first container (`c`) and that
# container's environment (`env`), printed. A CronJob's pod spec is the job's.
q() {
  local kind=$1 expr=$2; shift 2
  helm template rel "$CHART" -n backup -f "$VALUES" "$@" | python3 -c '
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get("kind") == sys.argv[1]:
        break
else:
    sys.exit("no " + sys.argv[1])
template = d["spec"].get("jobTemplate", d)["spec"]["template"]
spec = template["spec"]
c = spec["containers"][0]
env = {e["name"]: e.get("value", e.get("valueFrom")) for e in c.get("env", [])}
volume = [v for v in spec["volumes"] if v["name"] == "agent-tmp"]
mount = [m for m in c["volumeMounts"] if m["name"] == "agent-tmp"]
print(eval(sys.argv[2]))' "$kind" "$expr"
}

# start KIND [HELM ARGS…] — run the start script of KIND's first container
# under /bin/sh, with $TMP/scratch in place of the agent's directory and
# stubs for hostname and /run.sh; run.sh notes in $TMP/seen what the
# directory held when it was called.
start() {
  local kind=$1 script; shift
  script="$(q "$kind" 'c["args"][0]' "$@")"
  [[ $script == *"/run.sh"* ]] || fail "no start script rendered: $script"
  script=${script//\/run.sh/\"\$RUN_SH\"}
  script=${script//\/var\/lib\/k8s-borg\/tmp/\"\$SCRATCH\"}
  [[ $script != *"/var/lib/"* ]] || fail "the start script names a path of the machine: $script"
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\n' >"$TMP/bin/hostname"
  cat >"$TMP/run.sh" <<EOF
#!/bin/sh
{ ls -A "$TMP/scratch" 2>&1 || true; } >"$TMP/seen"
EOF
  chmod +x "$TMP/bin/hostname" "$TMP/run.sh"
  RUN_SH="$TMP/run.sh" SCRATCH="$TMP/scratch" PATH="$TMP/bin:$PATH" run /bin/sh -c "$script"
}

@test "a node agent gets an emptyDir for its temporary files, and TMPDIR points there" {
  [ "$(q DaemonSet 'volume' "${node_agent[@]}")" = "[{'name': 'agent-tmp', 'emptyDir': {}}]" ] \
    || fail "$(q DaemonSet 'volume' "${node_agent[@]}")"
  [ "$(q DaemonSet 'mount' "${node_agent[@]}")" \
    = "[{'name': 'agent-tmp', 'mountPath': '/var/lib/k8s-borg/tmp'}]" ] \
    || fail "$(q DaemonSet 'mount' "${node_agent[@]}")"
  [ "$(q DaemonSet 'env.get("TMPDIR")' "${node_agent[@]}")" = /var/lib/k8s-borg/tmp ] || fail
}

@test "the console pod as an agent gets the same, from cluster.tmpDir" {
  [ "$(q StatefulSet 'volume, mount, env.get("TMPDIR")' "${cluster_agent[@]}")" \
    = "([{'name': 'agent-tmp', 'emptyDir': {}}], [{'name': 'agent-tmp', 'mountPath': '/var/lib/k8s-borg/tmp'}], '/var/lib/k8s-borg/tmp')" ] \
    || fail "$(q StatefulSet 'volume, mount, env.get("TMPDIR")' "${cluster_agent[@]}")"
  # Each agent has its own settings.
  [ "$(q StatefulSet 'volume[0]["emptyDir"]' "${cluster_agent[@]}" "${node_agent[@]}" \
        --set node.tmpDir.sizeLimit=50Gi)" = "{}" ] || fail
  [ "$(q DaemonSet 'volume[0]["emptyDir"]' "${cluster_agent[@]}" "${node_agent[@]}" \
        --set cluster.tmpDir.sizeLimit=50Gi)" = "{}" ] || fail
}

@test "pods that run no agent keep their temporary files where they were" {
  [ "$(q DaemonSet 'volume, mount, "TMPDIR" in env')" = "([], [], False)" ] || fail
  [ "$(q StatefulSet 'volume, mount, "TMPDIR" in env')" = "([], [], False)" ] || fail
  # The CronJob shares cluster.* with the console pod, but runs no agent.
  [ "$(q CronJob 'volume, mount, "TMPDIR" in env' "${cluster_agent[@]}")" = "([], [], False)" ] || fail
}

@test "a size limit and the medium reach the emptyDir" {
  [ "$(q DaemonSet 'volume[0]["emptyDir"]' "${node_agent[@]}" --set node.tmpDir.sizeLimit=50Gi)" \
    = "{'sizeLimit': '50Gi'}" ] || fail
  [ "$(q DaemonSet 'volume[0]["emptyDir"]' "${node_agent[@]}" --set node.tmpDir.medium=Memory \
        --set node.tmpDir.sizeLimit=1Gi)" = "{'medium': 'Memory', 'sizeLimit': '1Gi'}" ] || fail
  [ "$(q StatefulSet 'volume[0]["emptyDir"]' "${cluster_agent[@]}" --set cluster.tmpDir.sizeLimit=20Gi \
        --set cluster.tmpDir.medium=Memory)" = "{'medium': 'Memory', 'sizeLimit': '20Gi'}" ] || fail
  # A bare number of bytes, as --set delivers it, stays a quantity.
  [ "$(q DaemonSet 'volume[0]["emptyDir"]' "${node_agent[@]}" --set node.tmpDir.sizeLimit=1073741824)" \
    = "{'sizeLimit': '1073741824'}" ] || fail
}

@test "another volume takes the emptyDir's place, each pod in a directory of its own" {
  local claim='{"ephemeral":{"volumeClaimTemplate":{"spec":{"accessModes":["ReadWriteOnce"],"resources":{"requests":{"storage":"200Gi"}}}}}}'
  [ "$(q DaemonSet 'sorted(volume[0]), volume[0]["ephemeral"]["volumeClaimTemplate"]["spec"]["resources"]' \
        "${node_agent[@]}" --set-json "node.tmpDir.volume=$claim")" \
    = "(['ephemeral', 'name'], {'requests': {'storage': '200Gi'}})" ] || fail
  # A volume several agents share (a claim, a host path, also with other
  # releases) holds one directory per pod, <namespace>/<workload>/<NODE_NAME>:
  # an agent that starts clears only its own.
  [ "$(q DaemonSet 'mount' "${node_agent[@]}" --set-json "node.tmpDir.volume=$claim")" \
    = "[{'name': 'agent-tmp', 'mountPath': '/var/lib/k8s-borg/tmp', 'subPathExpr': 'backup/rel-k8s-borg-node/\$(NODE_NAME)'}]" ] \
    || fail "$(q DaemonSet 'mount' "${node_agent[@]}" --set-json "node.tmpDir.volume=$claim")"
  [ "$(q StatefulSet 'volume, mount' "${cluster_agent[@]}" \
        --set-json 'cluster.tmpDir.volume={"hostPath":{"path":"/data/scratch","type":"DirectoryOrCreate"}}')" \
    = "([{'name': 'agent-tmp', 'hostPath': {'path': '/data/scratch', 'type': 'DirectoryOrCreate'}}], [{'name': 'agent-tmp', 'mountPath': '/var/lib/k8s-borg/tmp', 'subPathExpr': 'backup/rel-k8s-borg-app/\$(NODE_NAME)'}])" ] \
    || fail
}

@test "values without the section, as after --reuse-values from an older chart, get the emptyDir" {
  # --reuse-values takes the defaults of the chart the release was installed
  # with; null removes the key from the coalesced values the same way.
  local unset=(--set node.tmpDir=null --set cluster.tmpDir=null)
  [ "$(q DaemonSet 'volume, mount' "${node_agent[@]}" "${unset[@]}")" \
    = "([{'name': 'agent-tmp', 'emptyDir': {}}], [{'name': 'agent-tmp', 'mountPath': '/var/lib/k8s-borg/tmp'}])" ] \
    || fail "$(q DaemonSet 'volume, mount' "${node_agent[@]}" "${unset[@]}" 2>&1)"
  [ "$(q StatefulSet 'volume, mount' "${cluster_agent[@]}" "${unset[@]}")" \
    = "([{'name': 'agent-tmp', 'emptyDir': {}}], [{'name': 'agent-tmp', 'mountPath': '/var/lib/k8s-borg/tmp'}])" ] \
    || fail "$(q StatefulSet 'volume, mount' "${cluster_agent[@]}" "${unset[@]}" 2>&1)"
  # Also with both agents off.
  run helm template rel "$CHART" -n backup -f "$VALUES" "${unset[@]}"
  [ "$status" -eq 0 ] || fail "$output"
}

@test "a volume of its own takes neither size limit nor medium from the chart" {
  local key
  for key in sizeLimit medium; do
    run helm template rel "$CHART" -n backup -f "$VALUES" "${node_agent[@]}" \
      --set-json 'node.tmpDir.volume={"hostPath":{"path":"/data/scratch"}}' --set "node.tmpDir.$key=Memory"
    [ "$status" -ne 0 ] || fail "rendered node.tmpDir.volume with $key"
    [[ $output == *"node.tmpDir.volume replaces the emptyDir: node.tmpDir.sizeLimit and node.tmpDir.medium do not apply to it"* ]] \
      || fail "$output"
    run helm template rel "$CHART" -n backup -f "$VALUES" "${cluster_agent[@]}" \
      --set-json 'cluster.tmpDir.volume={"hostPath":{"path":"/data/scratch"}}' --set "cluster.tmpDir.$key=Memory"
    [ "$status" -ne 0 ] || fail "rendered cluster.tmpDir.volume with $key"
    [[ $output == *"cluster.tmpDir.volume replaces the emptyDir: cluster.tmpDir.sizeLimit and cluster.tmpDir.medium do not apply to it"* ]] \
      || fail "$output"
  done
}

@test "/tmp stays free: an install that mounts its own volume there still renders one mount per path" {
  local extra="$BATS_TEST_TMPDIR/extra.yaml"
  cat >"$extra" <<'YAML'
extraVolumes:
  - name: scratch
    emptyDir: {}
extraVolumeMounts:
  - name: scratch
    mountPath: /tmp
YAML
  local kind
  for kind in DaemonSet StatefulSet; do
    [ "$(q "$kind" 'sorted(p for p in [m["mountPath"] for m in c["volumeMounts"]] if [m["mountPath"] for m in c["volumeMounts"]].count(p) > 1)' \
          "${node_agent[@]}" "${cluster_agent[@]}" -f "$extra")" = "[]" ] || fail "$kind mounts a path twice"
    [ "$(q "$kind" '[m["name"] for m in c["volumeMounts"] if m["mountPath"] == "/tmp"]' \
          "${node_agent[@]}" "${cluster_agent[@]}" -f "$extra")" = "['scratch']" ] || fail "$kind: /tmp"
  done
}

@test "an agent pod that starts empties its directory before /run.sh, hidden files and all" {
  local kind
  for kind in DaemonSet StatefulSet; do
    mkdir -p "$TMP/scratch/borg-ui-restore-abc/data" "$TMP/scratch/tmp.Xyz" "$TMP/scratch/.hidden"
    touch "$TMP/scratch/borg-ui-restore-abc/data/file" "$TMP/scratch/borg-ui-rclone-x.conf" "$TMP/scratch/.dot"
    start "$kind" "${node_agent[@]}" "${cluster_agent[@]}"
    [ "$status" -eq 0 ] || fail "$kind: $output"
    [ -d "$TMP/scratch" ] || fail "$kind: the directory itself is gone"
    [ -e "$TMP/seen" ] && [ ! -s "$TMP/seen" ] || fail "$kind: /run.sh saw: $(cat "$TMP/seen")"
    [ -z "$output" ] || fail "$kind: $output"
    rm -f "$TMP/seen"
  done
}

@test "the start script names the directory itself, and starts without it" {
  # Not $TMPDIR: outside the pod that is the caller's own directory.
  local kind script
  for kind in DaemonSet StatefulSet; do
    script="$(q "$kind" 'c["args"][0]' "${node_agent[@]}" "${cluster_agent[@]}")"
    [[ $script == *"find /var/lib/k8s-borg/tmp -mindepth 1 "* ]] || fail "$kind: $script"
    [[ $script != *TMPDIR* ]] || fail "$kind: $script"
    start "$kind" "${node_agent[@]}" "${cluster_agent[@]}"
    [ "$status" -eq 0 ] && [ -z "$output" ] || fail "$kind without the directory: $output"
    [ -e "$TMP/seen" ] || fail "$kind: /run.sh did not run"
    rm -f "$TMP/seen"
  done
}

@test "pods that run no agent empty nothing" {
  [[ "$(q DaemonSet 'c["args"][0]')" != *"k8s-borg/tmp"* ]] || fail "$(q DaemonSet 'c["args"][0]')"
  [[ "$(q StatefulSet 'c["args"][0]')" != *"k8s-borg/tmp"* ]] || fail "$(q StatefulSet 'c["args"][0]')"
  [[ "$(q CronJob 'c["args"][0]' "${cluster_agent[@]}")" != *"k8s-borg/tmp"* ]] || fail
}
