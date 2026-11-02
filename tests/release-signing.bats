#!/usr/bin/env bats
#
# The SBOM, the provenance and the Sigstore signatures of a release. Nothing
# else would notice an edit that drops one of them: the release still builds,
# pushes and goes green, only without what users verify it by. Like the
# build.yml checks in chart-versions.bats, these read the workflow files.

setup() {
  load helpers/versions
  WF="$REPO_ROOT/.github/workflows"
  BUILD_IMAGE="$WF/build-image.yml"
}

# job FILE NAME — the lines of one job, up to the next one.
job() {
  awk -v head="  $2:" '
    on && match($0, /[^ ]/) && RSTART <= 3 { exit }
    on
    $0 == head { on = 1 }' "$1"
}

# step FILE HEAD — the lines of the step whose first line is "- HEAD".
step() {
  awk -v head="- $2" '
    on && match($0, /[^ ]/) && RSTART <= col { exit }
    on
    !on { line = $0; sub(/^ */, "", line); if (line == head) { on = 1; col = index($0, "-") } }' "$1"
}

# The jobs of build.yml that build an image with build-image.yml.
image_jobs() {
  awk '/^  [a-z][a-z0-9-]*:$/ { j = $1; sub(/:$/, "", j) }
       $1 == "uses:" && $2 == "./.github/workflows/build-image.yml" { print j }' "$BUILD_WF"
}

sign_step() { step "$BUILD_WF" 'name: Sign by digest'; }

# signed_var PATH JOB — the variable of the sign step that holds
# ghcr.io/ioanalytica/PATH at the digest JOB outputs.
signed_var() {
  sign_step | awk -v want="/$1@\${{ needs.$2.outputs.digest }}" '
    $1 ~ /^[A-Z_]+:$/ && substr($0, length($0) - length(want) + 1) == want { sub(/:$/, "", $1); print $1 }'
}

@test "the extractors find what the checks below read" {
  [ -n "$(step "$BUILD_IMAGE" 'id: build')" ]     || fail "no build step in build-image.yml"
  [ -n "$(job "$BUILD_IMAGE" merge)" ]            || fail "no merge job in build-image.yml"
  [ -n "$(job "$BUILD_WF" sign)" ]                || fail "no sign job in build.yml"
  [ -n "$(sign_step)" ]                           || fail "no 'Sign by digest' step in build.yml"
  [ "$(image_jobs | tr '\n' ' ')" = "agent runtime-base server " ] \
    || fail "image jobs: $(image_jobs | tr '\n' ' ')"
  [ "$(signed_var k8s-borg agent)" = AGENT ]      || fail "signed_var does not find the agent image"
  # A step ends where the next one starts, a job where the next one starts.
  [ "$(step "$BUILD_IMAGE" 'id: build' | grep -c 'uses:')" = 1 ] || fail "the build step ran into the next step"
  [ "$(job "$BUILD_IMAGE" build | grep -c 'runs-on:')" = 1 ]     || fail "the build job ran into the next job"
}

# --- SBOM and provenance ------------------------------------------------------

@test "every platform image gets an SBOM and max-mode SLSA v1 provenance" {
  local s
  s="$(step "$BUILD_IMAGE" 'id: build')"
  grep -q 'uses: docker/build-push-action@' <<<"$s" || fail "the build step no longer runs build-push-action"
  grep -Eq '^ +sbom: true$' <<<"$s" || fail "the image build no longer attaches an SBOM"
  # Left out, the mode follows the repository's visibility (max for public,
  # min for private) and the predicate follows BuildKit's default.
  grep -Eq '^ +provenance: mode=max,version=v1$' <<<"$s" \
    || fail "the image build no longer states max-mode SLSA v1 provenance"
}

@test "no secret goes into a build argument, which max-mode provenance publishes" {
  local s j
  s="$(step "$BUILD_IMAGE" 'id: build')"
  [ "$(grep -E '^ +build-args:' <<<"$s")" = '          build-args: ${{ inputs.build-args }}' ] \
    || fail "build-image.yml adds build arguments of its own: $(grep -E '^ +build-args:' <<<"$s")"
  ! grep -q 'secrets' <<<"$s" || fail "the build step references a secret: $(grep 'secrets' <<<"$s")"
  for j in $(image_jobs); do
    ! job "$BUILD_WF" "$j" | grep -q 'secrets' \
      || fail "build.yml job $j hands build-image.yml a secret: $(job "$BUILD_WF" "$j" | grep 'secrets')"
  done
}

@test "the merge fails unless every platform kept its SBOM and provenance" {
  local m
  m="$(job "$BUILD_IMAGE" merge)"
  grep -qF 'for att in SBOM:SPDX Provenance:SLSA; do' <<<"$m" \
    || fail "the merge job no longer checks the attestations of the index"
  grep -qF '| jq -e --argjson n "$platforms"' <<<"$m" || fail "the check no longer counts the platforms"
  grep -qF 'echo "digest=$digest" >> "$GITHUB_OUTPUT"' <<<"$m" || fail "the merge job no longer outputs the digest"
  grep -qF 'digest: ${{ steps.index.outputs.digest }}' <<<"$m" || fail "the merge job does not pass the digest on"
  grep -qF 'value: ${{ jobs.merge.outputs.digest }}' "$BUILD_IMAGE" \
    || fail "build-image.yml does not output the digest of the merged index"
}

# --- signatures ---------------------------------------------------------------

@test "every image and the chart are signed by the digest they were pushed under" {
  local needs j path var sign verify
  needs="$(job "$BUILD_WF" sign | sed -n 's/^    needs: \[\(.*\)\]$/\1/p' | tr -d ' ' | tr ',' '\n')"
  sign="$(sign_step | grep -E '^ +cosign sign --yes ')"
  verify="$(sign_step | grep -E '^ +cosign verify ')"
  for j in $(image_jobs) chart; do
    if [ "$j" = chart ]; then
      path=charts/k8s-borg
    else
      path="$(job "$BUILD_WF" "$j" | awk '$1 == "image:" { print $2 }')"
    fi
    grep -qx "$j" <<<"$needs" || fail "the sign job does not wait for $j"
    var="$(signed_var "$path" "$j")"
    [ -n "$var" ] || fail "the sign step has no ghcr.io/ioanalytica/$path at the digest of $j"
    grep -qF "\"\$$var\"" <<<"$sign"   || fail "$path (\$$var) is not signed"
    grep -qF "\"\$$var\"" <<<"$verify" || fail "$path (\$$var) is not verified after signing"
  done
  local chart
  chart="$(job "$BUILD_WF" chart)"
  grep -qF 'digest: ${{ steps.push.outputs.digest }}' <<<"$chart" || fail "the chart job does not output a digest"
  grep -qF 'out="$(helm push ' <<<"$chart" && grep -qF "sed -n 's/^Digest: " <<<"$chart" \
    || fail "the chart's digest no longer comes from what helm push reported"
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

@test "the OIDC token goes to the signing job only" {
  local found
  found="$(awk '
    FNR == 1 { injobs = 0; wf = FILENAME; sub(/.*\//, "", wf) }
    /^jobs:/ { injobs = 1 }
    injobs && /^  [a-z][a-z0-9_-]*:$/ { j = $1; sub(/:$/, "", j) }
    $1 == "id-token:" { print wf ":" (injobs ? j : "(workflow)") ":" $2 }' "$WF"/*.y*ml)"
  [ "$found" = "build.yml:sign:write" ] || fail "id-token permissions: ${found:-none}"
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
