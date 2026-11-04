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

@test "the tag job refuses to move latest for a version with a -suffix" {
  # build-image.yml computes the tags, the tag job sets them: should a tag
  # rule ever add latest for a prerelease, the job fails before it sets any.
  local bin="$BATS_TEST_TMPDIR/bin" g=ghcr.io/ioanalytica
  mkdir -p "$bin"
  wf_run "$BUILD_WF" 'name: Tag the images' >"$BATS_TEST_TMPDIR/tag.sh"
  [ -s "$BATS_TEST_TMPDIR/tag.sh" ] || fail "no tag script found"
  # oras sets tags, finds none, and every index is of run 50.
  cat >"$bin/oras" <<'SH'
#!/usr/bin/env bash
case "$1" in
  tag)      echo "$*" >>"$BATS_TEST_TMPDIR/oras.log" ;;
  resolve)  echo "Error: failed to resolve digest: $2: not found" >&2; exit 1 ;;
  manifest) echo '{"annotations":{"com.ioanalytica.k8s-borg.build-run":"50"}}' ;;
  *)        exit 1 ;;
esac
SH
  chmod +x "$bin/oras"
  export AGENT="$g/k8s-borg@sha256:1" AGENT_TAGS="$g/k8s-borg:1.3.3-rc.1"
  export RUNTIME_BASE="$g/k8s-borg-ui-runtime-base@sha256:2" RUNTIME_BASE_TAGS="$g/k8s-borg-ui-runtime-base:runtime-x-r1"
  export SERVER="$g/k8s-borg-ui@sha256:3" SERVER_TAGS="$(printf '%s\n' "$g/k8s-borg-ui:2.4.6" "$g/k8s-borg-ui:latest")"
  GITHUB_REF_NAME=1.3.3-rc.1 PATH="$bin:$PATH" RUNNER_TEMP="$BATS_TEST_TMPDIR" run bash -eo pipefail "$BATS_TEST_TMPDIR/tag.sh"
  [ "$status" -ne 0 ] && [[ "$output" == *"1.3.3-rc.1 is a prerelease: $g/k8s-borg-ui:latest stays where it is"* ]] \
    || fail "latest passed for a prerelease: $output"
  [ ! -e "$BATS_TEST_TMPDIR/oras.log" ] || fail "tags were set: $(cat "$BATS_TEST_TMPDIR/oras.log")"
  # The same list for a release goes through.
  GITHUB_REF_NAME=1.3.3 PATH="$bin:$PATH" RUNNER_TEMP="$BATS_TEST_TMPDIR" run bash -eo pipefail "$BATS_TEST_TMPDIR/tag.sh"
  [ "$status" -eq 0 ] || fail "$output"
  grep -qxF "tag $SERVER 2.4.6 latest" "$BATS_TEST_TMPDIR/oras.log" || fail "oras was asked: $(cat "$BATS_TEST_TMPDIR/oras.log")"
}

@test "no tag rule adds latest behind the release check's back" {
  # metadata-action's automatic `latest` comes with type=ref,event=tag for any
  # tag, prereleases included, and with flavor latest=true for everything.
  # type=semver leaves it out for a prerelease on its own.
  run grep -nE 'type=ref,event=tag|latest=true' "$BUILD_WF" "$REPO_ROOT/.github/workflows/build-image.yml"
  [ "$status" -ne 0 ] || fail "$output"
}
