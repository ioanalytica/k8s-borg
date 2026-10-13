#!/usr/bin/env bats
#
# node.datastoreSnapshot: where the snapshot runs and with which rights. The
# node DaemonSet reaches every control-plane node by default (it tolerates
# their NoSchedule taint); the snapshot volume is memory-backed; the host root
# stays read-only and the host network stays off unless asked for; the
# snapshot directory is archived. In agent mode the snapshot and its removal
# are published to the node agent and attached to the node plan.

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
}

teardown() { common_teardown; }

on=(--set node.datastoreSnapshot.enabled=true)
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

node_cm() { render ConfigMap "$@" | python3 -c '
import json, sys
for line in sys.stdin:
    d = json.loads(line)
    if "node-include.patterns" in d.get("data", {}):
        print(d["data"]["node-include.patterns"])'; }

agent_scripts() { render ConfigMap "$@" | python3 -c '
import json, sys
for line in sys.stdin:
    d = json.loads(line)
    if d["metadata"]["name"].endswith("-node-agent-scripts"):
        print(" ".join(sorted(d["data"])))'; }

@test "off by default: no snapshot volume, no node IP, nothing extra archived" {
  [ "$(q DaemonSet '"DATASTORE_SNAPSHOT" in env or "HOST_IP" in env')" = False ] || fail
  [ "$(q DaemonSet '[v["name"] for v in spec["volumes"] if v["name"] == "datastore-snapshot"]')" = "[]" ] || fail
  [[ "$(node_cm)" != *datastore* ]] || fail "$(node_cm)"
}

@test "the node pods reach the control-plane nodes: they tolerate NoSchedule taints" {
  [ "$(q DaemonSet 'spec["tolerations"] == [{"operator": "Exists", "effect": "NoSchedule"}]' "${on[@]}")" = True ] \
    || fail "$(q DaemonSet 'spec["tolerations"]' "${on[@]}")"
  [ "$(q DaemonSet 'spec.get("nodeSelector")' "${on[@]}")" = None ] || fail
}

@test "the snapshot volume is memory-backed with the size limit" {
  [ "$(q DaemonSet '[v["emptyDir"] for v in spec["volumes"] if v["name"] == "datastore-snapshot"]' "${on[@]}")" \
    = "[{'medium': 'Memory', 'sizeLimit': '2Gi'}]" ] || fail
  [ "$(q DaemonSet '[m["mountPath"] for m in c["volumeMounts"] if m["name"] == "datastore-snapshot"]' "${on[@]}")" \
    = "['/var/lib/k8s-borg/datastore']" ] || fail
  [ "$(q DaemonSet '[v["emptyDir"] for v in spec["volumes"] if v["name"] == "datastore-snapshot"]' "${on[@]}" \
        --set node.datastoreSnapshot.sizeLimit=8Gi)" = "[{'medium': 'Memory', 'sizeLimit': '8Gi'}]" ] || fail
}

@test "the host root stays read-only and no other host path is added" {
  [ "$(q DaemonSet '[m.get("readOnly") for m in c["volumeMounts"] if m["mountPath"] == "/node"]' "${on[@]}")" = "[True]" ] || fail
  [ "$(q DaemonSet '[v["hostPath"]["path"] for v in spec["volumes"] if "hostPath" in v]' "${on[@]}")" = "['/']" ] || fail
}

@test "etcd at the node IP, without the host network" {
  [ "$(q DaemonSet 'env["DATASTORE_ETCD_ENDPOINT"]' "${on[@]}")" = 'https://$(HOST_IP):2379' ] || fail
  [ "$(q DaemonSet 'env["HOST_IP"]' "${on[@]}")" = "{'fieldRef': {'fieldPath': 'status.hostIP'}}" ] || fail
  [ "$(q DaemonSet 'spec.get("hostNetwork")' "${on[@]}")" = None ] || fail
  # HOST_IP must come first, or Kubernetes does not expand $(HOST_IP).
  [ "$(q DaemonSet '[e["name"] for e in c["env"]].index("HOST_IP") < [e["name"] for e in c["env"]].index("DATASTORE_ETCD_ENDPOINT")' "${on[@]}")" = True ] || fail
}

@test "hostNetwork: the host network, cluster DNS, and etcd at localhost" {
  set -- "${on[@]}" --set node.datastoreSnapshot.hostNetwork=true
  [ "$(q DaemonSet 'spec["hostNetwork"], spec["dnsPolicy"]' "$@")" = "(True, 'ClusterFirstWithHostNet')" ] || fail
  [ "$(q DaemonSet 'env["DATASTORE_ETCD_ENDPOINT"]' "$@")" = "https://127.0.0.1:2379" ] || fail
}

@test "an explicit etcd endpoint and data directories reach the pod" {
  set -- "${on[@]}" --set node.datastoreSnapshot.etcdEndpoint=https://10.1.1.1:2379 \
         --set node.datastoreSnapshot.k3sDataDir=/data/k3s --set node.datastoreSnapshot.kubeadmDir=/etc/k8s
  [ "$(q DaemonSet 'env["DATASTORE_ETCD_ENDPOINT"], env["K3S_DATA_DIR"], env["KUBEADM_DIR"]' "$@")" \
    = "('https://10.1.1.1:2379', '/data/k3s', '/etc/k8s')" ] || fail
}

@test "the snapshot directory is archived with the node" {
  [[ "$(node_cm "${on[@]}")" == *"R /var/lib/k8s-borg/datastore"* ]] || fail "$(node_cm "${on[@]}")"
  [[ "$(node_cm "${on[@]}" --set 'node.include={R /node/etc}')" == *"R /node/etc"*"R /var/lib/k8s-borg/datastore"* ]] \
    || fail "$(node_cm "${on[@]}" --set 'node.include={R /node/etc}')"
}

@test "agent mode: snapshot and removal are published and attached to the node plan" {
  [ "$(agent_scripts "${agent[@]}" "${on[@]}")" = "datastore-snapshot datastore-snapshot-clean" ] \
    || fail "$(agent_scripts "${agent[@]}" "${on[@]}")"
  [ "$(q DaemonSet 'env["BORG_PLAN_PRE_AGENT_SCRIPTS"], env["BORG_PLAN_PRE_AGENT_SCRIPTS_CONTINUE"], env["BORG_PLAN_POST_AGENT_SCRIPTS"]' "${agent[@]}" "${on[@]}")" \
    = "('datastore-snapshot', 'datastore-snapshot', 'datastore-snapshot-clean')" ] || fail
  [ "$(q DaemonSet 'env["BORG_UI_AGENT_SCRIPTS_DIR"]' "${agent[@]}" "${on[@]}")" = /etc/borg-ui-agent-scripts ] || fail
}

@test "agent mode: the user's node scripts stay, and win on a name collision" {
  set -- "${agent[@]}" "${on[@]}" --set-string 'node.agentScripts.mine=#!/bin/sh' \
         --set-string 'node.agentScripts.datastore-snapshot=#!/bin/sh'
  [ "$(agent_scripts "$@")" = "datastore-snapshot datastore-snapshot-clean mine" ] || fail "$(agent_scripts "$@")"
  render ConfigMap "$@" | grep -- '-node-agent-scripts' | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
sys.exit(d["data"]["datastore-snapshot"].strip() != "#!/bin/sh")' || fail "the default won"
}

@test "agent mode, off: our hook names stay owned, so a plan sheds them" {
  [ "$(q DaemonSet 'env.get("BORG_PLAN_OWNED_AGENT_SCRIPTS"), "BORG_PLAN_PRE_AGENT_SCRIPTS" in env' "${agent[@]}")" \
    = "('datastore-snapshot datastore-snapshot-clean', False)" ] || fail
  [ -z "$(agent_scripts "${agent[@]}")" ] || fail "$(agent_scripts "${agent[@]}")"
}
