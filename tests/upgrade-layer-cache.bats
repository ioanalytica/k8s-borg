#!/usr/bin/env bats
#
# A release build runs the package upgrade of each image anew. The agent
# image's `apk upgrade` (docker/Dockerfile) and the `apt-get upgrade` of Borg
# UI's runtime base have a layer whose cache key is the base image and the
# instruction text, so from the GitHub Actions layer cache a later release
# would publish the packages an earlier one was built with, for as long as the
# base image is unchanged (#173). build.yml names the stage that holds the
# upgrade in `no-cache-filters`, and build-image.yml hands it to the build;
# every other stage keeps its cache. The end-to-end suites of lint-test.yml,
# the release's gate, build the agent image the same way. The server image is
# built on the runtime base by digest and has no upgrade of its own.

setup() {
  load helpers/versions
  load helpers/workflows
  BUILD_IMAGE="$REPO_ROOT/.github/workflows/build-image.yml"
}

# upgrade_stages DOCKERFILE — the stages whose RUN upgrades the distribution's
# packages, one a line. An unnamed stage prints as "#N", its index, which no
# filter can name.
upgrade_stages() {
  awk '
    /^FROM / { stage = "#" n++; for (i = 2; i < NF; i++) if (toupper($i) == "AS") stage = $(i + 1) }
    /^RUN / { run = 1 }
    run && /(apk|apt-get) upgrade/ { print stage }
    run && !/\\$/ { run = 0 }' "$1" | sort -u
}

# final_stage DOCKERFILE — the name (or "#N") of the last stage.
final_stage() {
  awk '/^FROM / { stage = "#" n++; for (i = 2; i < NF; i++) if (toupper($i) == "AS") stage = $(i + 1) }
       END { print stage }' "$1"
}

# job_value JOB KEY — KEY of the `with:` of an image job in build.yml.
job_value() { wf_job "$BUILD_WF" "$1" | awk -v key="$2:" '$1 == key { print $2 }'; }

# job_filters JOB — the stages JOB builds without the cache, one a line.
job_filters() { job_value "$1" no-cache-filters | tr ',' '\n' | sed '/^$/d' | sort -u; }

build_step() { wf_step "$BUILD_IMAGE" 'id: build'; }

@test "the extractors find what the checks below read" {
  [ "$(upgrade_stages "$REPO_ROOT/docker/Dockerfile")" = agent ] \
    || fail "upgrade_stages docker/Dockerfile: $(upgrade_stages "$REPO_ROOT/docker/Dockerfile")"
  [ "$(final_stage "$REPO_ROOT/docker/Dockerfile")" = agent ] \
    || fail "final_stage docker/Dockerfile: $(final_stage "$REPO_ROOT/docker/Dockerfile")"
  [ "$(job_value agent file)" = ./docker/Dockerfile ] || fail "job_value agent file: $(job_value agent file)"
  [ "$(wf_image_jobs "$BUILD_WF" | tr '\n' ' ')" = "agent runtime-base server " ] \
    || fail "image jobs: $(wf_image_jobs "$BUILD_WF" | tr '\n' ' ')"
  [ -n "$(build_step)" ] || fail "no build step in build-image.yml"
  # An unnamed stage, a RUN that continues on the next line, a comment.
  printf '%s\n' 'FROM a AS one' 'RUN true \' '    && apt-get upgrade -y' '# apk upgrade' 'FROM b' 'RUN apk upgrade' \
    >"$BATS_TEST_TMPDIR/Dockerfile"
  [ "$(upgrade_stages "$BATS_TEST_TMPDIR/Dockerfile" | tr '\n' ' ')" = "#1 one " ] \
    || fail "upgrade_stages: $(upgrade_stages "$BATS_TEST_TMPDIR/Dockerfile" | tr '\n' ' ')"
  [ "$(final_stage "$BATS_TEST_TMPDIR/Dockerfile")" = "#1" ] || fail "final_stage: $(final_stage "$BATS_TEST_TMPDIR/Dockerfile")"
}

@test "the agent image upgrades its packages in its final stage, named agent" {
  local df="$REPO_ROOT/docker/Dockerfile"
  [ "$(upgrade_stages "$df")" = agent ] || fail "stages with an upgrade: $(upgrade_stages "$df" | tr '\n' ' ')"
  [ "$(final_stage "$df")" = agent ] || fail "final stage: $(final_stage "$df")"
}

@test "every image job of build.yml builds exactly the stages that upgrade packages without the cache" {
  local job file want got
  for job in $(wf_image_jobs "$BUILD_WF"); do
    file="$(job_value "$job" file)"
    [ -n "$file" ] || fail "$job: no file"
    [ -f "$REPO_ROOT/$file" ] || fail "$job: $file does not exist (borg-ui checked out?)"
    want="$(upgrade_stages "$REPO_ROOT/$file")"
    got="$(job_filters "$job")"
    [[ "$want" != *"#"* ]] || fail "$job: $file upgrades packages in an unnamed stage: $(echo "$want" | tr '\n' ' ')"
    [ "$got" = "$want" ] \
      || fail "$job: no-cache-filters names '$(echo "$got" | tr '\n' ' ')', the stages of $file that upgrade are '$(echo "$want" | tr '\n' ' ')'"
  done
  # The two that do; the server image has no upgrade of its own.
  [ "$(job_filters agent)" = agent ] || fail "agent: $(job_filters agent)"
  [ "$(job_filters runtime-base)" = runtime-base ] || fail "runtime-base: $(job_filters runtime-base)"
}

@test "build-image.yml hands no-cache-filters to the build and keeps the cache for the rest" {
  wf_job "$BUILD_IMAGE" workflow_call | grep -qx '      no-cache-filters:' \
    || fail "build-image.yml has no no-cache-filters input"
  build_step | grep -qx '          no-cache-filters: \${{ inputs.no-cache-filters }}' \
    || fail "the build step does not pass inputs.no-cache-filters"
  build_step | grep -q '^          cache-from: type=gha,' || fail "the build step no longer reads the cache"
  ! build_step | grep -q '^          no-cache:' || fail "the build step turns the whole cache off"
}

# agent_builds FILE — one line per step of FILE that builds docker/Dockerfile:
# its no-cache-filters, or "-" when it has none.
agent_builds() {
  awk '
    function flush() { if (df) print (f == "" ? "-" : f); df = 0; f = "" }
    /^      - / { flush() }
    $1 == "file:" && $2 == "./docker/Dockerfile" { df = 1 }
    $1 == "no-cache-filters:" { f = $2 }
    END { flush() }' "$1"
}

@test "the end-to-end suites test the agent image with its final stage built anew, as a release does" {
  local wf="$REPO_ROOT/.github/workflows/lint-test.yml"
  [ "$(agent_builds "$wf" | wc -l | tr -d ' ')" = 2 ] || fail "agent image builds in lint-test.yml: $(agent_builds "$wf" | tr '\n' ' ')"
  [ "$(agent_builds "$wf" | sort -u)" = agent ] || fail "no-cache-filters of those builds: $(agent_builds "$wf" | tr '\n' ' ')"
}
