#!/usr/bin/env bats
#
# .github/workflows/lint-test.yml: the checks the ruleset on main requires by
# name (shellcheck, chart-lint, bats, e2e, e2e-db), the Borg suites as one job
# per major behind the one check `e2e`, and the skip of the end-to-end jobs
# for a pull request that changes documentation alone — which a tag build, a
# branch push or a failed decision never gets.
#
# GitHub counts a skipped job as a passed check; that is what lets a skip keep
# a required check green, and what would let a failure through as well if the
# aggregate `e2e` were skipped after a failed need. The verdicts below run the
# workflow's own scripts.

setup() {
  load helpers/common
  load helpers/versions
  common_setup
  WF="$REPO_ROOT/.github/workflows/lint-test.yml"
}

teardown() { common_teardown; }

# job ID — the lines of one job, from its key up to the next job or the
# comment above it.
job() {
  awk -v key="  $1:" '
    $0 == key { on = 1; print; next }
    on && /^  [a-z#]/ { exit }
    on { print }' "$WF"
}

# run_block ID — the script of the job's `run: |` step, unindented.
run_block() {
  job "$1" | awk '
    /^        run: \|$/ { on = 1; next }
    on && /^          / { sub(/^          /, ""); print; next }
    on { exit }'
}

SKIP_IF="    if: \${{ !cancelled() && needs.changes.outputs.docs-only != 'true' }}"
PR_ONLY="if: github.event_name == 'pull_request' && !startsWith(github.ref, 'refs/tags/')"

@test "the extractors find each job and stop at the next" {
  local j
  for j in changes chart-lint shellcheck bats e2e-borg e2e e2e-db; do
    [ "$(job "$j" | head -1)" = "  $j:" ] || fail "no job $j"
    [ "$(job "$j" | grep -c '^  [a-z]')" -eq 1 ] || fail "job $j runs into the next"
  done
  [ -n "$(run_block e2e)" ] || fail "no run block in e2e"
  [ -n "$(run_block changes)" ] || fail "no run block in changes"
}

@test "every check the ruleset requires is a job under its own name" {
  # A `name:` would rename the check, and the ruleset would wait for the old
  # name for ever.
  local j
  for j in shellcheck chart-lint bats e2e e2e-db; do
    [ -n "$(job "$j")" ] || fail "no job $j"
    run grep '^    name:' <(job "$j")
    [ "$status" -ne 0 ] || fail "job $j is renamed: $output"
  done
}

@test "the Borg suites run as one job per major, both to the end" {
  job e2e-borg | grep -qx '    name: e2e (Borg ${{ matrix.borg }})' \
    || fail "the per-major jobs are named otherwise — a name of exactly 'e2e' would clash with the aggregate"
  job e2e-borg | grep -qx '        borg: \[1, 2\]' || fail "the matrix is not Borg 1 and Borg 2"
  job e2e-borg | grep -qx '      fail-fast: false' || fail "a failure in one major cancels the other"
  job e2e-borg | grep -qx '        run: SKIP_BUILD=1 ./tests/e2e/run.sh "$BORG_MAJOR"' \
    || fail "a job runs more than its own major"
  job e2e-borg | grep -qx '          BORG_MAJOR: ${{ matrix.borg }}' || fail "BORG_MAJOR is not the matrix entry"
}

@test "only the Borg 1 job writes the image cache back" {
  job e2e-borg | grep -qx "          cache-to: \${{ matrix.borg == 1 && 'type=gha,mode=max,scope=k8s-borg-e2e' || '' }}" \
    || fail "the cache export is not limited to Borg 1"
  run grep 'cache-to:' <(job e2e-db)
  [ "$status" -ne 0 ] || fail "e2e-db writes the cache: $output"
}

@test "e2e is the aggregate of both majors and runs whatever they did" {
  job e2e | grep -qx '    needs: \[changes, e2e-borg\]' || fail "e2e does not wait for the per-major jobs"
  # Without always() a failed major skips e2e, and a skipped check passes.
  job e2e | grep -qx '    if: always()' || fail "e2e is not always()"
  run grep -E 'run\.sh|uses:' <(job e2e)
  [ "$status" -ne 0 ] || fail "the aggregate runs something itself: $output"
}

@test "e2e passes when both majors passed or a documentation-only pull request skipped them" {
  # verdict RESULT DOCS_ONLY — the aggregate's script on these inputs.
  verdict() { RESULT="$1" DOCS_ONLY="$2" bash -e -c "$(run_block e2e)" >/dev/null; }
  verdict success ''       || fail "both majors passed, and e2e failed"
  verdict skipped true     || fail "a documentation-only pull request fails e2e"
  ! verdict failure ''     || fail "a failed major passes e2e"
  ! verdict failure true   || fail "a failed major passes e2e"
  ! verdict cancelled ''   || fail "a cancelled major passes e2e"
  ! verdict skipped ''     || fail "majors skipped without a documentation-only verdict pass e2e"
  ! verdict skipped false  || fail "majors skipped without a documentation-only verdict pass e2e"
}

@test "the end-to-end jobs skip on a documentation-only verdict alone" {
  # != 'true' rather than == 'false': when `changes` fails, its output is
  # empty and everything runs. !cancelled() keeps a failed `changes` from
  # skipping them the way a failed need would.
  job e2e-borg | grep -qxF "$SKIP_IF" || fail "e2e-borg skips on something else"
  job e2e-db | grep -qxF "$SKIP_IF" || fail "e2e-db skips on something else"
  local j
  for j in shellcheck chart-lint bats; do
    run grep -E '^    (if|needs):' <(job "$j")
    [ "$status" -ne 0 ] || fail "$j can be skipped: $output"
  done
}

@test "every job has a time limit, and e2e-db's leaves run.sh time to stop a stuck version" {
  # Without one a hung job holds the run for GitHub's six hours.
  local j limit target
  for j in changes chart-lint shellcheck bats e2e-borg e2e e2e-db; do
    job "$j" | grep -qE '^    timeout-minutes: [0-9]+$' || fail "job $j has no time limit"
  done
  # run.sh stops a server version after E2E_DB_TIMEOUT and says what it was
  # doing; GitHub's limit must not end the job first. e2e-db has taken up to
  # 16 minutes with a cold image cache.
  limit="$(job e2e-db | sed -n 's/^    timeout-minutes: //p')"
  target="$(sed -n 's/^TIMEOUT="\${E2E_DB_TIMEOUT:-\([0-9][0-9]*\)}"$/\1/p' "$REPO_ROOT/tests/e2e/db/run.sh")"
  [ -n "$target" ] || fail "no default E2E_DB_TIMEOUT in tests/e2e/db/run.sh"
  [ $((limit * 60)) -ge $((target + 20 * 60)) ] \
    || fail "e2e-db stops after ${limit} min, run.sh after ${target}s plus up to 20 min of suite"
}

@test "tag builds and branch pushes never skip" {
  # Tag builds call this workflow from Build & push; its `gate` is the suite.
  grep -q 'uses: ./.github/workflows/lint-test.yml' "$REPO_ROOT/.github/workflows/build.yml" \
    || fail "build.yml no longer gates on lint-test.yml"
  # The one writer of the verdict runs on pull requests only, never on a tag.
  [ "$(grep -c 'docs-only=true' "$WF")" -eq 1 ] || fail "docs-only=true is written in more than one place"
  run_block changes | grep -q 'echo "docs-only=true" >>"$GITHUB_OUTPUT"' \
    || fail "the changes job no longer writes the verdict"
  [ "$(job changes | grep -cxF "        $PR_ONLY")" -eq 2 ] \
    || fail "the checkout and the decision do not both run on pull requests only"
  # A `paths` filter would skip the workflow, whose checks then stay pending.
  run grep -nE '^ *paths(-ignore)?:' "$WF"
  [ "$status" -ne 0 ] || fail "a paths filter: $output"
}

# --- the decision on a real merge -------------------------------------------------

# pr_repo — a repository on the branch of a pull request, cut from main.
pr_repo() {
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.org
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.org
  R="$TMP/repo"
  git init -q -b main "$R"
  mkdir -p "$R/scripts" "$R/docker"
  cp "$REPO_ROOT/scripts/docs-only.sh" "$R/scripts/"
  echo readme >"$R/README.md"
  echo 'echo hi' >"$R/docker/hook.sh"
  git -C "$R" add -A && git -C "$R" commit -qm base
  git -C "$R" switch -qc pr
}

# merged — commit the pull request, move main on with a change to docker/, and
# check out their merge: HEAD as actions/checkout leaves a pull_request run.
merged() {
  git -C "$R" add -A && git -C "$R" commit -qm pr
  git -C "$R" switch -q main
  echo 'echo moved' >>"$R/docker/hook.sh"
  git -C "$R" commit -qam "main moves on"
  git -C "$R" merge -q --no-ff -m merge pr
}

# decide — the changes job's script in the repository, with its status; the
# verdict in $verdict.
decide() {
  local rc=0
  : >"$TMP/out"
  (cd "$R" && GITHUB_OUTPUT="$TMP/out" RUNNER_TEMP="$TMP" bash -e -c "$(run_block changes)") || rc=$?
  verdict="$(cat "$TMP/out")"
  return "$rc"
}

@test "a pull request that changes documentation is documentation only, whatever main did since" {
  pr_repo
  echo more >>"$R/README.md"
  merged
  decide || fail "the decision failed"
  [ "$verdict" = "docs-only=true" ] || fail "verdict '$verdict'"
}

@test "moving a script to a Markdown name is not documentation" {
  pr_repo
  git -C "$R" mv docker/hook.sh NOTES.md
  merged
  decide || fail "the decision failed"
  [ -z "$verdict" ] || fail "the rename passed as documentation: '$verdict'"
}

@test "a HEAD that is not the merge fails the decision instead of guessing" {
  pr_repo
  echo more >>"$R/README.md"
  git -C "$R" commit -qam pr
  run decide
  [ "$status" -ne 0 ] || fail "decided on a plain commit: $output"
  [ ! -s "$TMP/out" ] || fail "wrote a verdict: $(cat "$TMP/out")"
}
