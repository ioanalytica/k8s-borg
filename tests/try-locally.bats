#!/usr/bin/env bats
#
# tests/try-locally/run.sh runs the page "Try it locally"
# (site/guide/try-locally.md) by its own shell blocks, and
# .github/workflows/try-locally.yml runs it in a k3d cluster. A block the page
# loses, a URL or chart the run can no longer swap for the checkout's, a plan
# the page renames or a path the workflow does not watch fails here, in a
# second, rather than in the k3d run of the next pull request that touches
# the chart.

setup() {
  load helpers/common
  load helpers/versions
  load helpers/workflows
  load try-locally/lib
  common_setup
  WF="$REPO_ROOT/.github/workflows/try-locally.yml"
}

teardown() { common_teardown; }

# pr_paths — the paths filter of the pull_request trigger.
pr_paths() {
  awk '
    $0 == "  pull_request:" { ev = 1; next }
    ev && /^  [^ ]/ { exit }
    ev && $1 == "paths:" { on = 1; next }
    on && $1 == "-" { p = $2; gsub(/"/, "", p); print p; next }
    on { on = 0 }' "$WF"
}

@test "the page has every block the run takes" {
  local b
  for b in "${PAGE_BLOCKS[@]}"; do
    [ -n "$(page_block "${b%|*}" sh "${b#*|}")" ] || fail "no shell block ${b#*|} under '${b%|*}'"
  done
  [ -n "$(page_block "## 3. " "" 1)" ] || fail "step 3 shows no log lines"
}

@test "a section ends at the next heading, not at a comment in a block" {
  PAGE="$TMP/page.md"
  cat >"$PAGE" <<'EOF'
# Page

## 1. One

```sh
echo one
# a comment, not a heading
echo one more
```

```
the output
```

```sh
echo two
```

### A subsection

```sh
echo sub
```

## 2. Two

```sh
echo three
```
EOF
  [ "$(page_block "## 1. " sh 1)" = "$(printf 'echo one\n# a comment, not a heading\necho one more')" ] \
    || fail "block 1: $(page_block "## 1. " sh 1)"
  [ "$(page_block "## 1. " sh 2)" = "echo two" ] || fail "block 2: $(page_block "## 1. " sh 2)"
  [ "$(page_block "## 1. " "" 1)" = "the output" ] || fail "output: $(page_block "## 1. " "" 1)"
  [ -z "$(page_block "## 1. " sh 3)" ] || fail "step 1 runs into its subsection"
  [ "$(page_block "### A sub" sh 1)" = "echo sub" ] || fail "subsection: $(page_block "### A sub" sh 1)"
  [ "$(page_block "## 2. " sh 1)" = "echo three" ] || fail "step 2: $(page_block "## 2. " sh 1)"
}

@test "the run puts the checkout's files and chart where the page names its own" {
  local b code all=""
  for b in "${PAGE_BLOCKS[@]}"; do
    all+="$(page_block "${b%|*}" sh "${b#*|}" | localize /checkout/chart)"$'\n'
  done
  run grep -nF "$PAGE_URL" <<<"$all"
  [ "$status" -ne 0 ] || fail "the page's URL is left: $output"
  run grep -nF "$PAGE_CHART" <<<"$all"
  [ "$status" -ne 0 ] || fail "the released chart is left: $output"
  grep -qxF "url=$EXAMPLES" <<<"$all" || fail "\$url is not the checkout's examples/k3d"
  # The page's chart is where the install and the upgrade take it from.
  code="$(page_block "## 3. " sh 1 | localize /checkout/chart)"
  grep -q '^helm install k8s-borg /checkout/chart ' <<<"$code" || fail "the install: $code"
  code="$(page_block "## 7. " sh 1 | localize /checkout/chart)"
  grep -q '^helm upgrade k8s-borg /checkout/chart ' <<<"$code" || fail "the upgrade: $code"
  # Without a chart, the page's own.
  code="$(page_block "## 3. " sh 1 | localize "")"
  grep -q "^helm install k8s-borg $PAGE_CHART " <<<"$code" || fail "the install without a chart: $code"
}

@test "the steps are the shape the run relies on" {
  page_block "## 1. " sh 1 | grep -qxE 'k3d cluster create [a-z0-9-]+ --image rancher/k3s:v[0-9]+\.[0-9]+\.[0-9]+-k3s[0-9]+' \
    || fail "step 1 does not create one k3d cluster by its name and k3s image: $(page_block "## 1. " sh 1)"
  # Run in the background with exec, read for its local port.
  page_block "## 4. " sh 1 | grep -qx 'kubectl -n k8s-borg port-forward svc/k8s-borg-ui [0-9]*:8081' \
    || fail "step 4 is no single port-forward to Borg UI: $(page_block "## 4. " sh 1)"
  # Its waits run once, the rest until the plan is registered.
  page_block "## 3. " sh 2 | grep -q ' rollout status ' \
    || fail "step 3's second block waits for no rollout: $(page_block "## 3. " sh 2)"
  page_block "## 3. " sh 2 | grep -v ' rollout status ' | grep -q 'logs daemonset/k8s-borg-node' \
    || fail "step 3's second block shows no log of the node pod: $(page_block "## 3. " sh 2)"
  page_block "## 3. " "" 1 | grep -q "^Backup plan '$NODE_PLAN' " \
    || fail "step 3 shows no plan $NODE_PLAN"
  # A wait without one would hold the run, and a reader, for ever.
  local b
  for b in "${PAGE_BLOCKS[@]}"; do
    run bash -c 'grep " rollout status " | grep -v -- " --timeout="' <<<"$(page_block "${b%|*}" sh "${b#*|}")"
    [ -z "$output" ] || fail "a rollout wait under '${b%|*}' without a time limit: $output"
  done
  grep -qF "\`$NODE_PLAN\`" "$PAGE" || fail "the page does not name the plan $NODE_PLAN"
  grep -qF "\`$CLUSTER_PLAN\`" "$PAGE" || fail "the page does not name the plan $CLUSTER_PLAN"
}

@test "an image the registry does not know is not published; any other failure fails" {
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/docker" <<'EOF'
#!/bin/sh
[ "$1 $2" = "manifest inspect" ] || { echo "unexpected: $*" >&2; exit 2; }
case "$3" in
  *:there) echo '{}' ;;
  *:missing) echo "manifest unknown" >&2; exit 1 ;;
  *) echo "Get https://ghcr.io/v2/: dial tcp: connection refused" >&2; exit 1 ;;
esac
EOF
  chmod +x "$TMP/bin/docker"
  PATH="$TMP/bin:$PATH" run unpublished a:there b:missing c:there d:missing
  [ "$status" -eq 0 ] || fail "$output"
  [ "$output" = "$(printf 'b:missing\nd:missing')" ] || fail "$output"
  PATH="$TMP/bin:$PATH" run unpublished a:there e:down b:missing
  [ "$status" -ne 0 ] || fail "an unreachable registry passed: $output"
}

@test "the images of a chart directory are the chart's own" {
  command -v helm >/dev/null || fail "helm is required for the chart tests"
  run chart_images "$REPO_ROOT/chart"
  [ "$status" -eq 0 ] || fail "$output"
  grep -qx "ghcr.io/ioanalytica/k8s-borg:$(chart_app_version)" <<<"$output" \
    || fail "not the agent image of appVersion $(chart_app_version): $output"
  grep -qx "ghcr.io/ioanalytica/k8s-borg-ui:$(values_tag ioanalytica/k8s-borg-ui)" <<<"$output" \
    || fail "not the UI image of chart/values.yaml: $output"
}

@test "pull requests run on what the run reads; the others install the release" {
  local want
  for want in "chart/**" "examples/k3d/**" "site/guide/try-locally.md" \
              "tests/try-locally/**" ".github/workflows/try-locally.yml"; do
    pr_paths | grep -qxF "$want" || fail "pull requests do not run on $want: $(pr_paths | tr '\n' ' ')"
  done
  grep -qx '  schedule:' "$WF" || fail "no weekly run"
  grep -qx '  workflow_dispatch:' "$WF" || fail "no manual run"
  local step
  step="$(wf_step "$WF" "name: The page, end to end")"
  grep -qxF "          CHART: \${{ (github.event_name == 'pull_request' || inputs.chart == 'checkout') && './chart' || '' }}" <<<"$step" \
    || fail "pull requests do not install the checkout's chart, or the others not the release: $step"
  grep -qxF '        run: tests/try-locally/run.sh ${CHART:+"$CHART"}' <<<"$step" \
    || fail "the step runs something else: $step"
}

@test "the job has a time limit, and runs the k3d and the k3s the page is tested with" {
  wf_job "$WF" k3d | grep -qE '^    timeout-minutes: [0-9]+$' || fail "no time limit"
  local k3d k3s page
  k3d="$(sed -n 's/^ *K3D_VERSION: \([0-9]*\.[0-9]*\)\..*/\1/p' "$WF")"
  page="$(sed -n 's/.*Tested with k3d \([0-9]*\.[0-9]*\) and k3s \([0-9]*\.[0-9]*\)\..*/\1 \2/p' "$PAGE")"
  [ -n "$k3d" ] || fail "no K3D_VERSION in the workflow"
  [ -n "$page" ] || fail "the page says no \"Tested with k3d X.Y and k3s X.Y.\""
  [ "$k3d" = "${page% *}" ] || fail "the workflow installs k3d $k3d, the page is tested with ${page% *}"
  # The job runs step 1 as it is, so its k3s is the image step 1 names.
  k3s="$(page_block "## 1. " sh 1 | sed -n 's/.* --image rancher\/k3s:v\([0-9]*\.[0-9]*\)\..*/\1/p')"
  [ -n "$k3s" ] || fail "step 1 names no rancher/k3s image"
  [ "$k3s" = "${page#* }" ] || fail "step 1 runs k3s $k3s, the page is tested with ${page#* }"
}
