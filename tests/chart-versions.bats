#!/usr/bin/env bats
#
# The same version is written down in several files, and nothing used to keep
# them in step. They had drifted: the chart referenced a UI image tag the build
# workflow never produced, and the Chart.yaml annotations still named an agent
# image four releases old.
#
# Two sources of truth:
#   UI image    -> `git describe` of the borg-ui pin (docker/ui-app-version.sh;
#                  the server image is built from that commit)
#   agent image -> Chart.yaml appVersion (values.yaml image.tag defaults to it)

setup() { load helpers/versions; }

# --- the extractors themselves ------------------------------------------------
# If a file is restructured these stop matching, and every assertion below would
# then compare "" with "" and pass. Pin them first.

@test "the version sources are all readable" {
  [ -n "$(ui_app_version)" ]      || fail "no UI app version — is the submodule checked out, with its tags (docker/ui-app-version.sh --fetch-tags)?"
  [ -n "$(chart_version)" ]       || fail "no version: in Chart.yaml"
  [ -n "$(chart_app_version)" ]   || fail "no appVersion: in Chart.yaml"
  [ -n "$(annotation_image k8s-borg)" ]    || fail "no k8s-borg entry in the annotations block"
  [ -n "$(annotation_image k8s-borg-ui)" ] || fail "no k8s-borg-ui entry in the annotations block"
  [ -n "$(values_tag ioanalytica/k8s-borg-ui)" ] || fail "no borgUI image tag in values.yaml"
}

@test "values_tag does not read a tag out of the next block" {
  # A block with no tag of its own must yield nothing. Reading forward to the
  # next `tag:` would make the agent-image assertion below pass against the
  # initImage tag as soon as the empty `tag: ""` line is removed.
  cat >"$BATS_TEST_TMPDIR/values.yaml" <<'YAML'
image:
  repository: ioanalytica/k8s-borg
initImage:
  repository: busybox
  tag: "1.37"
YAML
  [ -z "$(values_tag ioanalytica/k8s-borg "$BATS_TEST_TMPDIR/values.yaml")" ]
  [ "$(values_tag busybox "$BATS_TEST_TMPDIR/values.yaml")" = "1.37" ]
}

# --- UI image -----------------------------------------------------------------

@test "values.yaml pins the UI image to the submodule's app version" {
  [ "$(values_tag ioanalytica/k8s-borg-ui)" = "$(ui_app_version)" ] \
    || fail "values.yaml has $(values_tag ioanalytica/k8s-borg-ui), the borg-ui pin is $(ui_app_version)"
}

@test "the UI app version names the pinned commit unless the pin is a release tag" {
  # borg-ui/VERSION is the same for every main commit after a release; a tag
  # built from it would be reused, and overwritten, by the next pin.
  local v pin
  v="$(ui_app_version)"
  pin="$(git -C "$REPO_ROOT/borg-ui" rev-parse HEAD)"
  if [[ "$v" =~ -g([0-9a-f]+)$ ]]; then
    [[ "$pin" == "${BASH_REMATCH[1]}"* ]] || fail "$v does not name the pin $pin"
  else
    [ "$(git -C "$REPO_ROOT/borg-ui" rev-parse "v$v^{commit}")" = "$pin" ] \
      || fail "$v has no commit suffix, but the pin $pin is not tag v$v"
  fi
}

@test "the Chart.yaml annotation names the same UI image as values.yaml" {
  [ "$(annotation_image k8s-borg-ui)" = "$(values_tag ioanalytica/k8s-borg-ui)" ]
}

@test "build.yml derives the UI app version instead of hardcoding it" {
  # A literal version here is what caused the drift: the chart moved to 2.2.6
  # while the workflow kept building and tagging 2.2.5.
  run grep -E 'APP_VERSION=[0-9]' <(build_workflow)
  [ "$status" -ne 0 ] || fail "build.yml hardcodes APP_VERSION: $output"
  build_workflow | grep -q 'APP_VERSION=\${{ needs.prep.outputs.app_version }}' \
    || fail "build.yml no longer derives APP_VERSION from the prep job"
}

@test "build.yml computes the UI app version with ui-app-version.sh" {
  build_workflow | grep -q 'app_version="$(./docker/ui-app-version.sh --fetch-tags)"' \
    || fail "the prep job no longer takes the UI app version from docker/ui-app-version.sh"
  run grep -E '<[[:space:]]*borg-ui/VERSION' <(build_workflow)
  [ "$status" -ne 0 ] || fail "build.yml reads borg-ui/VERSION: $output"
}

@test "build.yml tags the server image with the version it builds" {
  build_workflow | grep -q 'type=raw,value=\${{ needs.prep.outputs.app_version }}' \
    || fail "the server image is tagged with something other than APP_VERSION"
}

# --- agent image --------------------------------------------------------------

@test "the agent image tag is left to the chart appVersion" {
  # An explicit tag here would be a second place to bump, and the README
  # documents the default. Empty is the intended state.
  [ -z "$(values_tag ioanalytica/k8s-borg)" ]
}

@test "the Chart.yaml annotation names the agent image at appVersion" {
  [ "$(annotation_image k8s-borg)" = "$(chart_app_version)" ] \
    || fail "annotation says $(annotation_image k8s-borg), appVersion is $(chart_app_version)"
}

# --- third-party images -------------------------------------------------------

@test "the Chart.yaml annotation matches the Redis image in values.yaml" {
  [ "$(annotation_image redis)" = "$(values_tag redis)" ]
}

# --- chart version ------------------------------------------------------------

# --- the release-tag guard ----------------------------------------------------

@test "check-release-tag accepts a tag equal to the chart version" {
  run ./tests/check-release-tag.sh "$(chart_version)"
  [ "$status" -eq 0 ]
}

@test "check-release-tag rejects a tag the chart does not carry" {
  # Exactly the 1.1.2 case: a release tag ahead of chart/Chart.yaml, which used
  # to package and republish the older version instead of failing.
  run ./tests/check-release-tag.sh "9.9.9-not-a-release"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not match"* ]]
}

@test "check-release-tag without an argument is a usage error" {
  run ./tests/check-release-tag.sh
  [ "$status" -eq 2 ]
}

@test "the chart version is the appVersion, optionally with a -N revision" {
  # Chart-only changes get a -N suffix (1.0.23-1, 1.0.23-2, …); a new appVersion
  # resets to the bare number.
  local v app
  v="$(chart_version)"
  app="$(chart_app_version)"
  [[ "$v" == "$app" || "$v" =~ ^"$app"-[0-9]+$ ]] \
    || fail "chart version $v is neither $app nor $app-N"
}
