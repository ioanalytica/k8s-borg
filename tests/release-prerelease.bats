#!/usr/bin/env bats
#
# Every version with a -suffix is a prerelease: a beta (1.2.4-beta.1) as well
# as a chart revision (1.2.3-1). Betas used to be published like releases: the
# GitHub release of each became the repository's Latest, and every tag moved
# the `latest` image tags.

setup() {
  load helpers/versions
  load helpers/workflows
  # The expressions build.yml has to use, written out once here.
  PRERELEASE="\${{ contains(github.ref_name, '-') }}"
  RELEASE="\${{ !contains(github.ref_name, '-') }}"
  LATEST="type=raw,value=latest,enable=\${{ startsWith(github.ref, 'refs/tags/') && !contains(github.ref_name, '-') }}"
}

@test "a version with a -suffix is a GitHub prerelease, never the Latest release" {
  local s
  s="$(wf_step "$BUILD_WF" 'name: Create GitHub Release')"
  grep -q 'uses: softprops/action-gh-release@' <<<"$s" || fail "no release step found"
  grep -qxF "          prerelease: $PRERELEASE" <<<"$s"  || fail "the release is not marked as a prerelease for a -suffix"
  grep -qxF "          make_latest: $RELEASE" <<<"$s"    || fail "a -suffix version can become the Latest release"
}

@test "the latest image tag moves with releases only" {
  local j tags
  [ -n "$(wf_image_jobs "$BUILD_WF")" ] || fail "no image jobs found"
  for j in $(wf_image_jobs "$BUILD_WF"); do
    tags="$(wf_job "$BUILD_WF" "$j" | grep -F 'value=latest')"
    [ "$(sed 's/^ *//' <<<"$tags")" = "$LATEST" ] || fail "job $j: ${tags:-no latest tag}"
  done
}

@test "no tag rule adds latest behind the release check's back" {
  # metadata-action's automatic `latest` comes with type=ref,event=tag for any
  # tag, prereleases included, and with flavor latest=true for everything.
  # type=semver leaves it out for a prerelease on its own.
  run grep -nE 'type=ref,event=tag|latest=true' "$BUILD_WF" "$REPO_ROOT/.github/workflows/build-image.yml"
  [ "$status" -ne 0 ] || fail "$output"
}
