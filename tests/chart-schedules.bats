#!/usr/bin/env bats
#
# Check and backup schedules of the managed agents. Each agent pod applies the
# perHost entry for its own hostname once, at start: the console pod's hostname
# is cluster.nodeName, a node pod's "k8s-borg-<node name>". So a schedule change
# has to roll the pods that apply it, and only those, and the install notes
# name the keys that no agent pod applies.

setup() {
  load helpers/common
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
    server: "http://borg-ui.example.com"
YAML
  # The console pod and the node pods as agents, the cluster backup as a plan.
  AGENTS=(--set cluster.mode=agent --set cluster.backupMode=plan --set node.backupMode=agent)
}

render() { helm template rel "$CHART" -n backup -f "$VALUES" "$@"; }

# notes ARGS… — the install notes, rendered without a cluster.
notes() {
  KUBECONFIG="$BATS_TEST_TMPDIR/no-cluster" \
    helm install rel "$CHART" -n backup -f "$VALUES" --dry-run=client "$@" \
    | sed -n '/^NOTES:/,$p'
}

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

# checksums ARGS… — the schedule checksums of the console and the node pods,
# one "<pod> checksum/<schedules>: <sum>" line each.
checksums() {
  RENDERED="$(render "$@")" || return 1
  object StatefulSet rel-k8s-borg-app | awk '$1 ~ /^checksum\/.*-schedules:$/ { print "console", $1, $2 }'
  object DaemonSet rel-k8s-borg-node | awk '$1 ~ /^checksum\/.*-schedules:$/ { print "node", $1, $2 }'
}

# changed BEFORE AFTER — the "<pod> checksum/<schedules>" of the lines that differ.
changed() {
  diff <(printf '%s\n' "$1") <(printf '%s\n' "$2") | awk '$1 == ">" { print $2, $3 }' | tr -d ':' | sort | xargs
}

# --- the keys ------------------------------------------------------------------

@test "the console pod's key is cluster.nodeName, a node pod's k8s-borg-<node name>" {
  RENDERED="$(render "${AGENTS[@]}" --set cluster.nodeName=k8s-borg)"
  # The hostnames the pods set for themselves, which the keys have to match.
  object StatefulSet rel-k8s-borg-app | grep -q 'hostname "${NODE_NAME}"'
  object StatefulSet rel-k8s-borg-app | grep -A1 -- '- name: NODE_NAME$' | grep -q 'value: "k8s-borg"$'
  object DaemonSet rel-k8s-borg-node | grep -q 'hostname "k8s-borg-${NODE_NAME}"'
  object DaemonSet rel-k8s-borg-node | grep -A3 -- '- name: NODE_NAME$' | grep -q 'fieldPath: spec.nodeName$'
}

@test "perHost entries become <key>_check_schedule and <key>_backup_schedule" {
  RENDERED="$(render "${AGENTS[@]}" \
    --set 'borg.checkSchedule.perHost.k8s-borg-mycluster=0 4 * * 0' \
    --set 'borg.backupSchedule.perHost.k8s-borg-node01=30 2 * * *')"
  object ConfigMap rel-k8s-borg-check-schedules | grep -q 'k8s-borg-mycluster_check_schedule: "0 4 \* \* 0"$'
  object ConfigMap rel-k8s-borg-backup-schedules | grep -q 'k8s-borg-node01_backup_schedule: "30 2 \* \* \*"$'
}

@test "off reaches the pods as off, also unquoted" {
  # YAML 1.1 reads an unquoted off as false.
  cat >"$BATS_TEST_TMPDIR/off.yaml" <<'YAML'
borg:
  checkSchedule:
    default: off
    perHost:
      k8s-borg-mycluster: off
      k8s-borg-node01: "off"
  backupSchedule:
    perHost:
      k8s-borg-node01: off
YAML
  RENDERED="$(render "${AGENTS[@]}" -f "$BATS_TEST_TMPDIR/off.yaml")"
  object ConfigMap rel-k8s-borg-check-schedules | grep -q '^  default_check_schedule: "off"$'
  object ConfigMap rel-k8s-borg-check-schedules | grep -q '^  k8s-borg-mycluster_check_schedule: "off"$'
  object ConfigMap rel-k8s-borg-check-schedules | grep -q '^  k8s-borg-node01_check_schedule: "off"$'
  object ConfigMap rel-k8s-borg-backup-schedules | grep -q '^  k8s-borg-node01_backup_schedule: "off"$'
}

# --- rolling the pods ----------------------------------------------------------

@test "a check-schedule change rolls the console pod and the node pods" {
  before="$(checksums "${AGENTS[@]}" --set 'borg.checkSchedule.perHost.k8s-borg-mycluster=0 4 * * 0')"
  after="$(checksums "${AGENTS[@]}" --set 'borg.checkSchedule.perHost.k8s-borg-mycluster=0 5 * * 0')"
  [ "$(changed "$before" "$after")" = "console checksum/check-schedules node checksum/check-schedules" ] \
    || fail "changed: $(changed "$before" "$after")"
}

@test "a backup-schedule change rolls the console pod and the node pods" {
  before="$(checksums "${AGENTS[@]}" --set 'borg.backupSchedule.default=0 2 * * *')"
  after="$(checksums "${AGENTS[@]}" --set 'borg.backupSchedule.default=0 3 * * *')"
  [ "$(changed "$before" "$after")" = "console checksum/backup-schedules node checksum/backup-schedules" ] \
    || fail "changed: $(changed "$before" "$after")"
}

@test "a first schedule rolls the pods too" {
  before="$(checksums "${AGENTS[@]}")"
  after="$(checksums "${AGENTS[@]}" --set 'borg.checkSchedule.default=0 3 * * *')"
  [ "$(changed "$before" "$after")" = "console checksum/check-schedules node checksum/check-schedules" ] \
    || fail "changed: $(changed "$before" "$after")"
}

@test "in cronjob mode the console pod does not roll for a backup schedule" {
  # It registers no plan; cluster.schedule runs the cluster backup.
  out="$(checksums --set cluster.mode=agent --set node.backupMode=agent)"
  grep -q '^console checksum/check-schedules: ' <<<"$out" || fail "$out"
  ! grep -q '^console checksum/backup-schedules' <<<"$out" || fail "$out"
  grep -q '^node checksum/backup-schedules: ' <<<"$out" || fail "$out"
}

@test "pods that do not run as agents carry no schedule checksum" {
  # The nodes as agents, the console pod for inspection only, and the reverse.
  out="$(checksums --set node.backupMode=agent)"
  ! grep -q '^console' <<<"$out" || fail "$out"
  grep -q '^node checksum/check-schedules: ' <<<"$out" || fail "$out"
  out="$(checksums --set cluster.mode=agent)"
  grep -q '^console checksum/check-schedules: ' <<<"$out" || fail "$out"
  ! grep -q '^node' <<<"$out" || fail "$out"
  # And the CronJob, whose pods start anew with every run, never.
  RENDERED="$(render "${AGENTS[@]}" --set cluster.backupMode=cronjob)"
  ! object CronJob rel-k8s-borg-cluster | grep -q 'checksum/' || fail "the CronJob carries a checksum"
}

@test "a schedule change touches nothing but the schedules and their checksums" {
  render "${AGENTS[@]}" --set 'borg.checkSchedule.perHost.k8s-borg-node01=0 3 * * *' \
    --set 'borg.backupSchedule.perHost.k8s-borg-node01=0 2 * * *' >"$BATS_TEST_TMPDIR/before.yaml"
  render "${AGENTS[@]}" --set 'borg.checkSchedule.perHost.k8s-borg-node01=0 4 * * *' \
    --set 'borg.backupSchedule.perHost.k8s-borg-node01=0 1 * * *' >"$BATS_TEST_TMPDIR/after.yaml"
  # Drop the schedule ConfigMaps and the checksum lines; the rest has to be equal.
  strip() {
    awk '
      /^---$/ { if (!skip) printf "%s", doc; doc = $0 "\n"; skip = 0; next }
      /^# Source: k8s-borg\/templates\/configmap-(check|backup)-schedules\.yaml$/ { skip = 1 }
      $1 ~ /^checksum\/(check|backup)-schedules:$/ { next }
      { doc = doc $0 "\n" }
      END { if (!skip) printf "%s", doc }
    ' "$1"
  }
  diff <(strip "$BATS_TEST_TMPDIR/before.yaml") <(strip "$BATS_TEST_TMPDIR/after.yaml")
  ! cmp -s "$BATS_TEST_TMPDIR/before.yaml" "$BATS_TEST_TMPDIR/after.yaml" || fail "the change did not render"
}

# --- keys no agent pod applies -------------------------------------------------

@test "the install notes name a key that is no pod's hostname" {
  # "console" was the example in values.yaml up to 1.2.3; no pod has that hostname.
  out="$(notes "${AGENTS[@]}" --set 'borg.checkSchedule.perHost.console=0 4 * * 0')"
  [[ "$out" == *"WARNING: no agent pod applies these schedules:"* ]] || fail "$out"
  [[ "$out" == *"• borg.checkSchedule.perHost.console"* ]] || fail "$out"
  [[ "$out" == *'The console pod is "k8s-borg-mycluster" (cluster.nodeName)'* ]] || fail "$out"
}

@test "the install notes take cluster.nodeName and k8s-borg-<node> keys as they are" {
  out="$(notes "${AGENTS[@]}" --set cluster.nodeName=k8s-borg \
    --set 'borg.checkSchedule.perHost.k8s-borg=15 2 * * 0' \
    --set 'borg.checkSchedule.perHost.k8s-borg-node01=0 3 * * *' \
    --set 'borg.backupSchedule.perHost.k8s-borg=0 */4 * * *' \
    --set 'borg.backupSchedule.perHost.k8s-borg-node01=0 2 * * *')"
  [[ "$out" == NOTES:* ]] || fail "no notes: $out"
  [[ "$out" != *WARNING* ]] || fail "$out"
}

@test "the install notes name the keys of pods that do not run as agents" {
  # Node pods in interval mode apply no schedule at all.
  out="$(notes --set cluster.mode=agent --set cluster.nodeName=k8s-borg \
    --set 'borg.checkSchedule.perHost.k8s-borg=15 2 * * 0' \
    --set 'borg.backupSchedule.perHost.k8s-borg=0 */4 * * *' \
    --set 'borg.backupSchedule.perHost.k8s-borg-node01=0 2 * * *')"
  [[ "$out" != *"borg.checkSchedule.perHost.k8s-borg"* ]] || fail "$out"
  [[ "$out" != *"• borg.backupSchedule.perHost.k8s-borg"$'\n'* ]] || fail "$out"
  [[ "$out" == *"• borg.backupSchedule.perHost.k8s-borg-node01"* ]] || fail "$out"
}

@test "the install notes name the console pod's backup key when cluster.schedule overrides it" {
  out="$(notes --set cluster.nodeName=k8s-borg --set 'cluster.schedule=0 3 * * *' \
    --set 'borg.backupSchedule.perHost.k8s-borg=0 */4 * * *')"
  [[ "$out" == *"• borg.backupSchedule.perHost.k8s-borg"$'\n'* ]] || fail "$out"
  [[ "$out" == *"cluster-data backups (0 3 * * *)"* ]] || fail "$out"
}

# --- the cluster CronJob -------------------------------------------------------

# cronjob_spec ARGS… — the schedule and suspend lines of the cluster CronJob.
cronjob_spec() {
  RENDERED="$(render "$@")" || return 1
  object CronJob rel-k8s-borg-cluster | awk '/^  (schedule|suspend):/ { print $1, $2, $3, $4, $5, $6 }' \
    | sed 's/ *$//'
}

@test "the cluster CronJob runs every six hours without a schedule of its own" {
  [ "$(cronjob_spec)" = 'schedule: "0 */6 * * *"' ] || fail "$(cronjob_spec)"
}

@test "the cluster CronJob takes the console pod's perHost backup schedule" {
  # In legacy and in agent mode: the key is cluster.nodeName either way.
  for mode in legacy agent; do
    out="$(cronjob_spec --set cluster.mode=$mode --set cluster.nodeName=k8s-borg \
      --set 'borg.backupSchedule.perHost.k8s-borg=0 */4 * * *')"
    [ "$out" = 'schedule: "0 */4 * * *"' ] || fail "$mode: $out"
  done
  out="$(notes --set cluster.nodeName=k8s-borg --set 'borg.backupSchedule.perHost.k8s-borg=0 */4 * * *')"
  [[ "$out" == *"Cluster backup: k8s CronJob (0 */4 * * * from borg.backupSchedule.perHost.k8s-borg)."* ]] \
    || fail "$out"
  [[ "$out" != *WARNING* ]] || fail "$out"
}

@test "cluster.schedule wins over the perHost backup schedule" {
  out="$(cronjob_spec --set 'cluster.schedule=0 3 * * *' \
    --set 'borg.backupSchedule.perHost.k8s-borg-mycluster=0 */4 * * *')"
  [ "$out" = 'schedule: "0 3 * * *"' ] || fail "$out"
}

@test "the default backup schedule leaves the cluster CronJob alone" {
  # borg.backupSchedule.default is meant for the agents; it would otherwise
  # move every cluster backup that runs on the six hours.
  out="$(cronjob_spec --set 'borg.backupSchedule.default=45 * * * *' \
    --set 'borg.backupSchedule.perHost.k8s-borg-node01=0 2 * * *')"
  [ "$out" = 'schedule: "0 */6 * * *"' ] || fail "$out"
}

@test "off as the console pod's backup schedule suspends the cluster CronJob, also unquoted" {
  for off in 'off' '"off"'; do
    printf 'borg:\n  backupSchedule:\n    perHost:\n      k8s-borg-mycluster: %s\n' "$off" >"$BATS_TEST_TMPDIR/off.yaml"
    out="$(cronjob_spec -f "$BATS_TEST_TMPDIR/off.yaml")"
    [ "$out" = "$(printf '%s\n' 'schedule: "0 */6 * * *"' 'suspend: true')" ] || fail "$off: $out"
  done
  out="$(notes -f "$BATS_TEST_TMPDIR/off.yaml")"
  [[ "$out" == *"Cluster backup: k8s CronJob (suspended: borg.backupSchedule.perHost.k8s-borg-mycluster is off)."* ]] \
    || fail "$out"
}

@test "in plan mode there is no CronJob, whatever the schedules" {
  RENDERED="$(render "${AGENTS[@]}" --set 'borg.backupSchedule.perHost.k8s-borg-mycluster=0 */4 * * *')"
  [ -z "$(object CronJob rel-k8s-borg-cluster)" ] || fail "a CronJob in plan mode"
}

@test "the install notes warn of nothing without perHost keys" {
  out="$(notes "${AGENTS[@]}" --set 'borg.checkSchedule.default=0 3 * * *')"
  [[ "$out" == NOTES:* ]] || fail "no notes: $out"
  [[ "$out" != *WARNING* ]] || fail "$out"
}
