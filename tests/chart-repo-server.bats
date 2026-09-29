#!/usr/bin/env bats
#
# The repository server is optional and off by default. These tests pin three
# things: a release that does not enable it renders exactly what it rendered
# before, enabling it adds objects without touching any other, and values that
# could not work — or would grant more than intended — fail the install.

setup() {
  load helpers/common
  command -v helm >/dev/null || fail "helm is required for the chart tests"
  CHART="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/chart"
  VALUES="$BATS_TEST_TMPDIR/values.yaml"
  cat >"$VALUES" <<'YAML'
borg:
  repoBase:
    value: "ssh://user@backup.example.com:22/./cluster"
  passphrase:
    value: "test"
ssh:
  privateKey: "test"
  publicKey: "test"
  knownHosts: "test"
YAML
  KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPSu1DAFv3rL+0eX65tyDpi0hwnDcsWJqgSLMp0O49HD"
  # The least that enables the server.
  ON=(--set repoServer.enabled=true
      --set ssh.hostKey=PRIVATE
      --set "ssh.authorizedKeys=$KEY cluster-a")
  # One configured client, for the tests about the client list.
  CLIENT=("${ON[@]}" --set repoServer.clients[0].name=cluster-a)
}

render() { helm template rel "$CHART" -n backup -f "$VALUES" "$@"; }

# object KIND NAME — one rendered object, from its "# Source" line to the next.
object() {
  awk -v kind="$1" -v name="$2" '
    /^---$/ { if (hit) print doc; doc = ""; hit = 0; is_kind = 0; next }
    { doc = doc $0 "\n" }
    $0 == "kind: " kind { is_kind = 1 }
    is_kind && $0 == "  name: " name { hit = 1 }
    END { if (hit) print doc }
  ' <<<"$RENDERED"
}

# refused MESSAGE ARGS… — the render fails and says why.
refused() {
  local message="$1"
  shift
  run render "$@"
  [ "$status" -ne 0 ] || fail "rendered although it should not"
  [[ "$output" == *"$message"* ]] || fail "expected \"$message\" in: $output"
}

# --- off by default -----------------------------------------------------------

@test "nothing of the repository server is rendered by default" {
  run render
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" != *repo-server* ]] || fail "found repo-server in the default render"
}

@test "enabling the server leaves every other object untouched" {
  # With the chart's own ssh Secret the host key is one more entry in it. That
  # Secret is the one object the server shares, so it is compared separately.
  render --set ssh.existingSecret=shared-ssh > "$BATS_TEST_TMPDIR/off.yaml"
  render --set ssh.existingSecret=shared-ssh --set repoServer.enabled=true > "$BATS_TEST_TMPDIR/on.yaml"
  # Drop the documents that come from the server's templates; the rest has to
  # be what a release without the server renders.
  awk '
    /^---$/ { if (!skip) printf "%s", doc; doc = $0 "\n"; skip = 0; next }
    /^# Source: k8s-borg\/templates\/repo-server-/ { skip = 1 }
    { doc = doc $0 "\n" }
    END { if (!skip) printf "%s", doc }
  ' "$BATS_TEST_TMPDIR/on.yaml" > "$BATS_TEST_TMPDIR/on-without-server.yaml"
  diff "$BATS_TEST_TMPDIR/off.yaml" "$BATS_TEST_TMPDIR/on-without-server.yaml"
}

# --- enabled ------------------------------------------------------------------

@test "the server is one unprivileged pod running the server entrypoint" {
  RENDERED="$(render "${ON[@]}")"
  sts="$(object StatefulSet rel-k8s-borg-repo-server)"
  [ -n "$sts" ] || fail "no StatefulSet rendered"
  grep -q 'replicas: 1$' <<<"$sts"
  grep -q 'command: \["/run-repo-server.sh"\]' <<<"$sts"
  grep -q 'runAsNonRoot: true' <<<"$sts"
  grep -q 'runAsUser: 20222$' <<<"$sts"
  grep -q 'runAsGroup: 20222$' <<<"$sts"
  grep -q 'allowPrivilegeEscalation: false' <<<"$sts"
  grep -q 'readOnlyRootFilesystem: true' <<<"$sts"
  grep -q 'automountServiceAccountToken: false' <<<"$sts"
  ! grep -q 'hostPath' <<<"$sts" || fail "the pod must not mount a hostPath"
  ! grep -q 'privileged' <<<"$sts" || fail "the pod must not be privileged"
  ! grep -q 'fsGroup' <<<"$sts" || fail "an fsGroup would let the kubelet change the data directory"
}

# mounts CONTAINER — the names of the volumes a container of the server's pod
# mounts, one per line. Only the volumeMounts: a port is called "ssh" as well.
mounts() {
  object StatefulSet rel-k8s-borg-repo-server | awk -v container="$1" '
    /^        - name: / { current = $3; in_mounts = 0 }
    current == container && /^          volumeMounts:$/ { in_mounts = 1; next }
    in_mounts && /^          [a-z]/ { in_mounts = 0 }
    in_mounts && /^            - name: / { print $3 }
  ' | sort -u
}

@test "only the init container sees the Secret, the server reads what was staged" {
  RENDERED="$(render "${ON[@]}")"
  sts="$(object StatefulSet rel-k8s-borg-repo-server)"
  grep -A3 '^        - name: prepare$' <<<"$sts" | grep -q 'command: \["/prepare-repo-server.sh"\]'
  # Spelled out, so that one more mount in either container fails here.
  [ "$(mounts prepare | tr '\n' ' ')" = "accounts config data run ssh tmp " ] || fail "init container mounts: $(mounts prepare | tr '\n' ' ')"
  [ "$(mounts repo-server | tr '\n' ' ')" = "accounts data run tmp " ] || fail "server container mounts: $(mounts repo-server | tr '\n' ' ')"
  main="$(awk '/^      containers:$/ { on = 1 } /^      volumes:$/ { on = 0 } on' <<<"$sts")"
  grep -A2 'name: run$' <<<"$main" | grep -q 'readOnly: true' || fail "the staged directory must be read-only for the server"
}

@test "of the shared Secret only the host key and authorized_keys are mounted" {
  RENDERED="$(render "${ON[@]}")"
  volume="$(object StatefulSet rel-k8s-borg-repo-server | awk '/^        - name: ssh$/ { on = 1 } on')"
  [ "$(grep -c 'key: ' <<<"$volume")" = "2" ] || fail "$volume"
  grep -q 'key: ssh_host_ed25519_key$' <<<"$volume"
  grep -q 'key: authorized_keys$' <<<"$volume"
  # A missing entry has to reach the init container, which names it.
  grep -q 'optional: true$' <<<"$volume"
}

@test "server and clients run the same image" {
  RENDERED="$(render "${ON[@]}")"
  # Init container and server: both from the image the clients run.
  server="$(object StatefulSet rel-k8s-borg-repo-server | grep ' image: ' | tr -d ' ' | sort -u)"
  client="$(object DaemonSet rel-k8s-borg-node | grep ' image: ' | grep -v busybox | tr -d ' ' | sort -u)"
  [ -n "$server" ] && [ "$server" = "$client" ] || fail "server: $server / client: $client"
}

@test "the account matches the uid the pod runs as" {
  RENDERED="$(render "${ON[@]}" --set repoServer.runAsUser=1500 --set repoServer.runAsGroup=1600)"
  object ConfigMap rel-k8s-borg-repo-server \
    | grep -q 'borg:x:1500:1600:Borg repository server:/run/borg-repo-server/home:/bin/sh'
  object ConfigMap rel-k8s-borg-repo-server | grep -q '^    borg:x:1600:$'
  object StatefulSet rel-k8s-borg-repo-server | grep -q 'runAsUser: 1500$'
  object StatefulSet rel-k8s-borg-repo-server | grep -q 'runAsGroup: 1600$'
}

@test "a configured client defaults to its own directory and the default permissions" {
  RENDERED="$(render "${CLIENT[@]}" --set repoServer.defaultPermissions=no-delete)"
  object ConfigMap rel-k8s-borg-repo-server | grep -q '^    cluster-a cluster-a no-delete$'
  object StatefulSet rel-k8s-borg-repo-server \
    | grep -A1 'name: BORG_REPO_SERVER_DEFAULT_PERMISSIONS' | grep -q 'value: "no-delete"'
}

@test "a configured client can share a directory with other permissions" {
  RENDERED="$(render "${ON[@]}" \
    --set repoServer.clients[0].name=restore-test \
    --set repoServer.clients[0].path=site/cluster-a \
    --set repoServer.clients[0].permissions=read-only)"
  object ConfigMap rel-k8s-borg-repo-server | grep -q '^    restore-test site/cluster-a read-only$'
}

@test "the server needs no client list" {
  RENDERED="$(render "${ON[@]}")"
  cm="$(object ConfigMap rel-k8s-borg-repo-server)"
  [ "$(awk '/^  clients: /{ on = 1; next } /^  [a-z]/{ on = 0 } on' <<<"$cm" | grep -vc '^    #')" = "0" ] || fail "$cm"
}

@test "Borg 1 is served unless switched off" {
  RENDERED="$(render "${ON[@]}")"
  object StatefulSet rel-k8s-borg-repo-server | grep -A1 'name: BORG_REPO_SERVER_BORG1' | grep -q 'value: "true"'
  RENDERED="$(render "${ON[@]}" --set repoServer.borg1=false)"
  object StatefulSet rel-k8s-borg-repo-server | grep -A1 'name: BORG_REPO_SERVER_BORG1' | grep -q 'value: "false"'
}

@test "host key and authorized_keys live in the ssh Secret of the release" {
  RENDERED="$(render "${ON[@]}")"
  secret="$(object Secret rel-k8s-borg-ssh)"
  grep -q 'ssh_host_ed25519_key: "PRIVATE"' <<<"$secret"
  grep -q "authorized_keys: \"$KEY cluster-a\"" <<<"$secret"
  object StatefulSet rel-k8s-borg-repo-server | grep -q 'secretName: rel-k8s-borg-ssh$'
  object StatefulSet rel-k8s-borg-repo-server | grep -q 'checksum/ssh: '
  [ "$(grep -c '^kind: Secret$' <<<"$RENDERED")" = "$(render | grep -c '^kind: Secret$')" ] \
    || fail "the server must not bring a Secret of its own"
}

@test "an existing ssh Secret serves clients and server alike" {
  RENDERED="$(render --set repoServer.enabled=true --set ssh.existingSecret=shared-ssh)"
  object StatefulSet rel-k8s-borg-repo-server | grep -q 'secretName: shared-ssh$'
  object DaemonSet rel-k8s-borg-node | grep -q 'secretName: shared-ssh$'
  [ -z "$(object Secret rel-k8s-borg-ssh)" ]
}

@test "without the server the ssh Secret carries nothing of it" {
  RENDERED="$(render)"
  ! object Secret rel-k8s-borg-ssh | grep -qE 'ssh_host_ed25519_key|authorized_keys' \
    || fail "server entries rendered without values"
}

@test "a changed client list restarts the pod" {
  before="$(render "${CLIENT[@]}" | grep 'checksum/config')"
  after="$(render "${CLIENT[@]}" --set repoServer.clients[0].permissions=no-delete | grep 'checksum/config')"
  [ -n "$before" ] && [ "$before" != "$after" ]
}

@test "a changed authorized_keys restarts the pod" {
  before="$(render "${ON[@]}" | grep 'checksum/ssh')"
  after="$(render "${ON[@]}" --set "ssh.authorizedKeys=$KEY cluster-b" | grep 'checksum/ssh')"
  [ -n "$before" ] && [ "$before" != "$after" ]
}

# --- reaching the server ------------------------------------------------------

@test "the Service is cluster-internal by default" {
  RENDERED="$(render "${ON[@]}")"
  svc="$(object Service rel-k8s-borg-repo-server)"
  grep -q 'type: ClusterIP$' <<<"$svc"
  grep -q 'port: 2222$' <<<"$svc"
  grep -q 'targetPort: ssh$' <<<"$svc"
  ! grep -qE 'externalTrafficPolicy|nodePort|loadBalancer' <<<"$svc" || fail "external settings on a ClusterIP Service: $svc"
}

@test "a NodePort Service takes a fixed node port" {
  RENDERED="$(render "${ON[@]}" --set repoServer.service.type=NodePort --set repoServer.service.nodePort=32222)"
  svc="$(object Service rel-k8s-borg-repo-server)"
  grep -q 'type: NodePort$' <<<"$svc"
  grep -q 'nodePort: 32222$' <<<"$svc"
  grep -q 'externalTrafficPolicy: Cluster$' <<<"$svc"
}

@test "a LoadBalancer Service takes address, source ranges and annotations" {
  RENDERED="$(render "${ON[@]}" --set repoServer.service.type=LoadBalancer \
    --set repoServer.service.loadBalancerIP=192.0.2.10 \
    --set repoServer.service.loadBalancerSourceRanges[0]=192.0.2.0/24 \
    --set repoServer.service.externalTrafficPolicy=Local \
    --set 'repoServer.service.annotations.metallb\.io/loadBalancerIPs=192.0.2.10')"
  svc="$(object Service rel-k8s-borg-repo-server)"
  grep -q 'type: LoadBalancer$' <<<"$svc"
  grep -q 'loadBalancerIP: "192.0.2.10"' <<<"$svc"
  grep -q -- '- 192.0.2.0/24$' <<<"$svc"
  grep -q 'externalTrafficPolicy: Local$' <<<"$svc"
  grep -q 'metallb.io/loadBalancerIPs: 192.0.2.10$' <<<"$svc"
}

# --- storage ------------------------------------------------------------------

@test "a local volume pins the data to one node and is kept on uninstall" {
  RENDERED="$(render "${ON[@]}" --set repoServer.persistence.local.createPV=true \
    --set repoServer.persistence.local.nodeName=storage-node \
    --set repoServer.persistence.local.path=/srv/borg)"
  pv="$(object PersistentVolume rel-k8s-borg-repo-server-pv)"
  grep -A1 '^  local:$' <<<"$pv" | grep -q 'path: "/srv/borg"'
  grep -A3 'key: kubernetes.io/hostname' <<<"$pv" | grep -q -- '- "storage-node"'
  grep -q 'persistentVolumeReclaimPolicy: Retain$' <<<"$pv"
  grep -A2 '^  claimRef:$' <<<"$pv" | grep -q 'name: rel-k8s-borg-repo-server-data$'
  grep -A2 '^  claimRef:$' <<<"$pv" | grep -q 'namespace: "backup"$'
  grep -q 'helm.sh/resource-policy: keep$' <<<"$pv"
  pvc="$(object PersistentVolumeClaim rel-k8s-borg-repo-server-data)"
  grep -q 'volumeName: rel-k8s-borg-repo-server-pv$' <<<"$pvc"
  grep -q 'helm.sh/resource-policy: keep$' <<<"$pvc"
}

@test "without a local volume the claim asks the storage class" {
  RENDERED="$(render "${ON[@]}" --set repoServer.persistence.storageClassName=fast --set repoServer.persistence.size=10Gi)"
  [ -z "$(object PersistentVolume rel-k8s-borg-repo-server-pv)" ]
  pvc="$(object PersistentVolumeClaim rel-k8s-borg-repo-server-data)"
  grep -q 'storageClassName: "fast"' <<<"$pvc"
  grep -q 'storage: "10Gi"' <<<"$pvc"
}

@test "an existing claim is used as it is" {
  RENDERED="$(render "${ON[@]}" --set repoServer.persistence.existingClaim=my-repos \
    --set repoServer.persistence.local.createPV=true)"
  [ -z "$(object PersistentVolume rel-k8s-borg-repo-server-pv)" ]
  [ -z "$(object PersistentVolumeClaim rel-k8s-borg-repo-server-data)" ]
  object StatefulSet rel-k8s-borg-repo-server | grep -q 'claimName: my-repos$'
}

# --- refused values -----------------------------------------------------------

@test "a server without a host key is refused" {
  refused "requires a host key" "${ON[@]}" --set ssh.hostKey=
}

@test "a server without client keys is refused" {
  refused "requires the clients' public keys" "${ON[@]}" --set ssh.authorizedKeys=
}

@test "an authorized_keys line carrying options is refused" {
  refused "ssh.authorizedKeys line 1" "${ON[@]}" --set "ssh.authorizedKeys=no-pty $KEY cluster-a"
  refused "ssh.authorizedKeys line 1" "${ON[@]}" --set-string "ssh.authorizedKeys=command=\"/bin/sh\" $KEY cluster-a"
}

@test "the bad line of several is named" {
  printf 'ssh:\n  authorizedKeys: |\n    # clients\n    %s cluster-a\n    %s\n' "$KEY" "$KEY" > "$BATS_TEST_TMPDIR/keys.yaml"
  refused "ssh.authorizedKeys line 3" --set repoServer.enabled=true --set ssh.hostKey=PRIVATE \
    -f "$BATS_TEST_TMPDIR/keys.yaml"
}

@test "a key whose comment cannot be a directory name is refused" {
  refused "names the client" "${ON[@]}" --set "ssh.authorizedKeys=$KEY someone@somewhere"
  refused "names the client" "${ON[@]}" --set "ssh.authorizedKeys=$KEY ../outside"
}

@test "a client path with a leading slash is refused" {
  refused "without a leading" "${CLIENT[@]}" --set repoServer.clients[0].path=/etc
}

@test "a client path with .. is refused" {
  refused 'must not contain ".."' "${CLIENT[@]}" --set repoServer.clients[0].path=cluster-a/../other
  refused 'must not contain ".."' "${CLIENT[@]}" --set repoServer.clients[0].path=..
}

@test "a client path with characters a shell would read is refused" {
  refused "must be made of" "${CLIENT[@]}" --set 'repoServer.clients[0].path=a b'
  refused "must be made of" "${CLIENT[@]}" --set 'repoServer.clients[0].path=a;b'
  refused "must be made of" "${CLIENT[@]}" --set 'repoServer.clients[0].path=./a'
  refused "must be made of" "${CLIENT[@]}" --set 'repoServer.clients[0].path=a/'
}

@test "a client without a name, or with one that is no plain name, is refused" {
  refused "clients[0].name is required" "${ON[@]}" --set repoServer.clients[0].path=somewhere
  refused "must start with a letter or digit" "${ON[@]}" --set 'repoServer.clients[0].name=a b'
}

@test "a client configured twice is refused" {
  refused "is used twice" "${CLIENT[@]}" --set repoServer.clients[1].name=cluster-a
}

@test "unknown permissions are refused" {
  refused "clients[0].permissions must be" "${CLIENT[@]}" --set repoServer.clients[0].permissions=append-only
  refused "repoServer.defaultPermissions must be" "${ON[@]}" --set repoServer.defaultPermissions=append-only
}

@test "a privileged port is refused" {
  refused "1024 or higher" "${ON[@]}" --set repoServer.port=22
}

@test "running as root is refused" {
  refused "does not run as root" "${ON[@]}" --set repoServer.runAsUser=0
}

@test "an unknown Service type is refused" {
  refused "repoServer.service.type must be" "${ON[@]}" --set repoServer.service.type=ExternalName
}

@test "a local volume without node or with a relative path is refused" {
  refused "requires repoServer.persistence.local.nodeName" "${ON[@]}" \
    --set repoServer.persistence.local.createPV=true --set repoServer.persistence.local.path=/srv/borg
  refused "must be an absolute path" "${ON[@]}" \
    --set repoServer.persistence.local.createPV=true --set repoServer.persistence.local.nodeName=n \
    --set repoServer.persistence.local.path=srv/borg
}

@test "a disabled server does not validate its values" {
  run render --set repoServer.port=22 --set 'repoServer.clients[0].name=a b'
  [ "$status" -eq 0 ] || fail "$output"
}
