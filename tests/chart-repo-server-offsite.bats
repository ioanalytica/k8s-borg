#!/usr/bin/env bats
#
# The repository server's external copy (repoServer.offsite) is off by default.
# Pinned here: enabling it adds a CronJob and at most one Secret and touches no
# other object; the job asks for nothing the server does not have, reads the
# data read-only on the server's node; every file comes from a value or an
# existing Secret; values that could not work fail the install.

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
  SERVER=(--set repoServer.enabled=true
          --set ssh.hostKey=PRIVATE
          --set "ssh.authorizedKeys=$KEY cluster-a")
  # The least that enables the copy.
  ON=("${SERVER[@]}"
      --set repoServer.offsite.enabled=true
      --set repoServer.offsite.target=offsite:k8s-borg
      --set "repoServer.offsite.rcloneConfig.value=[offsite]")
  JOB=rel-k8s-borg-repo-server-offsite
}

render() { helm template rel "$CHART" -n backup -f "$VALUES" "$@"; }

# object KIND NAME — one rendered object.
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

# --- off by default -------------------------------------------------------------

@test "nothing of the copy is rendered by default, not even with the server" {
  run render "${SERVER[@]}"
  [ "$status" -eq 0 ] || fail "$output"
  [[ "$output" != *offsite* ]] || fail "found offsite in the render"
}

@test "enabling the copy leaves every other object untouched" {
  render "${SERVER[@]}" > "$BATS_TEST_TMPDIR/off.yaml"
  render "${ON[@]}" > "$BATS_TEST_TMPDIR/on.yaml"
  awk '
    /^---$/ { if (!skip) printf "%s", doc; doc = $0 "\n"; skip = 0; next }
    /^# Source: k8s-borg\/templates\/repo-server-offsite-/ { skip = 1 }
    { doc = doc $0 "\n" }
    END { if (!skip) printf "%s", doc }
  ' "$BATS_TEST_TMPDIR/on.yaml" > "$BATS_TEST_TMPDIR/on-without-copy.yaml"
  # Blank lines aside: helm pads the last document of a kind once another
  # document follows it.
  diff <(grep -v '^[[:space:]]*$' "$BATS_TEST_TMPDIR/off.yaml") \
       <(grep -v '^[[:space:]]*$' "$BATS_TEST_TMPDIR/on-without-copy.yaml")
}

# --- the job ----------------------------------------------------------------------

@test "the job runs the copy script as the server's unprivileged user" {
  RENDERED="$(render "${ON[@]}" --set repoServer.runAsUser=1500 --set repoServer.runAsGroup=1600)"
  job="$(object CronJob "$JOB")"
  [ -n "$job" ] || fail "no CronJob rendered"
  grep -q 'command: \["/usr/local/bin/borg-offsite-copy"\]' <<<"$job"
  grep -q 'runAsNonRoot: true' <<<"$job"
  grep -q 'runAsUser: 1500$' <<<"$job"
  grep -q 'runAsGroup: 1600$' <<<"$job"
  grep -q 'allowPrivilegeEscalation: false' <<<"$job"
  grep -q 'readOnlyRootFilesystem: true' <<<"$job"
  grep -A1 'drop:' <<<"$job" | grep -q -- '- ALL'
  grep -q 'automountServiceAccountToken: false' <<<"$job"
  grep -q 'type: RuntimeDefault' <<<"$job"
  ! grep -qE 'privileged|hostPath|fsGroup|add:' <<<"$job" || fail "asks for more than the server"
  grep -q 'concurrencyPolicy: Forbid' <<<"$job"
  grep -q 'restartPolicy: Never' <<<"$job"
  grep -q 'backoffLimit: 0' <<<"$job"
}

@test "the job reads the server's volume read-only" {
  RENDERED="$(render "${ON[@]}")"
  job="$(object CronJob "$JOB")"
  grep -A2 '^                - name: data$' <<<"$job" | grep -q 'mountPath: /repos'
  grep -A2 '^                - name: data$' <<<"$job" | grep -q 'readOnly: true'
  grep -A3 '^            - name: data$' <<<"$job" | grep -q 'claimName: rel-k8s-borg-repo-server-data'
  grep -A3 '^            - name: data$' <<<"$job" | grep -q 'readOnly: true'
  RENDERED="$(render "${ON[@]}" --set repoServer.persistence.existingClaim=my-repos)"
  object CronJob "$JOB" | grep -q 'claimName: my-repos$'
}

@test "the job runs on the server's node and takes its node selector and tolerations" {
  RENDERED="$(render "${ON[@]}" \
    --set repoServer.nodeSelector.storage=ssd \
    --set repoServer.tolerations[0].key=storage \
    --set repoServer.tolerations[0].operator=Exists)"
  job="$(object CronJob "$JOB")"
  affinity="$(awk '/^          affinity:$/ { on = 1 } /^          containers:$/ { on = 0 } on' <<<"$job")"
  grep -q 'requiredDuringSchedulingIgnoredDuringExecution' <<<"$affinity"
  grep -q 'app.kubernetes.io/component: repo-server$' <<<"$affinity"
  grep -q 'topologyKey: kubernetes.io/hostname' <<<"$affinity"
  grep -A1 'nodeSelector:' <<<"$job" | grep -q 'storage: ssd'
  grep -A2 'tolerations:' <<<"$job" | grep -q 'key: storage'
}

@test "schedule, time zone and suspend reach the CronJob" {
  RENDERED="$(render "${ON[@]}")"
  job="$(object CronJob "$JOB")"
  grep -q 'schedule: "0 4 \* \* \*"' <<<"$job"
  grep -q 'timeZone: "UTC"' <<<"$job"
  grep -q 'suspend: false' <<<"$job"
  RENDERED="$(render "${ON[@]}" --set timezone=Europe/Berlin)"
  object CronJob "$JOB" | grep -q 'timeZone: "Europe/Berlin"'
  RENDERED="$(render "${ON[@]}" --set "repoServer.offsite.schedule=30 2 * * 0" \
    --set repoServer.offsite.timeZone=Europe/Vienna --set repoServer.offsite.suspend=true)"
  job="$(object CronJob "$JOB")"
  grep -q 'schedule: "30 2 \* \* 0"' <<<"$job"
  grep -q 'timeZone: "Europe/Vienna"' <<<"$job"
  grep -q 'suspend: true' <<<"$job"
}

@test "target, retries and the rclone options reach the script" {
  RENDERED="$(render "${ON[@]}")"
  job="$(object CronJob "$JOB")"
  grep -A1 'name: BORG_OFFSITE_TARGET' <<<"$job" | grep -q 'value: "offsite:k8s-borg"'
  grep -A1 'name: BORG_OFFSITE_SOURCE' <<<"$job" | grep -q 'value: "/repos"'
  grep -A1 'name: BORG_OFFSITE_RETRIES' <<<"$job" | grep -q 'value: "3"'
  grep -A1 'name: RCLONE_CONFIG' <<<"$job" | grep -q 'value: "/etc/borg-offsite/rclone.conf"'
  [ "$(awk '/^              args:$/ { on = 1; next } /^              [a-z]/ { on = 0 } on' <<<"$job")" \
    = "                - --transfers=4" ] || fail "$job"
  RENDERED="$(render "${ON[@]}" --set repoServer.offsite.transfers=8 --set repoServer.offsite.retries=5 \
    --set-string 'repoServer.offsite.bwlimit=08:00\,2M 20:00\,off' \
    --set 'repoServer.offsite.extraArgs[0]=--s3-no-check-bucket')"
  job="$(object CronJob "$JOB")"
  [ "$(awk '/^              args:$/ { on = 1; next } /^              [a-z]/ { on = 0 } on' <<<"$job")" \
    = '                - --transfers=8
                - "--bwlimit=08:00,2M 20:00,off"
                - "--s3-no-check-bucket"' ] || fail "$job"
  grep -A1 'name: BORG_OFFSITE_RETRIES' <<<"$job" | grep -q 'value: "5"'
}

# --- the files ----------------------------------------------------------------------

@test "values go into the copy's own Secret, mounted as files" {
  RENDERED="$(render "${ON[@]}" --set repoServer.offsite.sshKey.value=KEY --set repoServer.offsite.knownHosts.value=HOSTS)"
  secret="$(object Secret "$JOB")"
  grep -q 'rclone.conf: "\[offsite\]"' <<<"$secret"
  grep -q 'ssh_key: "KEY"' <<<"$secret"
  grep -q 'known_hosts: "HOSTS"' <<<"$secret"
  job="$(object CronJob "$JOB")"
  grep -A2 '^                - name: config$' <<<"$job" | grep -q 'mountPath: /etc/borg-offsite'
  for file in rclone.conf ssh_key known_hosts; do
    grep -A4 "name: $JOB$" <<<"$job" | grep -q "path: $file" || fail "$file not mounted: $job"
  done
  grep -q 'defaultMode: 292' <<<"$job"
}

@test "an existing Secret serves a file, with the default key or another one" {
  RENDERED="$(render "${SERVER[@]}" --set repoServer.offsite.enabled=true \
    --set repoServer.offsite.target=offsite:k8s-borg \
    --set repoServer.offsite.rcloneConfig.existingSecret=offsite-creds \
    --set repoServer.offsite.knownHosts.existingSecret=offsite-creds \
    --set repoServer.offsite.knownHosts.existingSecretKey=box-host-key)"
  # Nothing given as a value: no Secret of the chart's own.
  [ -z "$(object Secret "$JOB")" ] || fail "rendered a Secret without values"
  sources="$(object CronJob "$JOB" | awk '/^                sources:$/ { on = 1 } on')"
  grep -A4 'name: "offsite-creds"' <<<"$sources" | grep -q 'key: "rclone.conf"'
  grep -A4 'name: "offsite-creds"' <<<"$sources" | grep -A1 'key: "box-host-key"' | grep -q 'path: known_hosts'
  ! grep -q 'ssh_key' <<<"$sources" || fail "an SSH key that was not given is mounted"
}

@test "an existing Secret wins over a value for the same file" {
  RENDERED="$(render "${ON[@]}" --set repoServer.offsite.rcloneConfig.existingSecret=offsite-creds)"
  [ -z "$(object Secret "$JOB")" ] || fail "the value was rendered as well"
  object CronJob "$JOB" | grep -q 'name: "offsite-creds"'
}

# --- refused ----------------------------------------------------------------------

@test "the copy needs the server" {
  refused "repoServer.offsite.enabled requires repoServer.enabled" \
    --set repoServer.offsite.enabled=true --set repoServer.offsite.target=offsite:x \
    --set "repoServer.offsite.rcloneConfig.value=[offsite]"
}

@test "the target has to be an rclone remote" {
  refused "repoServer.offsite.target must be <remote>:<path>" "${ON[@]}" --set repoServer.offsite.target=
  refused "repoServer.offsite.target must be <remote>:<path>" "${ON[@]}" --set repoServer.offsite.target=/mnt/copy
  refused "repoServer.offsite.target must be <remote>:<path>" "${ON[@]}" --set "repoServer.offsite.target=:s3,provider=Other:bucket"
}

@test "the copy needs an rclone config" {
  refused "requires an rclone config" "${ON[@]}" --set repoServer.offsite.rcloneConfig.value=
}

@test "schedule, retries and transfers have to make sense" {
  refused "repoServer.offsite.schedule must be a cron schedule" "${ON[@]}" --set repoServer.offsite.schedule=
  refused "repoServer.offsite.retries must be 1 or more" "${ON[@]}" --set repoServer.offsite.retries=0
  refused "repoServer.offsite.transfers must be 1 or more" "${ON[@]}" --set repoServer.offsite.transfers=many
}
