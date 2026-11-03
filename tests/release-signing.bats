#!/usr/bin/env bats
#
# The SBOM, the provenance and the Sigstore signatures of a release. Nothing
# else would notice an edit that drops one of them: the release still builds,
# pushes and goes green, only without what users verify it by. Like the
# build.yml checks in chart-versions.bats, these read the workflow files.

setup() {
  load helpers/versions
  load helpers/workflows
  WF="$REPO_ROOT/.github/workflows"
  BUILD_IMAGE="$WF/build-image.yml"
}

sign_step() { wf_step "$BUILD_WF" 'name: Sign by digest'; }

# signed_var PATH JOB — the variable of the sign step that holds
# ghcr.io/ioanalytica/PATH at the digest JOB outputs.
signed_var() {
  sign_step | awk -v want="/$1@\${{ needs.$2.outputs.digest }}" '
    $1 ~ /^[A-Z_]+:$/ && substr($0, length($0) - length(want) + 1) == want { sub(/:$/, "", $1); print $1 }'
}

@test "the extractors find what the checks below read" {
  [ -n "$(wf_step "$BUILD_IMAGE" 'id: build')" ]     || fail "no build step in build-image.yml"
  [ -n "$(wf_job "$BUILD_IMAGE" merge)" ]            || fail "no merge job in build-image.yml"
  [ -n "$(wf_job "$BUILD_WF" sign)" ]                || fail "no sign job in build.yml"
  [ -n "$(sign_step)" ]                           || fail "no 'Sign by digest' step in build.yml"
  [ "$(wf_image_jobs "$BUILD_WF" | tr '\n' ' ')" = "agent runtime-base server " ] \
    || fail "image jobs: $(wf_image_jobs "$BUILD_WF" | tr '\n' ' ')"
  [ "$(signed_var k8s-borg agent)" = AGENT ]      || fail "signed_var does not find the agent image"
  # A step ends where the next one starts, a job where the next one starts.
  [ "$(wf_step "$BUILD_IMAGE" 'id: build' | grep -c 'uses:')" = 1 ] || fail "the build step ran into the next step"
  [ "$(wf_job "$BUILD_IMAGE" build | grep -c 'runs-on:')" = 1 ]     || fail "the build job ran into the next job"
}

# --- SBOM and provenance ------------------------------------------------------

@test "every platform image gets an SBOM and max-mode SLSA v1 provenance" {
  local s
  s="$(wf_step "$BUILD_IMAGE" 'id: build')"
  grep -q 'uses: docker/build-push-action@' <<<"$s" || fail "the build step no longer runs build-push-action"
  grep -Eq '^ +sbom: true$' <<<"$s" || fail "the image build no longer attaches an SBOM"
  # Left out, the mode follows the repository's visibility (max for public,
  # min for private) and the predicate follows BuildKit's default.
  grep -Eq '^ +provenance: mode=max,version=v1$' <<<"$s" \
    || fail "the image build no longer states max-mode SLSA v1 provenance"
}

@test "no secret goes into a build argument, which max-mode provenance publishes" {
  local s j
  s="$(wf_step "$BUILD_IMAGE" 'id: build')"
  [ "$(grep -E '^ +build-args:' <<<"$s")" = '          build-args: ${{ inputs.build-args }}' ] \
    || fail "build-image.yml adds build arguments of its own: $(grep -E '^ +build-args:' <<<"$s")"
  ! grep -q 'secrets' <<<"$s" || fail "the build step references a secret: $(grep 'secrets' <<<"$s")"
  for j in $(wf_image_jobs "$BUILD_WF"); do
    ! wf_job "$BUILD_WF" "$j" | grep -q 'secrets' \
      || fail "build.yml job $j hands build-image.yml a secret: $(wf_job "$BUILD_WF" "$j" | grep 'secrets')"
  done
}

@test "the merge passes on the digest imagetools created, not one read back by tag" {
  local m
  m="$(wf_job "$BUILD_IMAGE" merge)"
  grep -qF 'docker buildx imagetools create --metadata-file "$RUNNER_TEMP/index-metadata.json"' <<<"$m" \
    || fail "imagetools create no longer writes the metadata the digest is read from"
  ! grep -qE 'inspect "\$IMAGE:|steps\.meta\.outputs\.version' <<<"$(wf_step "$BUILD_IMAGE" 'name: Inspect')" \
    || fail "the Inspect step resolves a tag again"
  grep -qF 'digest: ${{ steps.index.outputs.digest }}' <<<"$m" || fail "the merge job does not pass the digest on"
  grep -qF 'value: ${{ jobs.merge.outputs.digest }}' "$BUILD_IMAGE" \
    || fail "build-image.yml does not output the digest of the merged index"
}

# The merge job's Inspect script, run against a stub docker that serves an
# index of two platforms and the SBOM and provenance documents of each.
inspect_fixture() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin" "$BATS_TEST_TMPDIR/fix"
  wf_run "$BUILD_IMAGE" 'name: Inspect' >"$BATS_TEST_TMPDIR/inspect.sh"
  [ -s "$BATS_TEST_TMPDIR/inspect.sh" ] || fail "no Inspect script found"
  cat >"$bin/docker" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$FIX/docker.log"
case "$*" in
  *--raw*)                 cat "$FIX/raw.json" ;;
  *'{{json .SBOM}}'*)       cat "$FIX/sbom.json" ;;
  *'{{json .Provenance}}'*) cat "$FIX/provenance.json" ;;
  *)                       echo "Name: $4" ;;
esac
SH
  chmod +x "$bin/docker"
  export FIX="$BATS_TEST_TMPDIR/fix" PATH="$bin:$PATH"
  export IMAGE=ghcr.io/ioanalytica/k8s-borg RUNNER_TEMP="$BATS_TEST_TMPDIR" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  DIGEST="sha256:$(printf '1%.0s' {1..64})"
  printf '{"containerimage.descriptor":{"digest":"%s"}}\n' "$DIGEST" >"$RUNNER_TEMP/index-metadata.json"
  cat >"$FIX/raw.json" <<'JSON'
{"manifests":[{"platform":{"os":"linux","architecture":"amd64"}},{"platform":{"os":"unknown","architecture":"unknown"}},
              {"platform":{"os":"linux","architecture":"arm64"}},{"platform":{"os":"unknown","architecture":"unknown"}}]}
JSON
  echo '{"linux/amd64":{"SPDX":{"spdxVersion":"SPDX-2.3"}},"linux/arm64":{"SPDX":{"spdxVersion":"SPDX-2.3"}}}' >"$FIX/sbom.json"
  echo '{"linux/amd64":{"SLSA":{"buildDefinition":{}}},"linux/arm64":{"SLSA":{"buildDefinition":{}}}}' >"$FIX/provenance.json"
}

@test "the merge's check passes an index with an SBOM and provenance for every platform" {
  inspect_fixture
  run bash -e "$BATS_TEST_TMPDIR/inspect.sh"
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(cat "$GITHUB_OUTPUT")" = "digest=$DIGEST" ] || fail "output: $(cat "$GITHUB_OUTPUT")"
  # Everything it read, it read by that digest.
  ! grep -v -F "$IMAGE@$DIGEST" "$FIX/docker.log" || fail "docker was asked for something else"
}

@test "the merge's check fails an index that lost an attestation, or a create without a digest" {
  inspect_fixture
  echo '{"linux/amd64":{"SPDX":{"spdxVersion":"SPDX-2.3"}}}' >"$FIX/sbom.json"
  run bash -e "$BATS_TEST_TMPDIR/inspect.sh"
  [ "$status" -ne 0 ] && [[ "$output" == *"SBOM attestation"* ]] || fail "a missing SBOM passed: $output"
  [ ! -s "$GITHUB_OUTPUT" ] || fail "a digest was passed on"

  inspect_fixture
  echo '{}' >"$FIX/provenance.json"
  run bash -e "$BATS_TEST_TMPDIR/inspect.sh"
  [ "$status" -ne 0 ] && [[ "$output" == *"Provenance attestation"* ]] || fail "a missing provenance passed: $output"

  inspect_fixture
  echo '{}' >"$RUNNER_TEMP/index-metadata.json"
  run bash -e "$BATS_TEST_TMPDIR/inspect.sh"
  [ "$status" -ne 0 ] && [[ "$output" == *"reported no digest"* ]] || fail "no digest passed: $output"
}

# --- signatures ---------------------------------------------------------------

@test "every image and the chart are signed by the digest they were pushed under" {
  local needs j path var sign verify
  needs="$(wf_job "$BUILD_WF" sign | sed -n 's/^    needs: \[\(.*\)\]$/\1/p' | tr -d ' ' | tr ',' '\n')"
  sign="$(sign_step | grep -E '^ +cosign sign --yes ')"
  verify="$(sign_step | grep -E '^ +cosign verify ')"
  for j in $(wf_image_jobs "$BUILD_WF") chart; do
    if [ "$j" = chart ]; then
      path=charts/k8s-borg
    else
      path="$(wf_job "$BUILD_WF" "$j" | awk '$1 == "image:" { print $2 }')"
    fi
    grep -qx "$j" <<<"$needs" || fail "the sign job does not wait for $j"
    var="$(signed_var "$path" "$j")"
    [ -n "$var" ] || fail "the sign step has no ghcr.io/ioanalytica/$path at the digest of $j"
    grep -qF "\"\$$var\"" <<<"$sign"   || fail "$path (\$$var) is not signed"
    grep -qF "\"\$$var\"" <<<"$verify" || fail "$path (\$$var) is not verified after signing"
  done
  grep -qF 'digest: ${{ steps.push.outputs.digest }}' <<<"$(wf_job "$BUILD_WF" chart)" \
    || fail "the chart job does not output a digest"
}

# The chart job's push script, with a stub helm. FAKE_HELM picks what push
# reports: ok (Helm 4: "Digest:" on stdout), stderr, none, or fail.
push_chart() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin" "$BATS_TEST_TMPDIR/chart"
  touch "$BATS_TEST_TMPDIR/chart/k8s-borg-1.0.0.tgz"
  wf_run "$BUILD_WF" 'name: Push chart to GHCR (tags only)' | sed 's/\${{[^}]*}}/x/g' >"$BATS_TEST_TMPDIR/push.sh"
  [ -s "$BATS_TEST_TMPDIR/push.sh" ] || fail "no push script found"
  cat >"$bin/helm" <<'SH'
#!/usr/bin/env bash
[ "$1" = registry ] && { cat >/dev/null; exit 0; }
d="sha256:$(printf 'a%.0s' {1..64})"
case "$FAKE_HELM" in
  ok)     printf 'Pushed: %s\nDigest: %s\n' "$3" "$d" ;;
  stderr) printf 'Pushed: %s\nDigest: %s\n' "$3" "$d" >&2 ;;
  none)   printf 'Pushed: %s\n' "$3" ;;
  fail)   echo "Error: denied" >&2; exit 1 ;;
esac
SH
  chmod +x "$bin/helm"
  FAKE_HELM="$1" PATH="$bin:$PATH" REGISTRY=ghcr.io OWNER=ioanalytica \
    RUNNER_TEMP="$BATS_TEST_TMPDIR" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output" \
    bash -e "$BATS_TEST_TMPDIR/push.sh"
}

@test "the chart job passes on the digest helm push reports, and fails without one" {
  run push_chart ok
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(cat "$BATS_TEST_TMPDIR/output")" = "digest=sha256:$(printf 'a%.0s' {1..64})" ] \
    || fail "output: $(cat "$BATS_TEST_TMPDIR/output")"
  rm -f "$BATS_TEST_TMPDIR/output"
  # Should a Helm release ever print the digest elsewhere, the release fails
  # here instead of signing nothing.
  local how
  for how in stderr none fail; do
    run push_chart "$how"
    [ "$status" -ne 0 ] || fail "helm push '$how' passed: $output"
    [ ! -s "$BATS_TEST_TMPDIR/output" ] || fail "helm push '$how' passed a digest on"
  done
}

@test "the GitHub Release is published only after the signatures verified" {
  local needs
  needs="$(wf_job "$BUILD_WF" release | sed -n 's/^    needs: \[\(.*\)\]$/\1/p' | tr -d ' ' | tr ',' '\n')"
  grep -qx sign <<<"$needs" || fail "the release job does not wait for the sign job"
  run grep -n 'uses: softprops/action-gh-release@' "$BUILD_WF"
  [ "${#lines[@]}" -eq 1 ] && grep -qF 'uses: softprops/action-gh-release@' <<<"$(wf_job "$BUILD_WF" release)" \
    || fail "a release is created outside the release job: $output"
  # It attaches the chart job's own package, the bytes that were signed, not
  # one packaged again.
  ! wf_job "$BUILD_WF" release | grep -q 'helm package' || fail "the release job packages the chart itself"
  local handover days
  handover="$(wf_step "$BUILD_WF" 'name: Hand the package to the release job (tags only)')"
  grep -qF 'name: chart' <<<"$handover" && grep -qF 'name: chart' <<<"$(wf_job "$BUILD_WF" release)" \
    || fail "the chart package is not handed over"
  # A re-run of the failed sign and release jobs is possible for 30 days; the
  # package has to outlive that.
  days="$(sed -n 's/^ *retention-days: \([0-9]*\)$/\1/p' <<<"$handover")"
  [ "${days:-0}" -ge 30 ] || fail "the chart package expires after ${days:-?} days"
  run grep -n 'contents: write' "$BUILD_WF"
  [ "${#lines[@]}" -eq 1 ] && grep -q 'contents: write' <<<"$(wf_job "$BUILD_WF" release)" \
    || fail "another job can write to the repository: $output"
}

@test "nothing is signed by tag, and nothing outside build.yml's sign job" {
  local word var
  # A reusable workflow would sign under its own name, not the identity
  # README.md tells users to verify.
  run grep -n 'cosign sign' "$WF"/*.y*ml
  [ "${#lines[@]}" -eq 1 ] || fail "cosign sign appears more than once: $output"
  [[ "$output" == "$BUILD_WF:"* ]] || fail "something other than build.yml signs: $output"
  for word in $(sign_step | sed -n 's/^ *cosign sign --yes //p'); do
    var="$(sed -n 's/^"\$\([A-Z_]*\)"$/\1/p' <<<"$word")"
    [ -n "$var" ] || fail "cosign sign is given '$word', not a variable"
    # …/name@${{ needs.<job>.outputs.digest }}
    sign_step | awk -v var="$var:" '
      $1 == var && index($0, "@${{ needs.") && $(NF - 1) ~ /^needs\.[a-z-]+\.outputs\.digest$/ && $NF == "}}" { found = 1 }
      END { exit !found }' \
      || fail "\$$var is not a reference by digest: $(sign_step | grep -E "^ +$var:")"
  done
}

@test "the OIDC token goes to the signing job and the Pages deployment only" {
  # deploy-pages proves the run to GitHub Pages with the token. A certificate
  # Sigstore would issue to that job names site.yml, which the identity users
  # verify against (build.yml, for a tag) does not accept.
  local found
  found="$(awk '
    FNR == 1 { injobs = 0; wf = FILENAME; sub(/.*\//, "", wf) }
    /^jobs:/ { injobs = 1 }
    injobs && /^  [a-z][a-z0-9_-]*:$/ { j = $1; sub(/:$/, "", j) }
    $1 == "id-token:" { print wf ":" (injobs ? j : "(workflow)") ":" $2 }' "$WF"/*.y*ml)"
  [ "$found" = "$(printf '%s\n' build.yml:sign:write site.yml:deploy:write)" ] \
    || fail "id-token permissions: ${found:-none}"
}

@test "the sign job has a time limit" {
  # It waits on Sigstore's services; without a limit a hang holds the release
  # run for GitHub's six hours.
  wf_job "$BUILD_WF" sign | grep -qE '^    timeout-minutes: [0-9]+$' || fail "the sign job has no time limit"
}

@test "cosign is installed by a pinned installer, at one pinned release" {
  local installs releases
  installs="$(grep -hE '^ +- uses: sigstore/cosign-installer@' "$WF"/*.y*ml)"
  [ -n "$installs" ] || fail "no workflow installs cosign"
  ! grep -vE '@v[0-9]+\.[0-9]+\.[0-9]+$' <<<"$installs" || fail "cosign-installer not pinned to a release: $installs"
  # Without cosign-release the installer brings its own default, which moves
  # with the installer.
  releases="$(grep -hE '^ +cosign-release:' "$WF"/*.y*ml)"
  [ "$(wc -l <<<"$releases")" -eq "$(wc -l <<<"$installs")" ] \
    || fail "an installer runs without cosign-release"
  [[ "$(awk '{ print $2 }' <<<"$releases" | sort -u)" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "cosign-release is not one exact version: $releases"
}

@test "README.md verifies against the identity the release checks right after signing" {
  local signer
  signer="$(sed -n "s/^  SIGNER: '\(.*\)'\$/\1/p" "$BUILD_WF")"
  # The certificate names the workflow file the sign job is in.
  [ "$signer" = "^https://github\\.com/ioanalytica/k8s-borg/\\.github/workflows/build\\.yml@refs/tags/" ] \
    || fail "SIGNER is '$signer'"
  sign_step | grep -qF -- '--certificate-identity-regexp "$SIGNER"' || fail "the sign job verifies against another identity"
  sign_step | grep -qF -- '--certificate-oidc-issuer https://token.actions.githubusercontent.com' \
    || fail "the sign job verifies against another issuer"
  grep -qF -- "--certificate-identity-regexp '$signer'" "$REPO_ROOT/README.md" \
    || fail "README.md does not give the identity $signer"
  grep -qF -- '--certificate-oidc-issuer https://token.actions.githubusercontent.com' "$REPO_ROOT/README.md" \
    || fail "README.md does not give the GitHub Actions issuer"
}
