#!/usr/bin/env bats
#
# The SBOM, the provenance and the Sigstore signatures of a release, and the
# order that keeps every tag on a signed digest: pushed by digest, signed,
# then tagged. Nothing else would notice an edit that drops one of them: the
# release still builds, pushes and goes green, only without what users verify
# it by, or with a version tag that names an unsigned artifact for a while.
# Like the build.yml checks in chart-versions.bats, these read the workflow
# files.

setup() {
  load helpers/versions
  load helpers/workflows
  WF="$REPO_ROOT/.github/workflows"
  BUILD_IMAGE="$WF/build-image.yml"
}

sign_step() { wf_step "$BUILD_WF" 'name: Sign by digest'; }

# digest_var PATH JOB [STEP] — the variable of STEP (the sign step by
# default) that holds ghcr.io/ioanalytica/PATH at the digest JOB outputs.
digest_var() {
  wf_step "$BUILD_WF" "${3:-name: Sign by digest}" | awk -v want="/$1@\${{ needs.$2.outputs.digest }}" '
    $1 ~ /^[A-Z_]+:$/ && substr($0, length($0) - length(want) + 1) == want { sub(/:$/, "", $1); print $1 }'
}
signed_var() { digest_var "$1" "$2"; }

# needs_of JOB — the jobs JOB of build.yml waits for, one a line.
needs_of() {
  wf_job "$BUILD_WF" "$1" | awk '
    $1 == "needs:" { $1 = ""; gsub(/[][ ]/, ""); n = split($0, a, ","); for (i = 1; i <= n; i++) print a[i] }'
}

# image_path JOB — the image under ghcr.io/ioanalytica/ a job of build.yml
# builds, or the chart's repository for the chart job.
image_path() {
  if [ "$1" = chart ]; then echo charts/k8s-borg; else wf_job "$BUILD_WF" "$1" | awk '$1 == "image:" { print $2 }'; fi
}

@test "the extractors find what the checks below read" {
  [ -n "$(wf_step "$BUILD_IMAGE" 'id: build')" ]     || fail "no build step in build-image.yml"
  [ -n "$(wf_job "$BUILD_IMAGE" merge)" ]            || fail "no merge job in build-image.yml"
  [ -n "$(wf_job "$BUILD_WF" sign)" ]                || fail "no sign job in build.yml"
  [ -n "$(sign_step)" ]                           || fail "no 'Sign by digest' step in build.yml"
  [ -n "$(wf_job "$BUILD_WF" tag)" ]                 || fail "no tag job in build.yml"
  [ "$(needs_of release | tr '\n' ' ')" = "chart sign tag " ] || fail "needs_of release: $(needs_of release | tr '\n' ' ')"
  [ "$(needs_of try-locally)" = tag ]               || fail "needs_of try-locally: $(needs_of try-locally)"
  [ "$(image_path server)" = k8s-borg-ui ]          || fail "image_path server: $(image_path server)"
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

@test "the merge passes on the digest of the index it pushed and its tags, not a digest read back by tag" {
  local m
  m="$(wf_job "$BUILD_IMAGE" merge)"
  ! grep -qE 'inspect "\$IMAGE:|steps\.meta\.outputs\.version' <<<"$(wf_step "$BUILD_IMAGE" 'name: Inspect')" \
    || fail "the Inspect step resolves a tag again"
  grep -qF 'digest: ${{ steps.index.outputs.digest }}' <<<"$m" || fail "the merge job does not pass the digest on"
  grep -qF 'tags: ${{ steps.meta.outputs.tags }}' <<<"$m"     || fail "the merge job does not pass the tags on"
  grep -qF 'value: ${{ jobs.merge.outputs.digest }}' "$BUILD_IMAGE" \
    || fail "build-image.yml does not output the digest of the merged index"
  grep -qF 'value: ${{ jobs.merge.outputs.tags }}' "$BUILD_IMAGE" \
    || fail "build-image.yml does not output the tags of the merged index"
}

# The merge job's push script in a directory of two platform digests, with a
# stub docker that prints an index for --dry-run (or fails, FAKE_DOCKER=fail)
# and a stub oras that keeps the file it is asked to push.
merge_push() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin" "$BATS_TEST_TMPDIR/digests" "$BATS_TEST_TMPDIR/fix"
  wf_run "$BUILD_IMAGE" 'name: Create manifest list & push by digest' >"$BATS_TEST_TMPDIR/push.sh"
  [ -s "$BATS_TEST_TMPDIR/push.sh" ] || fail "no push script found in the merge job"
  touch "$BATS_TEST_TMPDIR/digests/$(printf 'b%.0s' {1..64})" "$BATS_TEST_TMPDIR/digests/$(printf 'c%.0s' {1..64})"
  cat >"$bin/docker" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$FIX/docker.log"
[ "$FAKE_DOCKER" = fail ] && { echo "ERROR: manifest unknown" >&2; exit 1; }
printf '{\n  "mediaType": "application/vnd.oci.image.index.v1+json"\n}\n'
SH
  cat >"$bin/oras" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$FIX/oras.log"
[ "$1 $2" = "manifest push" ] && cp "$4" "$FIX/pushed.json"
exit 0
SH
  chmod +x "$bin/docker" "$bin/oras"
  (cd "$BATS_TEST_TMPDIR/digests" &&
    FAKE_DOCKER="$1" FIX="$BATS_TEST_TMPDIR/fix" PATH="$bin:$PATH" IMAGE=ghcr.io/ioanalytica/k8s-borg \
      BUILD_RUN=41 RUNNER_TEMP="$BATS_TEST_TMPDIR" bash -e "$BATS_TEST_TMPDIR/push.sh")
}

@test "the merge pushes the index imagetools prints, by its digest and under no tag" {
  local fix="$BATS_TEST_TMPDIR/fix" b c
  b="$(printf 'b%.0s' {1..64})"
  c="$(printf 'c%.0s' {1..64})"
  run merge_push ok
  [ "$status" -eq 0 ] || fail "$output"
  # imagetools create pushes under a tag unless it only prints (--dry-run).
  # The index carries the number of its run, which the tag job compares.
  [ "$(cat "$fix/docker.log")" = "buildx imagetools create --dry-run --annotation index:com.ioanalytica.k8s-borg.build-run=41 ghcr.io/ioanalytica/k8s-borg@sha256:$b ghcr.io/ioanalytica/k8s-borg@sha256:$c" ] \
    || fail "docker was asked: $(cat "$fix/docker.log")"
  grep -qxF '          BUILD_RUN: ${{ github.run_number }}' <<<"$(wf_step "$BUILD_IMAGE" 'name: Create manifest list & push by digest')" \
    || fail "the index does not get the run's number"
  # A reference without a tag: oras pushes the manifest by its digest.
  [ "$(cat "$fix/oras.log")" = "manifest push ghcr.io/ioanalytica/k8s-borg $BATS_TEST_TMPDIR/index.json" ] \
    || fail "oras was asked: $(cat "$fix/oras.log")"
  # The bytes pushed are the index, without the newline the print adds.
  printf '{\n  "mediaType": "application/vnd.oci.image.index.v1+json"\n}' >"$BATS_TEST_TMPDIR/want.json"
  cmp "$BATS_TEST_TMPDIR/want.json" "$fix/pushed.json" || fail "pushed: $(od -c "$fix/pushed.json" | tail -3)"

  rm -f "$fix"/*.log "$fix/pushed.json"
  run merge_push fail
  [ "$status" -ne 0 ] || fail "a failed imagetools create passed: $output"
  [ ! -e "$fix/oras.log" ] || fail "oras pushed after imagetools failed: $(cat "$fix/oras.log")"
}

# The merge job's Inspect script, run against a stub docker that serves an
# index of two platforms and the SBOM and provenance documents of each. The
# index pushed is "{}", whose digest DIGEST is.
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
  DIGEST=sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a
  printf '{}' >"$RUNNER_TEMP/index.json"
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

@test "the merge's check fails an index that lost an attestation, or a merge that pushed none" {
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
  rm "$RUNNER_TEMP/index.json"
  run bash -e "$BATS_TEST_TMPDIR/inspect.sh"
  [ "$status" -ne 0 ] && [[ "$output" == *"no index was pushed"* ]] || fail "no index passed: $output"
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

# The chart job's push script, with a stub curl (the job's registry is up), a
# stub helm and a stub oras. FAKE_HELM picks what push reports: ok (Helm 4:
# "Digest:" on stdout), stderr, none, or fail; FAKE_ORAS=fail fails the copy.
push_chart() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin" "$BATS_TEST_TMPDIR/chart"
  touch "$BATS_TEST_TMPDIR/chart/k8s-borg-1.0.0.tgz"
  wf_run "$BUILD_WF" 'name: Push chart to GHCR by digest (tags only)' | sed 's/\${{[^}]*}}/x/g' >"$BATS_TEST_TMPDIR/push.sh"
  [ -s "$BATS_TEST_TMPDIR/push.sh" ] || fail "no push script found"
  printf '#!/bin/sh\necho "$*" >>"$BATS_TEST_TMPDIR/curl.log"\n' >"$bin/curl"
  cat >"$bin/helm" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$BATS_TEST_TMPDIR/helm.log"
d="sha256:$(printf 'a%.0s' {1..64})"
case "$FAKE_HELM" in
  ok)     printf 'Pushed: %s\nDigest: %s\n' "$3" "$d" ;;
  stderr) printf 'Pushed: %s\nDigest: %s\n' "$3" "$d" >&2 ;;
  none)   printf 'Pushed: %s\n' "$3" ;;
  fail)   echo "Error: denied" >&2; exit 1 ;;
esac
SH
  cat >"$bin/oras" <<'SH'
#!/usr/bin/env bash
[ "$1" = login ] && { cat >/dev/null; exit 0; }
echo "$*" >>"$BATS_TEST_TMPDIR/oras.log"
[ "$FAKE_ORAS" != fail ]
SH
  chmod +x "$bin/curl" "$bin/helm" "$bin/oras"
  FAKE_HELM="$1" FAKE_ORAS="${2:-ok}" PATH="$bin:$PATH" REGISTRY=ghcr.io OWNER=ioanalytica TOKEN=t ACTOR=a \
    RUNNER_TEMP="$BATS_TEST_TMPDIR" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output" \
    bash -e "$BATS_TEST_TMPDIR/push.sh"
}

@test "the chart goes up through the job's own registry, into GHCR by digest under no tag" {
  local d="sha256:$(printf 'a%.0s' {1..64})"
  run push_chart ok
  [ "$status" -eq 0 ] || fail "$output"
  # It waits for the registry to answer.
  grep -qF 'http://localhost:5000/v2/' "$BATS_TEST_TMPDIR/curl.log" || fail "curl was asked: $(cat "$BATS_TEST_TMPDIR/curl.log")"
  # helm push tags the version as it pushes, so it pushes there.
  [ "$(cat "$BATS_TEST_TMPDIR/helm.log")" = "push $BATS_TEST_TMPDIR/chart/k8s-borg-1.0.0.tgz oci://localhost:5000/charts --plain-http" ] \
    || fail "helm was asked: $(cat "$BATS_TEST_TMPDIR/helm.log")"
  # oras copies that digest, and gives the copy no tag.
  [ "$(cat "$BATS_TEST_TMPDIR/oras.log")" = "cp --from-plain-http localhost:5000/charts/k8s-borg@$d ghcr.io/ioanalytica/charts/k8s-borg" ] \
    || fail "oras was asked: $(cat "$BATS_TEST_TMPDIR/oras.log")"
  [ "$(cat "$BATS_TEST_TMPDIR/output")" = "digest=$d" ] || fail "output: $(cat "$BATS_TEST_TMPDIR/output")"
}

@test "the chart job's registry is the one helm pushes to, pinned by version and digest" {
  local job
  job="$(wf_job "$BUILD_WF" chart)"
  grep -qE '^        image: registry:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$' <<<"$job" \
    || fail "the registry image: $(grep -F 'image:' <<<"$job")"
  grep -qxF '          - 5000:5000' <<<"$job" || fail "the registry is not on port 5000: $job"
  # Nothing else in the release names a registry image.
  run grep -nE '^ +image: registry:' "$WF"/*.y*ml
  [ "${#lines[@]}" -eq 1 ] || fail "$output"
}

@test "the chart job passes on the digest helm push reports, and fails without one or without the copy" {
  # Should a Helm release ever print the digest elsewhere, the release fails
  # here instead of signing nothing.
  local how
  for how in stderr none fail; do
    rm -f "$BATS_TEST_TMPDIR/output" "$BATS_TEST_TMPDIR/oras.log"
    run push_chart "$how"
    [ "$status" -ne 0 ] || fail "helm push '$how' passed: $output"
    [ ! -s "$BATS_TEST_TMPDIR/output" ] || fail "helm push '$how' passed a digest on"
    [ ! -e "$BATS_TEST_TMPDIR/oras.log" ] || fail "helm push '$how' was copied: $(cat "$BATS_TEST_TMPDIR/oras.log")"
  done
  rm -f "$BATS_TEST_TMPDIR/output"
  run push_chart ok fail
  [ "$status" -ne 0 ] || fail "a failed copy passed: $output"
  [ ! -s "$BATS_TEST_TMPDIR/output" ] || fail "a failed copy passed a digest on"
}

@test "the chart job waits for the gate and the image builds, and its re-run replaces the package" {
  # A failed image build leaves no chart behind, not even under its digest.
  local needs j
  needs="$(needs_of chart)"
  [ -n "$(wf_image_jobs "$BUILD_WF")" ] || fail "no image jobs found"
  for j in gate $(wf_image_jobs "$BUILD_WF"); do
    grep -qx "$j" <<<"$needs" || fail "the chart job does not wait for $j"
  done
  # A re-run after a failed push uploads the package again under the same
  # name: without overwrite the upload fails on the failed attempt's artifact.
  grep -qx '          overwrite: true' <<<"$(wf_step "$BUILD_WF" 'name: Hand the package to the release job (tags only)')" \
    || fail "a re-run of the chart job cannot replace the package of a failed attempt"
}

@test "the GitHub Release is published only after the signatures verified and the tags are set" {
  local needs
  needs="$(needs_of release)"
  grep -qx sign <<<"$needs" || fail "the release job does not wait for the sign job"
  grep -qx tag <<<"$needs"  || fail "the release job does not wait for the tag job"
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

# --- tags -------------------------------------------------------------------

# where_oras CMD — FILE:JOB of every line of the workflows and the local
# actions that runs `oras CMD`, one a line.
where_oras() {
  awk -v cmd="$1" '
    FNR == 1 { j = "(none)"; wf = FILENAME; sub(/.*\/\.github\//, "", wf) }
    /^  [a-z][a-z0-9_-]*:$/ { j = $1; sub(/:$/, "", j) }
    $0 ~ "(^|[ \"$])oras " cmd " " && $1 != "#" { print wf ":" j }' \
    "$WF"/*.y*ml "$REPO_ROOT"/.github/actions/*/action.y*ml | sort -u
}

@test "nothing of a release gets a tag before the sign job" {
  local line
  # The platform images go up by digest, the index imagetools only prints.
  grep -qxF '          outputs: type=image,push-by-digest=true,name-canonical=true,push=true' \
    <<<"$(wf_step "$BUILD_IMAGE" 'id: build')" || fail "the platform images are no longer pushed by digest"
  run grep -h 'imagetools create' "$WF"/*.y*ml
  [ "$(grep -vc '^ *#' <<<"$output")" -gt 0 ] || fail "imagetools create not found"
  while IFS= read -r line; do
    [[ "$line" == *"imagetools create --dry-run "* ]] || fail "imagetools create pushes: $line"
    ! grep -qE -- ' (-t|--tag)[ =]' <<<"$line" || fail "imagetools create is given a tag: $line"
  done < <(grep -v '^ *#' <<<"$output")
  # helm push tags as it pushes: into the chart job's own registry alone.
  run grep -hE '(^ *|\$\()helm push ' "$WF"/*.y*ml
  [ "${#lines[@]}" -eq 1 ] && [[ "$output" == *' oci://localhost:5000/charts --plain-http)"' ]] \
    || fail "helm push: $output"
  # oras sets tags in the tag job alone; it pushes by digest elsewhere.
  [ "$(where_oras tag)" = workflows/build.yml:tag ] || fail "oras tag runs in: $(where_oras tag | tr '\n' ' ')"
  [ "$(where_oras push)" = workflows/build.yml:tag ] || fail "oras push runs in: $(where_oras push | tr '\n' ' ')"
  [ "$(where_oras 'manifest push')" = workflows/build-image.yml:merge ] \
    || fail "oras manifest push runs in: $(where_oras 'manifest push' | tr '\n' ' ')"
  [ "$(where_oras cp)" = workflows/build.yml:chart ] || fail "oras cp runs in: $(where_oras cp | tr '\n' ' ')"
}

@test "the tag job tags each signed digest, after the sign job and before what reads tags" {
  local needs j path var tags
  needs="$(needs_of tag)"
  for j in sign chart $(wf_image_jobs "$BUILD_WF"); do
    grep -qx "$j" <<<"$needs" || fail "the tag job does not wait for $j"
  done
  grep -qx "    if: startsWith(github.ref, 'refs/tags/')" <<<"$(wf_job "$BUILD_WF" tag)" || fail "the tag job is not guarded to tags"
  wf_job "$BUILD_WF" tag | grep -qE '^    timeout-minutes: [0-9]+$' || fail "the tag job has no time limit"
  [ "$(wf_job "$BUILD_WF" tag | grep -E '^      [a-z-]+: (read|write)( |$)' | awk '{ print $1 $2 }' | tr '\n' ' ')" = "contents:read packages:write " ] \
    || fail "the tag job's permissions: $(wf_job "$BUILD_WF" tag | grep -E '^      [a-z-]+: (read|write)')"
  # The digest each image job built and the sign job signed, with the tags
  # that job computed.
  for j in $(wf_image_jobs "$BUILD_WF"); do
    path="$(image_path "$j")"
    var="$(digest_var "$path" "$j" 'name: Tag the images')"
    [ -n "$var" ] || fail "the tag step has no ghcr.io/ioanalytica/$path at the digest of $j"
    [ "$var" = "$(signed_var "$path" "$j")" ] || fail "\$$var is not the variable the sign step signs"
    tags="$(wf_step "$BUILD_WF" 'name: Tag the images' | awk -v v="${var}_TAGS:" '$1 == v { print $2, $3, $4 }')"
    [ "$tags" = "\${{ needs.$j.outputs.tags }}" ] || fail "\$${var}_TAGS is '$tags'"
    grep -qxF "          move_tags \"\$$var\" \$$(tr '[:upper:]' '[:lower:]' <<<"$var")" <<<"$(wf_step "$BUILD_WF" 'name: Tag the images')" \
      || fail "\$$var is not tagged"
  done
  [ "$(digest_var charts/k8s-borg chart 'name: Tag the chart')" = CHART ] || fail "the chart is not tagged at its digest"
  grep -qxF '        run: oras tag "$CHART" "$GITHUB_REF_NAME"' <<<"$(wf_step "$BUILD_WF" 'name: Tag the chart')" \
    || fail "the chart is not tagged with its version"
  # The chart names its images by tag, so its version comes last.
  [ "$(wf_job "$BUILD_WF" tag | grep '^      - ' | tail -1)" = "      - name: Tag the chart" ] \
    || fail "the tag job's last step: $(wf_job "$BUILD_WF" tag | grep '^      - ' | tail -1)"
}

@test "the server builds on the runtime base by the digest its job pushed" {
  # By tag it would get the base of an earlier release, whose tag the new
  # base takes only in the tag job, after the server is built and signed.
  local job
  job="$(wf_job "$BUILD_WF" server)"
  grep -qx '        BASE_IMAGE=ghcr.io/ioanalytica/k8s-borg-ui-runtime-base@${{ needs.runtime-base.outputs.digest }}' <<<"$job" \
    || fail "the server's base: $(grep -F BASE_IMAGE= <<<"$job")"
  grep -qx runtime-base <<<"$(needs_of server)" || fail "the server job does not wait for the runtime base"
}

# The tag job's image script, with a stub oras: it logs the tags it is asked
# to set (FIX/oras.log), resolves the tags tag_exists made (any other: "not
# found", or FAKE_RESOLVE's error), and gives an index the run tag_fixture or
# tag_exists recorded for its digest (FAKE_FETCH=fail: an error). REF is the
# version the run is for.
tag_images() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  wf_run "$BUILD_WF" 'name: Tag the images' >"$BATS_TEST_TMPDIR/tag.sh"
  [ -s "$BATS_TEST_TMPDIR/tag.sh" ] || fail "no tag script found"
  cat >"$bin/oras" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "tag "*) echo "$*" >>"$FIX/oras.log" ;;
  "resolve "*)
    [ -z "${FAKE_RESOLVE-}" ] || { echo "Error: $FAKE_RESOLVE" >&2; exit 1; }
    f="$FIX/tags/${2//\//_}"; [ -f "$f" ] || { echo "Error: failed to resolve digest: $2: not found" >&2; exit 1; }; cat "$f" ;;
  "manifest fetch")
    [ "${FAKE_FETCH-}" != fail ] || [ -f "$FIX/run/${3#*@}.ours" ] || { echo "Error: 502 Bad Gateway" >&2; exit 1; }
    d="$FIX/run/${3#*@}"
    if [ -f "$d" ]; then printf '{"annotations":{"com.ioanalytica.k8s-borg.build-run":"%s"}}\n' "$(cat "$d")"; else echo '{}'; fi ;;
  *) echo "unexpected: oras $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$bin/oras"
  export FIX AGENT AGENT_TAGS RUNTIME_BASE RUNTIME_BASE_TAGS SERVER SERVER_TAGS
  # GitHub runs a step without a shell: of its own with bash -e, no pipefail.
  GITHUB_REF_NAME="$1" PATH="$bin:$PATH" RUNNER_TEMP="$FIX" bash -e "$BATS_TEST_TMPDIR/tag.sh"
}

# tag_exists IMAGE:TAG DIGEST [RUN] — the registry has TAG on DIGEST, an
# index of the run RUN (none: from before runs were recorded).
tag_exists() {
  echo "$2" >"$FIX/tags/${1//\//_}"
  [ -z "${3-}" ] || echo "$3" >"$FIX/run/${2#*@}"
}

tag_fixture() {
  local g=ghcr.io/ioanalytica d
  FIX="$(mktemp -d "$BATS_TEST_TMPDIR/fix.XXXXXX")"
  mkdir -p "$FIX/tags" "$FIX/run"
  AGENT="$g/k8s-borg@sha256:$(printf '1%.0s' {1..64})"
  AGENT_TAGS="$(printf '%s\n' "$g/k8s-borg:1.3.3" "$g/k8s-borg:sha-abc1234" "$g/k8s-borg:latest")"
  RUNTIME_BASE="$g/k8s-borg-ui-runtime-base@sha256:$(printf '2%.0s' {1..64})"
  RUNTIME_BASE_TAGS="$(printf '%s\n' "$g/k8s-borg-ui-runtime-base:runtime-x-r1" "$g/k8s-borg-ui-runtime-base:latest" '')"
  SERVER="$g/k8s-borg-ui@sha256:$(printf '3%.0s' {1..64})"
  SERVER_TAGS="$(printf '%s\n' "$g/k8s-borg-ui:2.4.6" "$g/k8s-borg-ui:latest")"
  # This is run 50.
  for d in "$AGENT" "$RUNTIME_BASE" "$SERVER"; do echo 50 >"$FIX/run/${d#*@}"; touch "$FIX/run/${d#*@}.ours"; done
}

@test "the tag job sets each image's tags on its digest, the agent first" {
  tag_fixture
  run tag_images 1.3.3
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(cat "$FIX/oras.log")" = "$(printf '%s\n' \
    "tag $AGENT 1.3.3 sha-abc1234 latest" \
    "tag $RUNTIME_BASE runtime-x-r1 latest" \
    "tag $SERVER 2.4.6 latest")" ] || fail "oras was asked: $(cat "$FIX/oras.log")"
}

@test "the tag job moves a tag only to the images of a later run" {
  # A late re-run of an older release's failed jobs: a newer release holds
  # latest and the shared tags, which stay; an earlier run, or an index from
  # before runs were recorded, gives them up. Run 100 is after run 50, which
  # a comparison of strings would not say.
  local g=ghcr.io/ioanalytica newer older plain
  newer="sha256:$(printf '4%.0s' {1..64})"
  older="sha256:$(printf '5%.0s' {1..64})"
  plain="sha256:$(printf '6%.0s' {1..64})"
  tag_fixture
  tag_exists "$g/k8s-borg-ui:2.4.6" "$newer" 100
  tag_exists "$g/k8s-borg-ui:latest" "$newer"
  tag_exists "$g/k8s-borg:latest" "$older" 49
  tag_exists "$g/k8s-borg-ui-runtime-base:latest" "$plain"
  # A re-run finds its own tag where it put it.
  tag_exists "$g/k8s-borg:1.3.3" "${AGENT#*@}"
  run tag_images 1.3.3
  [ "$status" -eq 0 ] || fail "$output"
  [ "$(cat "$FIX/oras.log")" = "$(printf '%s\n' \
    "tag $AGENT 1.3.3 sha-abc1234 latest" \
    "tag $RUNTIME_BASE runtime-x-r1 latest")" ] || fail "oras was asked: $(cat "$FIX/oras.log")"
  [[ "$output" == *"◆ $g/k8s-borg-ui:2.4.6 stays on $newer, from the later run 100"* ]] || fail "$output"
  [[ "$output" == *"◆ $g/k8s-borg-ui:latest stays on $newer, from the later run 100"* ]] || fail "$output"
}

@test "the tag job stops when the registry does not say which run a tag names" {
  # Only "not found" lets a tag move without knowing its current run.
  tag_fixture
  FAKE_RESOLVE="failed to resolve digest: ghcr.io/ioanalytica/k8s-borg:1.3.3: 502 Bad Gateway" run tag_images 1.3.3
  [ "$status" -ne 0 ] && [[ "$output" == *"502 Bad Gateway"* ]] || fail "a resolve error passed: $output"
  [ ! -e "$FIX/oras.log" ] || fail "tags were set: $(cat "$FIX/oras.log")"

  tag_fixture
  tag_exists ghcr.io/ioanalytica/k8s-borg:latest "sha256:$(printf '4%.0s' {1..64})" 100
  FAKE_FETCH=fail run tag_images 1.3.3
  [ "$status" -ne 0 ] && [[ "$output" == *"502 Bad Gateway"* ]] || fail "a fetch error passed: $output"
  [ ! -e "$FIX/oras.log" ] || fail "tags were set: $(cat "$FIX/oras.log")"
}

@test "the tag job sets no tag for an index of the run that names no run" {
  tag_fixture
  rm "$FIX/run/${SERVER#*@}"
  run tag_images 1.3.3
  [ "$status" -ne 0 ] && [[ "$output" == *"✗ $SERVER names no run"* ]] || fail "$output"
  [ ! -e "$FIX/oras.log" ] || fail "tags were set: $(cat "$FIX/oras.log")"
}

@test "one tag job runs at a time, across runs, and none is cancelled for another" {
  local job
  job="$(wf_job "$BUILD_WF" tag)"
  [ "$(awk '$1 == "concurrency:" { on = 1; next } on && /^      [a-z-]+:/ { print $1 $2; next } on { exit }' <<<"$job" | tr '\n' ' ')" \
    = "group:build-tag cancel-in-progress:false " ] || fail "the tag job's concurrency: $(grep -A2 'concurrency:' <<<"$job")"
  run grep -n 'group: build-tag' "$WF"/*.y*ml
  [ "${#lines[@]}" -eq 1 ] || fail "another job shares the group: $output"
}

@test "the tag job sets no tag when a list has another image's tag, or none" {
  tag_fixture
  SERVER_TAGS="$(printf '%s\n' ghcr.io/ioanalytica/k8s-borg-ui:2.4.6 ghcr.io/ioanalytica/k8s-borg:2.4.6)"
  run tag_images 1.3.3
  [ "$status" -ne 0 ] && [[ "$output" == *"ghcr.io/ioanalytica/k8s-borg:2.4.6 is not a tag of ghcr.io/ioanalytica/k8s-borg-ui"* ]] \
    || fail "a foreign tag passed: $output"
  [ ! -e "$FIX/oras.log" ] || fail "tags were set: $(cat "$FIX/oras.log")"

  tag_fixture
  SERVER_TAGS=""
  run tag_images 1.3.3
  [ "$status" -ne 0 ] && [[ "$output" == *"no tags for ghcr.io/ioanalytica/k8s-borg-ui"* ]] || fail "no tags passed: $output"
  [ ! -e "$FIX/oras.log" ] || fail "tags were set: $(cat "$FIX/oras.log")"
}

@test "oras comes from the repository's action, checked against its release's sums" {
  local action="$REPO_ROOT/.github/actions/setup-oras/action.yml" cmd entry job first_oras setup
  grep -qF 'sha256sum -c -' "$action" || fail "the action does not check oras against its release's sums"
  grep -qE '^ +# renovate: datasource=github-releases depName=oras-project/oras$' "$action" \
    || fail "the action's oras version has no # renovate: line"
  run grep -ln 'oras-project/oras/releases' "$WF"/*.y*ml
  [ "$status" -ne 0 ] || fail "a workflow downloads oras itself: $output"
  # Every job that runs oras installs it with the action first.
  for cmd in tag push 'manifest push' cp login; do where_oras "$cmd"; done | sort -u >"$BATS_TEST_TMPDIR/jobs"
  [ -s "$BATS_TEST_TMPDIR/jobs" ] || fail "no job runs oras"
  while IFS= read -r entry; do
    job="$(wf_job "$REPO_ROOT/.github/${entry%%:*}" "${entry#*:}")"
    first_oras="$(grep -nE '(^|[ "$])oras (tag|push|manifest|cp|login) ' <<<"$job" | grep -v '^[0-9]*: *#' | head -1 | cut -d: -f1)"
    setup="$(grep -nxE ' +- uses: \./\.github/actions/setup-oras' <<<"$job" | head -1 | cut -d: -f1)"
    [ -n "$setup" ] && [ "$setup" -lt "$first_oras" ] || fail "$entry runs oras without installing it first"
  done <"$BATS_TEST_TMPDIR/jobs"
}

@test "cosign is installed by a pinned installer, at one pinned release" {
  local installs releases
  installs="$(grep -hE '^ +- uses: sigstore/cosign-installer@' "$WF"/*.y*ml)"
  [ -n "$installs" ] || fail "no workflow installs cosign"
  ! grep -vE '@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$' <<<"$installs" || fail "cosign-installer not pinned to a release: $installs"
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
