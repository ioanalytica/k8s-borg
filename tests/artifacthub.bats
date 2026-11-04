#!/usr/bin/env bats
#
# The chart's listing on Artifact Hub: the artifacthub.io/* annotations of
# chart/Chart.yaml, the ones a release adds (scripts/artifacthub-annotations.sh),
# the repository metadata in artifacthub-repo.yml, and the chart and tag jobs
# of build.yml that publish both. The image list is chart-versions.bats' business.
#
# Artifact Hub ignores what it cannot parse and says so only in its control
# panel, so these check the values against what its documentation accepts.

setup() {
  load helpers/common
  load helpers/versions
  load helpers/workflows
  common_setup
  command -v yq >/dev/null || fail "yq is required for the Artifact Hub tests"
  SCRIPT="$REPO_ROOT/scripts/artifacthub-annotations.sh"
  REPO_META="$REPO_ROOT/artifacthub-repo.yml"
  DOCS=https://k8s-borg.ioanalytica.com
}

teardown() { common_teardown; }

# annotation KEY [FILE] — the value of one annotation of a Chart.yaml.
annotation() { yq ".annotations[\"$1\"] // \"\"" "${2:-$CHART}"; }

# other_annotations [FILE] — the annotation keys that are not artifacthub.io/ ones.
other_annotations() { yq '.annotations | keys | .[] | select(test("^artifacthub[.]io/") | not)' "${1:-$CHART}"; }

# --- chart/Chart.yaml ------------------------------------------------------------

@test "the chart's homepage is the documentation site" {
  [ "$(yq .home "$CHART")" = "$DOCS" ] || fail "home: $(yq .home "$CHART")"
}

@test "the license annotation is the SPDX identifier the chart states" {
  local spdx
  spdx="$(sed -n 's/^# SPDX-License-Identifier: //p' "$CHART")"
  [ -n "$spdx" ] || fail "no SPDX-License-Identifier line in Chart.yaml"
  [ "$(annotation artifacthub.io/license)" = "$spdx" ] \
    || fail "artifacthub.io/license is '$(annotation artifacthub.io/license)', the chart says $spdx"
}

@test "the category is one Artifact Hub knows" {
  case "$(annotation artifacthub.io/category)" in
    ai-machine-learning | analytics | data-processing | database | integration-delivery | \
      monitoring-logging | networking | security | storage | streaming-messaging | web-applications) ;;
    *) fail "unknown category '$(annotation artifacthub.io/category)'" ;;
  esac
}

@test "every link has a name and a URL, and support goes to the issues" {
  local links
  links="$(annotation artifacthub.io/links)"
  [ -n "$links" ] || fail "no artifacthub.io/links"
  [ "$(yq '[.[] | select(.name == "" or .name == null or .url == "" or .url == null)] | length' <<<"$links")" = 0 ] \
    || fail "a link without name or url: $links"
  [ "$(yq '.[] | select(.name == "support") | .url' <<<"$links")" = "https://github.com/ioanalytica/k8s-borg/issues" ] \
    || fail "no support link to the issues"
}

@test "the links into the documentation site name pages it has" {
  local url page n=0
  while IFS= read -r url; do
    [[ "$url" == "$DOCS"/* ]] || continue
    n=$((n + 1))
    page="${url#"$DOCS"/}"
    page="${page%%#*}"
    [ -f "$REPO_ROOT/site/$page.md" ] || fail "$url: no site/$page.md"
  done < <(annotation artifacthub.io/links | yq '.[].url')
  [ "$n" -gt 0 ] || fail "no link into the documentation site"
}

@test "the block annotations are YAML Artifact Hub can parse" {
  local key
  for key in artifacthub.io/links artifacthub.io/images; do
    annotation "$key" | yq -e 'type == "!!seq" and length > 0' >/dev/null \
      || fail "$key is not a non-empty YAML list"
  done
}

@test "every annotation is an Artifact Hub one" {
  # Artifact Hub reads none of the Bitnami-style keys (category, licenses,
  # images) the chart used to carry, and a second image list would drift.
  run other_annotations
  [ "$status" -eq 0 ] && [ -z "$output" ] || fail "other annotations: $output"
}

@test "other_annotations finds the keys of other tools" {
  printf '%s\n' 'annotations:' '  artifacthub.io/license: x' '  category: Storage' '  artifacthubXio/y: z' >"$TMP/Chart.yaml"
  [ "$(other_annotations "$TMP/Chart.yaml")" = "$(printf '%s\n' category artifacthubXio/y)" ] \
    || fail "got: $(other_annotations "$TMP/Chart.yaml")"
}

@test "the repository's Chart.yaml leaves changes and prerelease to the release" {
  [ -z "$(annotation artifacthub.io/changes)" ]    || fail "chart/Chart.yaml carries artifacthub.io/changes"
  [ -z "$(annotation artifacthub.io/prerelease)" ] || fail "chart/Chart.yaml carries artifacthub.io/prerelease"
}

# --- scripts/artifacthub-annotations.sh -------------------------------------------

# A Chart.yaml and a CHANGELOG.md for the script to work on.
fixtures() {
  cat >"$TMP/Chart.yaml" <<'YAML'
apiVersion: v2
name: k8s-borg
version: 1.2.3
annotations:
  artifacthub.io/license: AGPL-3.0-only
dependencies: []
YAML
  cat >"$TMP/CHANGELOG.md" <<'MD'
# Changelog

## 1.2.3

* **Borg UI 2.4.6.** The pin stays.

### Chart and images

* **A `value` with "quotes" and a \ backslash.** More text
  on a second line.
  - a nested point, part of the bullet above

* A bullet without a lead, e.g. this one. Its second sentence is left out.

### Project and CI

* **CI is faster.**

### Documentation

* **A new page:
  over two lines.**

## 1.2.3-beta.1

* **The beta.**
MD
}

@test "the changes are the lead sentences of the entry, as plain text, without Project and CI" {
  fixtures
  run "$SCRIPT" 1.2.3 "$TMP/Chart.yaml" "$TMP/CHANGELOG.md"
  [ "$status" -eq 0 ] || fail "$output"
  local want got
  want="$(printf '%s\n' \
    'Borg UI 2.4.6.' \
    'A value with "quotes" and a \ backslash.' \
    'A bullet without a lead, e.g. this one.' \
    'A new page: over two lines.')"
  got="$(annotation artifacthub.io/changes "$TMP/Chart.yaml" | yq '.[]')"
  [ "$got" = "$want" ] || fail "got:
$got"
  [ "$(annotation artifacthub.io/prerelease "$TMP/Chart.yaml")" = false ]
  # The rest of the file is as it was.
  [ "$(annotation artifacthub.io/license "$TMP/Chart.yaml")" = AGPL-3.0-only ]
  [ "$(yq -o json -I0 .dependencies "$TMP/Chart.yaml")" = '[]' ]
}

@test "a prerelease without a section of its own takes the changes of its release" {
  fixtures
  run "$SCRIPT" 1.2.3-rc.1 "$TMP/Chart.yaml" "$TMP/CHANGELOG.md"
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(annotation artifacthub.io/prerelease "$TMP/Chart.yaml")" = true ] || fail "not a prerelease"
  annotation artifacthub.io/changes "$TMP/Chart.yaml" | yq -e 'length == 4' >/dev/null \
    || fail "changes: $(annotation artifacthub.io/changes "$TMP/Chart.yaml")"
}

@test "a version with a -suffix is a prerelease" {
  local v
  for v in 1.2.3-beta.1 1.2.3-1 1.3.0-rc.1; do
    fixtures
    run "$SCRIPT" "$v" "$TMP/Chart.yaml" "$TMP/CHANGELOG.md"
    [ "$status" -eq 0 ] || fail "$v: $output"
    [ "$(annotation artifacthub.io/prerelease "$TMP/Chart.yaml")" = true ] || fail "$v is not a prerelease"
  done
}

@test "a version without a CHANGELOG entry gets no changes" {
  fixtures
  run "$SCRIPT" 1.2.4 "$TMP/Chart.yaml" "$TMP/CHANGELOG.md"
  [ "$status" -eq 0 ] || fail "$output"
  [ -z "$(annotation artifacthub.io/changes "$TMP/Chart.yaml")" ] || fail "changes for a version with no entry"
  [ "$(annotation artifacthub.io/prerelease "$TMP/Chart.yaml")" = false ]
}

@test "the script refuses to write a second changes or prerelease" {
  local key
  for key in artifacthub.io/changes artifacthub.io/prerelease; do
    fixtures
    awk -v k="$key" '{ print } $0 == "annotations:" { print "  " k ": x" }' "$TMP/Chart.yaml" >"$TMP/before"
    cp "$TMP/before" "$TMP/Chart.yaml"
    run "$SCRIPT" 1.2.3 "$TMP/Chart.yaml" "$TMP/CHANGELOG.md"
    [ "$status" -eq 1 ] || fail "$key: status $status: $output"
    [[ "$output" == *"already has $key"* ]] || fail "$output"
    cmp -s "$TMP/before" "$TMP/Chart.yaml" || fail "$key: the file was changed"
  done
}

@test "the script fails on a Chart.yaml without annotations, and without a version" {
  fixtures
  sed -i.bak '/^annotations:$/,/^  artifacthub/d' "$TMP/Chart.yaml"
  run "$SCRIPT" 1.2.3 "$TMP/Chart.yaml" "$TMP/CHANGELOG.md"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  run "$SCRIPT"
  [ "$status" -eq 2 ] || fail "status $status without a version"
}

@test "the chart with the release annotations of its version still lints" {
  cp -R "$REPO_ROOT/chart" "$TMP/chart"
  run "$SCRIPT" "$(chart_version)" "$TMP/chart/Chart.yaml"
  [ "$status" -eq 0 ] || fail "$output"
  run helm lint "$TMP/chart"
  [ "$status" -eq 0 ] || fail "$output"
  annotation artifacthub.io/changes "$TMP/chart/Chart.yaml" | yq -e 'type == "!!seq" and length > 0' >/dev/null \
    || fail "no changes for $(chart_version)"
}

# --- build.yml ------------------------------------------------------------------

@test "the chart job sets the tag's version and writes the release annotations before it lints and packages" {
  local job check version annotate package
  job="$(wf_job "$BUILD_WF" chart)"
  check="$(grep -n -- '- name: Tag must match the chart version' <<<"$job" | cut -d: -f1)"
  version="$(grep -n -- '- name: Chart version from the tag (tags only)' <<<"$job" | cut -d: -f1)"
  annotate="$(grep -n -- '- name: Artifact Hub annotations (tags only)' <<<"$job" | cut -d: -f1)"
  package="$(grep -n -- '- name: Lint & package' <<<"$job" | cut -d: -f1)"
  [ -n "$check" ] && [ -n "$version" ] && [ -n "$annotate" ] && [ -n "$package" ] || fail "steps not found"
  [ "$check" -lt "$version" ] && [ "$version" -lt "$annotate" ] || fail "the version is set out of order"
  [ "$annotate" -lt "$package" ] || fail "the annotations are written after the chart is packaged"
  grep -qxF '        run: scripts/chart-release-version.sh "$GITHUB_REF_NAME"' <<<"$(wf_step "$BUILD_WF" 'name: Chart version from the tag (tags only)')" \
    || fail "the chart does not get the tag's version"
  local s
  s="$(wf_step "$BUILD_WF" 'name: Artifact Hub annotations (tags only)')"
  grep -qxF "        if: startsWith(github.ref, 'refs/tags/')" <<<"$s" || fail "not limited to tags"
  grep -qxF '        run: scripts/artifacthub-annotations.sh "$GITHUB_REF_NAME"' <<<"$s" || fail "$s"
}

@test "the tag job pushes the repository metadata where Artifact Hub reads it, before the chart's version" {
  # Artifact Hub reads the metadata when a new version appears: the tag job
  # sets the chart's version, after the signing (release-signing.bats).
  local job meta version s
  job="$(wf_job "$BUILD_WF" tag)"
  grep -qxF "    if: startsWith(github.ref, 'refs/tags/')" <<<"$job" || fail "not limited to tags"
  meta="$(grep -n -- '- name: Artifact Hub repository metadata' <<<"$job" | cut -d: -f1)"
  version="$(grep -n -- '- name: Tag the chart' <<<"$job" | cut -d: -f1)"
  [ -n "$meta" ] && [ -n "$version" ] || fail "steps not found"
  [ "$meta" -lt "$version" ] || fail "the metadata goes up after the chart's version"
  s="$(wf_step "$BUILD_WF" 'name: Artifact Hub repository metadata')"
  grep -qF 'oras push "$REGISTRY/$OWNER/charts/k8s-borg:artifacthub.io" \' <<<"$s" || fail "not pushed to the tag artifacthub.io"
  grep -qF -- '--config /dev/null:application/vnd.cncf.artifacthub.config.v1+yaml \' <<<"$s" || fail "wrong config media type"
  grep -qF 'artifacthub-repo.yml:application/vnd.cncf.artifacthub.repository-metadata.layer.v1.yaml' <<<"$s" \
    || fail "wrong layer media type"
}

# --- artifacthub-repo.yml -----------------------------------------------------------

@test "the repository metadata names the Artifact Hub repository" {
  [[ "$(yq .repositoryID "$REPO_META")" =~ ^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$ ]] \
    || fail "repositoryID: $(yq .repositoryID "$REPO_META")"
}

@test "the repository metadata keeps every -suffix version out, and no release" {
  # Artifact Hub takes the highest version as the latest one, a beta above
  # the last release included. Its version rule is a regular expression.
  local re v
  re="$(yq '.ignore[] | select(.name == "k8s-borg") | .version' "$REPO_META")"
  [ -n "$re" ] || fail "no ignore rule for k8s-borg"
  [ "$(yq '.ignore[] | select(.name == "k8s-borg") | .version' "$REPO_META" | wc -l)" -eq 1 ] || fail "several rules"
  for v in 1.2.4-beta.1 1.2.3-1 1.3.0-rc.1 1.1.7-alpha; do
    grep -qE -- "$re" <<<"$v" || fail "$v is listed"
  done
  for v in 1.3.0 1.2.3 10.0.1; do
    ! grep -qE -- "$re" <<<"$v" || fail "release $v is ignored"
  done
}
