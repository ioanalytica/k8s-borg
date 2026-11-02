#!/usr/bin/env bats
#
# examples/helm/k8s-borg.yaml is the example of a whole release, and it had
# drifted: the chart had moved config.*, app.* and borgUI.agent elsewhere, and
# the example, pinned to chart 1.0.4, still set them. The chart refuses the old
# app section, so the example did not render at all; config.* alone it would
# have ignored without a word — Helm drops a key the chart does not know — and
# backed up nothing the example's include patterns and S3 buckets listed.

setup() {
  load helpers/common
  load helpers/versions
  common_setup
  command -v helm >/dev/null || fail "helm is required for the chart tests"
  python3 -c 'import yaml' 2>/dev/null \
    || fail "python3 with PyYAML is required (apt-get install python3-yaml)"
  CHART_DIR="$REPO_ROOT/chart"
  EXAMPLE="$REPO_ROOT/examples/helm/k8s-borg.yaml"
  EX_VALUES="$BATS_TEST_TMPDIR/values.yaml"
  helmrelease_field values >"$EX_VALUES"
}

teardown() { common_teardown; }

# helmrelease_field values|version — the HelmRelease's spec.values as a values
# file, or the chart version it pins.
helmrelease_field() {
  python3 - "$EXAMPLE" "$1" <<'PY'
import sys, yaml
hr = next(d for d in yaml.safe_load_all(open(sys.argv[1]))
          if d and d.get("kind") == "HelmRelease")
if sys.argv[2] == "values":
    yaml.safe_dump(hr["spec"]["values"], sys.stdout, sort_keys=False)
else:
    print(hr["spec"]["chart"]["spec"]["version"])
PY
}

@test "every key the example sets is one the chart knows" {
  # A map the chart leaves empty ({}) takes any key; below it nothing is checked.
  run python3 - "$EX_VALUES" "$CHART_DIR/values.yaml" <<'PY'
import sys, yaml
ex, known = (yaml.safe_load(open(p)) for p in sys.argv[1:3])
def walk(e, k, path):
    for key, val in e.items():
        p = f"{path}.{key}" if path else key
        if not isinstance(k, dict) or key not in k:
            print(p)
        elif isinstance(val, dict) and isinstance(k[key], dict) and k[key]:
            walk(val, k[key], p)
walk(ex, known, "")
PY
  [ "$status" -eq 0 ] || fail "$output"
  [ -z "$output" ] || fail "keys chart/values.yaml does not know: $output"
}

@test "the example renders" {
  run helm template k8s-borg "$CHART_DIR" -n k8s-borg -f "$EX_VALUES"
  [ "$status" -eq 0 ] || fail "$output"
}

@test "the example renders with its commented Borg UI part switched on" {
  run helm template k8s-borg "$CHART_DIR" -n k8s-borg -f "$EX_VALUES" \
    --set borgUI.enabled=true --set borgUI.ingress.enabled=true \
    --set borgUI.ingress.host=borgui.example.com \
    --set borgUI.adminPassword.existingSecret=k8s-borg-secret \
    --set borgUI.adminPassword.existingSecretKey=BORG_UI_ADMIN_PASS \
    --set node.backupMode=agent --set cluster.mode=agent --set cluster.backupMode=plan \
    --set-string 'borg.backupSchedule.default=0 2 * * *'
  [ "$status" -eq 0 ] || fail "$output"
}

@test "the example pins the current chart version" {
  local v
  v="$(chart_version)"
  [ -n "$v" ] || fail "no version: in Chart.yaml"
  # Every version with a -suffix (a beta, an rc, a -N revision) is a
  # prerelease. One is built from a branch whose Chart.yaml carries its version
  # (check-release-tag.sh); the example stays on the last release meanwhile.
  if [[ "$v" == *-* ]]; then
    skip "chart $v is a prerelease; the example stays on the last release"
  fi
  [ "$(helmrelease_field version)" = "$v" ] \
    || fail "example pins $(helmrelease_field version), chart is $(chart_version)"
}
