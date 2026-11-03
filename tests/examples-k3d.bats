#!/usr/bin/env bats
#
# examples/k3d/ holds the files of the site's page "Try it locally"
# (site/guide/try-locally.md): the whole chart in a throwaway k3d cluster. The
# page and the files name the same things in several places: the node, the
# release and its namespace, the client of the repository server, the claims,
# the demo database. A name changed on one side only fails at install time, in
# a pod that waits for a claim, a host key or a Secret that is not there.
# These tests keep both sides together, and the values in the chart's keys.

setup() {
  load helpers/common
  load helpers/examples
  command -v helm >/dev/null || fail "helm is required for the chart tests"
  python3 -c 'import yaml' 2>/dev/null \
    || fail "python3 with PyYAML is required (apt-get install python3-yaml)"
  K3D="$REPO_ROOT/examples/k3d"
  PAGE="$REPO_ROOT/site/guide/try-locally.md"
  KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPSu1DAFv3rL+0eX65tyDpi0hwnDcsWJqgSLMp0O49HD"
  # What the page passes on the command line, with stand-ins: the admin
  # password from a file, with its final newline.
  printf 'test\n' >"$BATS_TEST_TMPDIR/admin-password"
  ARGS=(-f "$K3D/values.yaml"
        --set borg.passphrase.value=test
        --set-file borgUI.adminPassword.value="$BATS_TEST_TMPDIR/admin-password"
        --set ssh.privateKey=test --set ssh.publicKey=test --set ssh.knownHosts=test
        --set ssh.hostKey=test --set "ssh.authorizedKeys=$KEY quickstart")
}

# page_value REGEX — the first group of REGEX (Python syntax) in the page.
page_value() {
  python3 - "$PAGE" "$1" <<'PY'
import re, sys
m = re.search(sys.argv[2], open(sys.argv[1]).read())
print(m.group(1) if m else "")
PY
}

# release_and_namespace — "<release> <namespace>" of the page's helm install.
release_and_namespace() {
  page_value 'helm install (\S+ oci://\S+ -n \S+)' | awk '{ print $1, $4 }'
}

@test "every key the k3d values set is one the chart knows" {
  local file
  for file in values.yaml values-demo-db.yaml; do
    run unknown_keys "$K3D/$file"
    [ "$status" -eq 0 ] || fail "$output"
    [ -z "$output" ] || fail "$file: keys chart/values.yaml does not know: $output"
  done
}

@test "the k3d values render, alone and with the demo database" {
  read -r release ns < <(release_and_namespace)
  [ -n "$ns" ] || fail "no helm install in the page"
  run helm template "$release" "$REPO_ROOT/chart" -n "$ns" "${ARGS[@]}"
  [ "$status" -eq 0 ] || fail "$output"
  run helm template "$release" "$REPO_ROOT/chart" -n "$ns" "${ARGS[@]}" -f "$K3D/values-demo-db.yaml"
  [ "$status" -eq 0 ] || fail "$output"
}

@test "the page's cluster, release and client are the ones the values name" {
  local cluster node release ns
  cluster=$(page_value 'k3d cluster create (\S+)')
  [ -n "$cluster" ] || fail "no k3d cluster create in the page"
  node="k3d-$cluster-server-0"
  read -r release ns < <(release_and_namespace)
  run python3 - "$K3D/values.yaml" "$PAGE" "$node" "$release" "$ns" <<'PY'
import re, sys, yaml
values, page = yaml.safe_load(open(sys.argv[1])), open(sys.argv[2]).read()
node, release, ns = sys.argv[3:6]
local = values["repoServer"]["persistence"]["local"]
host = f"{release}-repo-server.{ns}.svc"
errors = []
if local["nodeName"] != node:
    errors.append(f"repoServer.persistence.local.nodeName {local['nodeName']}, the page's node is {node}")
want = f"docker exec {node} install -d -o 20222 -g 20222 -m 0700 {local['path']}"
if want not in page:
    errors.append(f"the page does not create the data directory: {want}")
m = re.fullmatch(r"ssh://borg@([^:/]+):(\d+)/\./([^/]+)", values["borg"]["repoBase"]["value"])
if not m:
    errors.append(f"borg.repoBase.value is no Borg 1 URL of the repository server: {values['borg']['repoBase']['value']}")
else:
    if m.group(1) != host:
        errors.append(f"borg.repoBase.value names {m.group(1)}, the release's repository server is {host}")
    if f'echo "[{host}]:{m.group(2)} ' not in page:
        errors.append(f"the page's known_hosts line is not for [{host}]:{m.group(2)}")
    if f"-C {m.group(3)} -f id_ed25519" not in page:
        errors.append(f"the page's client key is not named {m.group(3)}, the directory of borg.repoBase.value")
print("\n".join(errors))
PY
  [ "$status" -eq 0 ] || fail "$output"
  [ -z "$output" ] || fail "$output"
  # The repository server's Service is the host the values name.
  run helm template "$release" "$REPO_ROOT/chart" -n "$ns" "${ARGS[@]}" -s templates/repo-server-service.yaml
  [ "$status" -eq 0 ] || fail "$output"
  grep -qx "  name: $release-repo-server" <<<"$output" || fail "$output"
}

@test "the pods mount the release's own claims, which ask for ReadWriteOnce alone" {
  read -r release ns < <(release_and_namespace)
  helm template "$release" "$REPO_ROOT/chart" -n "$ns" "${ARGS[@]}" >"$BATS_TEST_TMPDIR/release.yaml"
  run python3 - "$PAGE" "$BATS_TEST_TMPDIR/release.yaml" <<'PY'
import re, sys, yaml
page = open(sys.argv[1]).read()
docs = [d for d in yaml.safe_load_all(open(sys.argv[2])) if d]
made = {d["metadata"]["name"]: d for d in docs if d["kind"] == "PersistentVolumeClaim"}
def mounted(node):
    if isinstance(node, dict):
        if "persistentVolumeClaim" in node:
            yield node["persistentVolumeClaim"]["claimName"]
        for v in node.values():
            yield from mounted(v)
    elif isinstance(node, list):
        for v in node:
            yield from mounted(v)
errors = []
for claim in sorted({c for d in docs for c in mounted(d)}):
    if claim not in made:
        errors.append(f"a pod mounts {claim}, a claim the release does not make")
    elif made[claim]["spec"]["accessModes"] != ["ReadWriteOnce"]:
        errors.append(f"{claim} asks for {made[claim]['spec']['accessModes']}, k3s's local-path offers ReadWriteOnce alone")
for claim in re.findall(r"on the claim `([^`]+)`", page):
    if claim not in made:
        errors.append(f"the page names the claim {claim}, which the release does not make")
print("\n".join(errors))
PY
  [ "$status" -eq 0 ] || fail "$output"
  [ -z "$output" ] || fail "$output"
}

@test "the demo database is the one values-demo-db.yaml dumps, into a source of the cluster backup" {
  run python3 - "$K3D/values-demo-db.yaml" "$K3D/demo-db.yaml" <<'PY'
import sys, yaml
values = yaml.safe_load(open(sys.argv[1]))
docs = {(d["kind"], d["metadata"]["name"]): d for d in yaml.safe_load_all(open(sys.argv[2])) if d}
(inst,) = values["databases"]["postgres"]["instances"]
ref = inst["secretRef"]
secret = docs.get(("Secret", ref["name"]))
errors = []
if not secret or secret["metadata"]["namespace"] != ref["namespace"]:
    errors.append(f"no Secret {ref['namespace']}/{ref['name']} in demo-db.yaml")
else:
    for k in ("usernameKey", "passwordKey"):
        if ref[k] not in secret["stringData"]:
            errors.append(f"the Secret has no key {ref[k]} ({k})")
svc = docs.get(("Service", inst["host"].split(".")[0]))
if not svc or inst["host"] != f"{svc['metadata']['name']}.{svc['metadata']['namespace']}.svc":
    errors.append(f"no Service for host {inst['host']} in demo-db.yaml")
loc = values["borg"]["dbBackupLocation"]
if f"R {loc}" not in values["cluster"]["include"]:
    errors.append(f"cluster.include has no root for borg.dbBackupLocation {loc}")
print("\n".join(errors))
PY
  [ "$status" -eq 0 ] || fail "$output"
  [ -z "$output" ] || fail "$output"
}
