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

# inputs EVENT — the inputs of one trigger, "name type required default" per
# line (a dash for what is not set).
inputs() {
  awk -v ev="  $1:" '
    $0 == ev { on = 1; next }
    on && /^  [^ ]/ { exit }
    on && /^      [a-z][a-z-]*:$/ { if (n) print n, t, r, d; n = $1; sub(/:$/, "", n); t = "-"; r = "-"; d = "-"; next }
    on && n && $1 == "type:" { t = $2 }
    on && n && $1 == "required:" { r = $2 }
    on && n && $1 == "default:" { d = $2 }
    END { if (n) print n, t, r, d }' "$WF"
}

@test "pull requests run on what the run reads; the others install the release or a version" {
  local want
  for want in "chart/**" "examples/k3d/**" "site/guide/try-locally.md" \
              "tests/try-locally/**" ".github/workflows/try-locally.yml"; do
    pr_paths | grep -qxF "$want" || fail "pull requests do not run on $want: $(pr_paths | tr '\n' ' ')"
  done
  grep -qx '  schedule:' "$WF" || fail "no weekly run"
  grep -qx '  workflow_dispatch:' "$WF" || fail "no manual run"
  # By hand: the release or the checkout, or a published version.
  inputs workflow_dispatch | grep -qx 'chart choice - release' || fail "the manual run's chart: $(inputs workflow_dispatch)"
  inputs workflow_dispatch | grep -qx 'chart-version string - -' || fail "the manual run takes no version: $(inputs workflow_dispatch)"
  # Called by build.yml: the tag's version, nothing else to choose.
  [ "$(inputs workflow_call)" = "chart-version string true -" ] || fail "the called run's inputs: $(inputs workflow_call)"
  local step
  step="$(wf_step "$WF" "name: The chart")"
  grep -qxF '          VERSION: ${{ inputs.chart-version }}' <<<"$step" \
    || fail "the chart step does not read the version input: $step"
  grep -qxF "          CHOICE: \${{ github.event_name == 'pull_request' && 'checkout' || inputs.chart }}" <<<"$step" \
    || fail "pull requests do not install the checkout's chart, or the others not the choice: $step"
  step="$(wf_step "$WF" "name: The page, end to end")"
  grep -qxF '          CHART: ${{ steps.chart.outputs.dir }}' <<<"$step" \
    || fail "the run does not get the chart step's directory: $step"
  grep -qxF '          PUBLISHED: ${{ steps.chart.outputs.published }}' <<<"$step" \
    || fail "the run does not learn whether the chart is a published one: $step"
  grep -qxF '        run: tests/try-locally/run.sh ${PUBLISHED:+--published} ${CHART:+"$CHART"}' <<<"$step" \
    || fail "the step runs something else: $step"
}

@test "a pull request's newer push replaces its run; a called run cannot cancel the tag's build" {
  # On the job, not the workflow: a called workflow's group is computed with
  # the tag build's context, and must not be able to cancel that build. The
  # inputs are in the group: it keeps one run waiting at most, so versions
  # dispatched in a row would otherwise drop one.
  ! grep -q '^concurrency:' "$WF" || fail "concurrency at the workflow level"
  local job
  job="$(wf_job "$WF" k3d)"
  grep -qxF '      group: try-locally-${{ github.event_name }}-${{ github.ref }}-${{ inputs.chart }}-${{ inputs.chart-version }}' <<<"$job" \
    || fail "the group is not the event's, the ref's and the inputs': $(grep -F 'group:' <<<"$job")"
  grep -qxF "      cancel-in-progress: \${{ github.event_name == 'pull_request' }}" <<<"$job" \
    || fail "a run other than a pull request's can cancel one: $(grep -F 'cancel-in-progress' <<<"$job")"
}

# chart_step VERSION CHOICE — the chart step's script with a helm that logs
# its arguments and lays out what `helm pull --untar` would. The step's
# outputs are in $BATS_TEST_TMPDIR/output, `out NAME` reads one.
chart_step() {
  local bin="$BATS_TEST_TMPDIR/bin" out="$BATS_TEST_TMPDIR/output"
  mkdir -p "$bin" "$BATS_TEST_TMPDIR/temp"
  : >"$BATS_TEST_TMPDIR/helm.log"
  cat >"$bin/helm" <<'EOF'
#!/bin/sh
echo "$*" >>"$HELM_LOG"
dir=""
while [ $# -gt 0 ]; do [ "$1" = --untardir ] && dir="$2"; shift; done
[ -z "$dir" ] || mkdir -p "$dir/k8s-borg"
EOF
  chmod +x "$bin/helm"
  wf_run "$WF" 'name: The chart' >"$BATS_TEST_TMPDIR/chart.sh"
  [ -s "$BATS_TEST_TMPDIR/chart.sh" ] || fail "no chart step script"
  : >"$out"
  PATH="$bin:$PATH" HELM_LOG="$BATS_TEST_TMPDIR/helm.log" VERSION="$1" CHOICE="$2" \
    RUNNER_TEMP="$BATS_TEST_TMPDIR/temp" GITHUB_OUTPUT="$out" bash -e "$BATS_TEST_TMPDIR/chart.sh" >&2
}
out() { sed -n "s/^$1=//p" "$BATS_TEST_TMPDIR/output"; }

@test "a version is pulled from GHCR, the checkout's chart is ./chart, the release is none" {
  local dir="$BATS_TEST_TMPDIR/temp/chart/k8s-borg"
  # The tag's build and a manual run with a version: the page's chart at
  # that version, as a directory, with the images it names — in the
  # registry, or the run fails.
  chart_step 1.3.2-rc.1 release || fail "the step failed on a version"
  [ "$(out dir)" = "$dir" ] || fail "a version hands on '$(out dir)'"
  [ -d "$dir" ] || fail "$dir is not where helm pull --untar put the chart"
  [ "$(out published)" = 1 ] || fail "a version is not a published chart: '$(out published)'"
  grep -qxF "pull $PAGE_CHART --version 1.3.2-rc.1 --untar --untardir $BATS_TEST_TMPDIR/temp/chart" "$BATS_TEST_TMPDIR/helm.log" \
    || fail "not the page's chart at the version: $(cat "$BATS_TEST_TMPDIR/helm.log")"
  # A version set by hand wins over the choice.
  chart_step 1.3.2-rc.1 checkout || fail "the step failed on a version with the checkout"
  [ "$(out dir)" = "$dir" ] || fail "a version with the checkout hands on '$(out dir)'"
  # A pull request, and the manual choice: the checkout's chart, no pull,
  # and images it may still lack.
  chart_step "" checkout || fail "the step failed on the checkout"
  [ "$(out dir)" = ./chart ] || fail "the checkout hands on '$(out dir)'"
  [ -z "$(out published)" ] || fail "the checkout counts as published"
  [ ! -s "$BATS_TEST_TMPDIR/helm.log" ] || fail "the checkout pulled a chart: $(cat "$BATS_TEST_TMPDIR/helm.log")"
  # The weekly run (no input at all) and the manual default: the release.
  chart_step "" "" || fail "the step failed without inputs"
  [ -z "$(out dir)" ] && [ -z "$(out published)" ] || fail "the weekly run hands on '$(out dir)' '$(out published)'"
  chart_step "" release || fail "the step failed on the release"
  [ -z "$(out dir)" ] || fail "the release hands on '$(out dir)'"
  [ ! -s "$BATS_TEST_TMPDIR/helm.log" ] || fail "the release pulled a chart: $(cat "$BATS_TEST_TMPDIR/helm.log")"
}

# run_sh ARG… — run.sh up to its image check: a docker that knows no image,
# a k3d without a cluster, stand-ins for the tools it needs later; helm is
# the real one, for the chart's images.
run_sh() {
  local t
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\n[ "$1 $2" = "manifest inspect" ] || exit 2\necho "manifest unknown" >&2\nexit 1\n' >"$TMP/bin/docker"
  printf '#!/bin/sh\nexit 1\n' >"$TMP/bin/k3d"
  for t in kubectl ssh-keygen openssl curl jq; do printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/$t"; done
  chmod +x "$TMP"/bin/*
  PATH="$TMP/bin:$PATH" run "$REPO_ROOT/tests/try-locally/run.sh" "$@"
}

@test "a chart whose images are not published is a notice; a published one with such images fails" {
  command -v helm >/dev/null || fail "helm is required for the chart tests"
  # run.sh takes its examples/k3d from the checkout and refuses a path the
  # page's unquoted commands would split; it refuses in such a checkout
  # before it reaches the images.
  case "$REPO_ROOT" in
    *[!A-Za-z0-9._/+@-]*) skip "run.sh refuses the checkout's path $REPO_ROOT" ;;
  esac
  run_sh "$REPO_ROOT/chart"
  [ "$status" -eq 0 ] || fail "the checkout's chart with unpublished images failed ($status): $output"
  grep -qF "◆ not run: the chart names images the tag's build has not published yet: ghcr.io/ioanalytica/" <<<"$output" \
    || fail "no notice: $output"
  run_sh --published "$REPO_ROOT/chart"
  [ "$status" -eq 1 ] || fail "a published chart with missing images did not fail ($status): $output"
  grep -qF "✗ the published chart names images the registry does not have: ghcr.io/ioanalytica/" <<<"$output" \
    || fail "no failure: $output"
  run_sh --published
  [ "$status" -eq 2 ] || fail "--published without a chart ($status): $output"
  run_sh --release "$REPO_ROOT/chart"
  [ "$status" -eq 2 ] || fail "an unknown option ($status): $output"
  run_sh "$REPO_ROOT/chart" "$REPO_ROOT/chart"
  [ "$status" -eq 2 ] || fail "two charts ($status): $output"
}

@test "each tag's build runs the page against what it published, after the tagging, beside the release" {
  local build="$REPO_ROOT/.github/workflows/build.yml" job needs j
  job="$(wf_job "$build" try-locally)"
  [ -n "$job" ] || fail "build.yml has no try-locally job"
  grep -qxF '    uses: ./.github/workflows/try-locally.yml' <<<"$job" || fail "the job does not call the workflow: $job"
  grep -qxF '      chart-version: ${{ github.ref_name }}' <<<"$job" || fail "the job does not pass the tag as the version: $job"
  grep -qxF "    if: startsWith(github.ref, 'refs/tags/')" <<<"$job" || fail "the job is not guarded to tags: $job"
  # After the tag job, which sets the tags once every image and the chart is
  # signed (release-signing.bats): run.sh pulls the chart by its version and
  # installs it with the images it names by tag, as users get them.
  grep -qx '    needs: tag' <<<"$job" || fail "the job does not wait for the tag job alone: $(grep -F needs: <<<"$job")"
  # Nothing waits for it: a red run on X.Y.Z holds up neither the signatures
  # nor the release.
  run awk '/^  [a-z][a-z0-9-]*:$/ { j = $1; sub(/:$/, "", j) }
           $1 == "needs:" && /try-locally/ { print j }' "$build"
  [ -z "$output" ] || fail "a job waits for try-locally: $output"
  # The called workflow asks for contents: read and nothing more; the job
  # grants it that, not the write permissions of its neighbours.
  [ "$(grep -E '^      [a-z-]+: (read|write)$' <<<"$job" | tr -d ' ')" = "contents:read" ] \
    || fail "the job's permissions: $(grep -E '^      [a-z-]+: (read|write)$' <<<"$job" | tr -d ' ' | tr '\n' ' ')"
  [ "$(awk '/^permissions:/ { on = 1; next } on && /^  [a-z-]+:/ { print $1 $2; next } on { exit }' "$WF")" = "contents:read" ] \
    || fail "the workflow asks for more than contents: read"
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
