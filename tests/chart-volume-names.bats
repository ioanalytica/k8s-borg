#!/usr/bin/env bats
#
# Volume names are unique within a pod. The backup workloads (the node
# DaemonSet, the cluster CronJob, the console StatefulSet) add the release's
# extraVolumes to the chart's own volumes, and an entry that takes one of
# their names, or the name of another entry, makes a workload Kubernetes
# refuses. The render fails on it instead, and says which list holds the
# entry, which name it is and in which workload it is taken. Nothing else
# happens to the entry: no other name is made up for it. Where the chart adds
# no volume of that name (a workload or a feature that is off), the name is
# free.

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
  # Every volume the chart can add to the three workloads.
  FULL="$BATS_TEST_TMPDIR/full.yaml"
  cat >"$FULL" <<'YAML'
node:
  backupMode: agent
  agentScripts:
    pre.sh: "#!/bin/sh\n# borg-ui: test\n"
  datastoreSnapshot:
    enabled: true
  sqlite:
    enabled: true
    databases:
      - {namespace: app, pvc: data, path: db.sqlite3}
cluster:
  mode: agent
databases:
  postgres:
    enabled: true
    existingSecret: pg
YAML
}

teardown() { common_teardown; }

# names KIND [HELM ARGS…] — the volume names of KIND's pod, one per line.
names() {
  local kind=$1; shift
  helm template rel "$CHART" -n backup -f "$VALUES" "$@" | python3 -c '
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get("kind") == sys.argv[1]:
        spec = d["spec"].get("jobTemplate", d)["spec"]["template"]["spec"]
        print("\n".join(v["name"] for v in spec["volumes"]))' "$kind"
}

# refused LIST NAME WORKLOAD [HELM ARGS…] — the render fails, and says that
# NAME, an entry of LIST, is taken in WORKLOAD.
refused() {
  local list=$1 name=$2 workload=$3; shift 3
  run helm template rel "$CHART" -n backup -f "$VALUES" "$@"
  [ "$status" -ne 0 ] || fail "rendered a second volume $name in $workload"
  [[ $output == *"$list: the volume name \"$name\" is used more than once in $workload "* ]] || fail "$output"
  [[ $output == *"give the entry another name"* ]] || fail "$output"
}

volume() { printf '[{"name":"%s","emptyDir":{}}]' "$1"; }

@test "the fixture reaches every workload, and the chart's own volumes do not collide" {
  local kind
  for kind in DaemonSet CronJob StatefulSet; do
    run names "$kind" -f "$FULL"
    [ "$status" -eq 0 ] && [ "$(wc -l <<<"$output")" -ge 9 ] || fail "$kind: $output"
    [ -z "$(sort <<<"$output" | uniq -d)" ] || fail "$kind: twice: $(sort <<<"$output" | uniq -d)"
  done
  [[ "$(names DaemonSet -f "$FULL" | tr '\n' ' ')" == *"rootfs "*"agent-scripts "*"datastore-snapshot "*"sqlite-copies "*"k8s-borg-agent-tmp "* ]] \
    || fail "$(names DaemonSet -f "$FULL")"
}

# candidates KIND MIN [HELM ARGS…] — the volume names of KIND's pod in $list,
# at least MIN of them: a loop over none would check nothing.
candidates() {
  local kind=$1 min=$2; shift 2
  list="$(names "$kind" "$@")" || fail "$kind: $list"
  [ "$(grep -c . <<<"$list")" -ge "$min" ] || fail "$kind: only these volumes: $list"
}

@test "an extraVolumes entry with the name of any volume of the node pods is refused" {
  local list name
  candidates DaemonSet 9 -f "$FULL"
  while read -r name; do
    refused extraVolumes "$name" "DaemonSet rel-k8s-borg-node" -f "$FULL" --set cluster.enabled=false \
      --set-json "extraVolumes=$(volume "$name")"
  done <<<"$list"
}

@test "a cluster.extraVolumes entry with the name of any volume of the CronJob or the console pod is refused" {
  local list name cron
  candidates CronJob 9 -f "$FULL"
  cron=$list
  while read -r name; do
    refused cluster.extraVolumes "$name" "CronJob rel-k8s-borg-cluster" -f "$FULL" \
      --set-json "cluster.extraVolumes=$(volume "$name")"
  done <<<"$list"
  # The console pod has volumes the CronJob has not.
  candidates StatefulSet 9 -f "$FULL"
  list="$(comm -23 <(sort <<<"$list") <(sort <<<"$cron"))"
  [ -n "$list" ] || fail "the console pod has no volume of its own"
  while read -r name; do
    refused cluster.extraVolumes "$name" "StatefulSet rel-k8s-borg-app" -f "$FULL" \
      --set-json "cluster.extraVolumes=$(volume "$name")"
  done <<<"$list"
}

@test "so is an extraVolumes entry there, and one given as text" {
  refused extraVolumes cache "CronJob rel-k8s-borg-cluster" --set node.enabled=false \
    --set-json "extraVolumes=$(volume cache)"
  refused extraVolumes k8s-borg-agent-tmp "StatefulSet rel-k8s-borg-app" --set node.enabled=false \
    --set cluster.mode=agent --set-json "extraVolumes=$(volume k8s-borg-agent-tmp)"
  refused extraVolumes mounts "DaemonSet rel-k8s-borg-node" \
    --set-string 'extraVolumes=- name: {{ printf "%s" "mounts" }}
  emptyDir: {}'
}

@test "one name in two entries is refused as well, with every list that holds it" {
  refused extraVolumes scratch "DaemonSet rel-k8s-borg-node" \
    --set-json 'extraVolumes=[{"name":"scratch","emptyDir":{}},{"name":"scratch","emptyDir":{}}]'
  refused "cluster.extraVolumes, extraVolumes" scratch "CronJob rel-k8s-borg-cluster" --set node.enabled=false \
    --set-json "extraVolumes=$(volume scratch)" --set-json "cluster.extraVolumes=$(volume scratch)"
}

# renders [HELM ARGS…] — the chart renders with them.
renders() {
  run helm template rel "$CHART" -n backup -f "$VALUES" "$@"
  [ "$status" -eq 0 ] || fail "$*: $output"
}

@test "a name is free where the chart adds no volume of it" {
  # A feature that is off, a workload that is off, the other workloads' lists.
  renders --set-json "extraVolumes=$(volume sqlite-copies)"
  renders --set-json "extraVolumes=$(volume k8s-borg-agent-tmp)"
  renders --set-json "extraVolumes=$(volume rootfs)" --set node.enabled=false
  renders --set-json "cluster.extraVolumes=$(volume rootfs)"
  renders --set-json "extraVolumes=$(volume agent-tmp)" -f "$FULL"
  renders --set-json "cluster.extraVolumes=$(volume cache)" --set cluster.enabled=false
}

@test "the entry is rendered as it is given: no name is changed" {
  [[ "$(names DaemonSet --set-json "extraVolumes=$(volume my-scratch)" | tr '\n' ' ')" == *" my-scratch "* ]] || fail
  [[ "$(names CronJob --set-json "cluster.extraVolumes=$(volume my-scratch)" | tr '\n' ' ')" == *" my-scratch "* ]] || fail
}
