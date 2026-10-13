#!/usr/bin/env bats
#
# node.sqlite: what the node pods get to copy the listed SQLite databases.
# The list in the config, the copy directory on the node's disk and archived,
# HostToContainer propagation on the read-only host root, their own
# ServiceAccount with get on exactly the listed claims and on volumes, the
# step in the interval run and, in agent mode, the hooks of the node plan,
# next to the datastore snapshot. Invalid lists fail the render.

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
  ON="$BATS_TEST_TMPDIR/sqlite.yaml"
  cat >"$ON" <<'YAML'
node:
  sqlite:
    enabled: true
    databases:
      - {namespace: vaultwarden, pvc: vaultwarden-data, path: db.sqlite3}
      - {namespace: git, pvc: gitea-data, path: gitea/gitea.db}
      - {namespace: git, pvc: gitea-data, path: queues.db}
      - {namespace: git, pvc: runner-data, path: runner.db}
YAML
}

teardown() { common_teardown; }

agent=(--set node.backupMode=agent --set borgUI.agentConnection.server=http://ui.example:8081
       --set borgUI.adminPassword.value=pw)

# render KIND [HELM ARGS…] — the rendered documents of that kind as JSON lines.
render() {
  local kind=$1; shift
  helm template rel "$CHART" -n backup -f "$VALUES" "$@" | python3 -c '
import json, sys, yaml
for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc.get("kind") == sys.argv[1]:
        print(json.dumps(doc))' "$kind"
}

# q KIND EXPR [HELM ARGS…] — a Python expression over the first document of
# KIND (as `d`) and its first container (as `c`), printed.
q() {
  local kind=$1 expr=$2; shift 2
  render "$kind" "$@" | head -1 | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
spec = d.get("spec", {}).get("template", {}).get("spec", {})
c = (spec.get("containers") or [{}])[0]
env = {e["name"]: e.get("value", e.get("valueFrom")) for e in c.get("env", [])}
print(eval(sys.argv[1]))' "$expr"
}

# config KEY [HELM ARGS…] — a key of the chart's config ConfigMap.
config() {
  local key=$1; shift
  render ConfigMap "$@" | python3 -c '
import json, sys
for line in sys.stdin:
    d = json.loads(line)
    if d["metadata"]["name"].endswith("-config"):
        print(d["data"].get(sys.argv[1], ""))' "$key"
}

# rbac [HELM ARGS…] — "KIND NAMESPACE NAME RULES-or-SUBJECTS" per RBAC object of
# the node pods, sorted.
rbac() {
  helm template rel "$CHART" -n backup -f "$VALUES" "$@" | python3 -c '
import json, sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and d["kind"] in ("ServiceAccount", "Role", "RoleBinding", "ClusterRole", "ClusterRoleBinding") \
            and "-node" in d["metadata"]["name"]:
        print(d["kind"], d["metadata"].get("namespace", "-"), d["metadata"]["name"],
              json.dumps(d.get("rules") or d.get("subjects") or [], sort_keys=True))' | LC_ALL=C sort
}

agent_scripts() { render ConfigMap "$@" | python3 -c '
import json, sys
for line in sys.stdin:
    d = json.loads(line)
    if d["metadata"]["name"].endswith("-node-agent-scripts"):
        print(" ".join(sorted(d["data"])))'; }

@test "off by default: no copies, no ServiceAccount, the host root as before" {
  [ "$(q DaemonSet '"SQLITE_COPY" in env, spec.get("serviceAccountName")')" = "(False, None)" ] || fail
  [ "$(q DaemonSet '[v["name"] for v in spec["volumes"] if v["name"] == "sqlite-copies"]')" = "[]" ] || fail
  [ "$(q DaemonSet '[m for m in c["volumeMounts"] if m["mountPath"] == "/node"]')" \
    = "[{'name': 'rootfs', 'mountPath': '/node', 'readOnly': True}]" ] || fail
  [ -z "$(config node-sqlite-databases.json)" ] || fail
  [[ "$(config node-include.patterns)" != *sqlite* ]] || fail
  [ -z "$(rbac)" ] || fail "$(rbac)"
}

@test "the list of databases reaches the node pods, and the copies are archived" {
  [ "$(config node-sqlite-databases.json -f "$ON")" \
    = '[{"namespace":"vaultwarden","path":"db.sqlite3","pvc":"vaultwarden-data"},{"namespace":"git","path":"gitea/gitea.db","pvc":"gitea-data"},{"namespace":"git","path":"queues.db","pvc":"gitea-data"},{"namespace":"git","path":"runner.db","pvc":"runner-data"}]' ] \
    || fail "$(config node-sqlite-databases.json -f "$ON")"
  [[ "$(config node-include.patterns -f "$ON" --set 'node.include={R /node/etc}')" == *"R /node/etc"*"R /var/lib/k8s-borg/sqlite"* ]] \
    || fail "$(config node-include.patterns -f "$ON")"
  [ "$(q DaemonSet 'env["SQLITE_COPY"], env["SQLITE_COPY_DIR"], env["SQLITE_BUSY_TIMEOUT"], env["KUBELET_DIR"]' -f "$ON")" \
    = "('true', '/var/lib/k8s-borg/sqlite', '60', '/var/lib/kubelet')" ] || fail
  [ "$(q DaemonSet 'env["SQLITE_BUSY_TIMEOUT"], env["KUBELET_DIR"]' -f "$ON" \
        --set node.sqlite.busyTimeout=5 --set node.sqlite.kubeletDir=/var/lib/k0s/kubelet)" \
    = "('5', '/var/lib/k0s/kubelet')" ] || fail
}

@test "the copies go to the node's disk, with the size limit when one is set" {
  [ "$(q DaemonSet '[v["emptyDir"] for v in spec["volumes"] if v["name"] == "sqlite-copies"]' -f "$ON")" = "[{}]" ] || fail
  [ "$(q DaemonSet '[v["emptyDir"] for v in spec["volumes"] if v["name"] == "sqlite-copies"]' -f "$ON" \
        --set node.sqlite.sizeLimit=5Gi)" = "[{'sizeLimit': '5Gi'}]" ] || fail
  [ "$(q DaemonSet '[m["mountPath"] for m in c["volumeMounts"] if m["name"] == "sqlite-copies"]' -f "$ON")" \
    = "['/var/lib/k8s-borg/sqlite']" ] || fail
}

@test "the host root stays read-only, now with HostToContainer propagation, and no other host path" {
  [ "$(q DaemonSet '[m for m in c["volumeMounts"] if m["mountPath"] == "/node"]' -f "$ON")" \
    = "[{'name': 'rootfs', 'mountPath': '/node', 'readOnly': True, 'mountPropagation': 'HostToContainer'}]" ] || fail
  [ "$(q DaemonSet '[v["hostPath"]["path"] for v in spec["volumes"] if "hostPath" in v]' -f "$ON")" = "['/']" ] || fail
}

@test "the node pods' ServiceAccount may get the listed claims, one Role per namespace, and volumes; nothing else" {
  run rbac -f "$ON"
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(q DaemonSet 'spec["serviceAccountName"]' -f "$ON")" = rel-k8s-borg-node ] || fail
  subject='[{"kind": "ServiceAccount", "name": "rel-k8s-borg-node", "namespace": "backup"}]'
  expected="ServiceAccount backup rel-k8s-borg-node []
ClusterRole - rel-k8s-borg-node-sqlite-backup [{\"apiGroups\": [\"\"], \"resources\": [\"persistentvolumes\"], \"verbs\": [\"get\"]}]
ClusterRoleBinding - rel-k8s-borg-node-sqlite-backup $subject
Role git rel-k8s-borg-node-sqlite-$(printf git | shasum -a 256 | cut -c1-10) [{\"apiGroups\": [\"\"], \"resourceNames\": [\"gitea-data\", \"runner-data\"], \"resources\": [\"persistentvolumeclaims\"], \"verbs\": [\"get\"]}]
RoleBinding git rel-k8s-borg-node-sqlite-$(printf git | shasum -a 256 | cut -c1-10) $subject
Role vaultwarden rel-k8s-borg-node-sqlite-$(printf vaultwarden | shasum -a 256 | cut -c1-10) [{\"apiGroups\": [\"\"], \"resourceNames\": [\"vaultwarden-data\"], \"resources\": [\"persistentvolumeclaims\"], \"verbs\": [\"get\"]}]
RoleBinding vaultwarden rel-k8s-borg-node-sqlite-$(printf vaultwarden | shasum -a 256 | cut -c1-10) $subject"
  expected=$(LC_ALL=C sort <<<"$expected")
  [ "$output" = "$expected" ] || fail "$(diff <(echo "$expected") <(echo "$output"))"
}

@test "with a reconcile gate in agent mode, the node ServiceAccount may still read the reconcile status" {
  set -- -f "$ON" --set node.backupMode=agent --set borgUI.enabled=true --set borgUI.adminPassword.value=pw
  [ "$(q DaemonSet 'spec["serviceAccountName"]' "$@")" = rel-k8s-borg-node ] || fail
  render RoleBinding "$@" | python3 -c '
import json, sys
for line in sys.stdin:
    d = json.loads(line)
    if d["metadata"]["name"] == "rel-k8s-borg-agent":
        sys.exit("rel-k8s-borg-node" not in [s["name"] for s in d["subjects"]])
sys.exit("no agent RoleBinding")' || fail "the node ServiceAccount is not bound to the agent Role"
}

@test "agent mode: the copy and its removal are published and attached to the node plan, around the datastore snapshot" {
  [ "$(agent_scripts -f "$ON" "${agent[@]}")" = "sqlite-copy sqlite-copy-clean" ] || fail "$(agent_scripts -f "$ON" "${agent[@]}")"
  [ "$(q DaemonSet 'env["BORG_PLAN_PRE_AGENT_SCRIPTS"], env["BORG_PLAN_PRE_AGENT_SCRIPTS_CONTINUE"], env["BORG_PLAN_POST_AGENT_SCRIPTS"]' -f "$ON" "${agent[@]}")" \
    = "('sqlite-copy', 'sqlite-copy', 'sqlite-copy-clean')" ] || fail
  set -- -f "$ON" "${agent[@]}" --set node.datastoreSnapshot.enabled=true
  [ "$(q DaemonSet 'env["BORG_PLAN_PRE_AGENT_SCRIPTS"], env["BORG_PLAN_PRE_AGENT_SCRIPTS_CONTINUE"], env["BORG_PLAN_POST_AGENT_SCRIPTS"]' "$@")" \
    = "('sqlite-copy datastore-snapshot', 'sqlite-copy datastore-snapshot', 'datastore-snapshot-clean sqlite-copy-clean')" ] || fail
  [ "$(q DaemonSet 'env["BORG_PLAN_OWNED_AGENT_SCRIPTS"]' "$@")" \
    = "datastore-snapshot datastore-snapshot-clean sqlite-copy sqlite-copy-clean" ] || fail
}

@test "enabled without databases, or a database without namespace, claim or a relative path, fails the render" {
  run helm template rel "$CHART" -n backup -f "$VALUES" --set node.sqlite.enabled=true
  [ "$status" -ne 0 ] && [[ "$output" == *"node.sqlite.databases is empty"* ]] || fail "$output"
  for entry in '{pvc: data, path: a.db}' '{namespace: app, path: a.db}' '{namespace: app, pvc: data}' \
               '{namespace: app, pvc: data, path: /data/a.db}' '{namespace: app, pvc: data, path: ../a.db}' \
               '{namespace: App, pvc: data, path: a.db}' '{namespace: app, pvc: Data_1, path: a.db}'; do
    printf 'node:\n  sqlite:\n    enabled: true\n    databases:\n      - %s\n' "$entry" >"$BATS_TEST_TMPDIR/bad.yaml"
    run helm template rel "$CHART" -n backup -f "$VALUES" -f "$BATS_TEST_TMPDIR/bad.yaml"
    [ "$status" -ne 0 ] && [[ "$output" == *"node.sqlite.databases[0]"* ]] || fail "$entry: $output"
  done
}
