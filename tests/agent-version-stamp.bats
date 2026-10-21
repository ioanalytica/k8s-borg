#!/usr/bin/env bats
#
# docker/agent-version-stamp.sh decides whether the images built from a borg-ui
# pin carry the agent version X.Y.Z.<describe distance> instead of X.Y.Z (#77).
# A pin between releases with changed agent code must get one, or enrolled
# agents are never offered that code; a pin without agent changes must not, or
# every pin move offers an upgrade that changes nothing.
#
# The decision is tested against throwaway borg-ui-shaped repositories; the
# workflow tests below pin that both images get the one result.

bats_require_minimum_version 1.5.0   # run --separate-stderr

setup() {
  load helpers/versions
  # A test repository must not pick up signing or hooks from the user's config.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.org
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.org
  SRC="$BATS_TEST_TMPDIR/borg-ui"
  STAMP="$REPO_ROOT/docker/agent-version-stamp.sh"
}

# borg_ui VERSION [WITH_SCRIPT] — a repository with the files the stamp reads,
# released as v2.3.10.
borg_ui() {
  git init -q "$SRC"
  mkdir -p "$SRC/agent/borg_ui_agent" "$SRC/scripts" "$SRC/app"
  printf '[project]\nname = "borg-ui-agent"\nversion = "%s"\n' "$1" >"$SRC/pyproject.toml"
  printf '__version__ = "%s"\n' "$1" >"$SRC/agent/borg_ui_agent/__init__.py"
  echo server >"$SRC/app/main.py"
  [ "${2:-yes}" = yes ] && echo '# stamps' >"$SRC/scripts/agent_version.py"
  commit "release"
  git -C "$SRC" tag v2.3.10
}

commit() { git -C "$SRC" add -A && git -C "$SRC" commit -q --allow-empty -m "$1"; }

# change PATH — one commit changing a file below the checkout.
change() { echo "$RANDOM" >>"$SRC/$1"; commit "change $1"; }

stamp() { BORG_UI_DIR="$SRC" "$STAMP"; }

@test "a pin at a release tag keeps the plain version" {
  borg_ui 0.1.21
  run --separate-stderr stamp
  [ "$status" -eq 0 ] || fail "$stderr"
  [ -z "$output" ] || fail "stamped $output at the tag"
  [[ "$stderr" == *"0.1.21 (no stamp: the pin is release tag v2.3.10)"* ]] || fail "$stderr"
}

@test "agent code changed since the release: the describe distance" {
  borg_ui 0.1.21
  change app/main.py
  change agent/borg_ui_agent/jobs.py
  change app/main.py
  run --separate-stderr stamp
  [ "$status" -eq 0 ] || fail "$stderr"
  [ "$output" = 3 ] || fail "expected 3, got '$output'"
  [[ "$stderr" == *"agent 0.1.21.3 "* ]] || fail "$stderr"
}

@test "the distance is the one in the UI image tag" {
  borg_ui 0.1.21
  change agent/borg_ui_agent/jobs.py
  change app/main.py
  local described
  described="$(git -C "$SRC" describe --tags --match 'v[0-9]*' --abbrev=9 HEAD)"
  [[ "$described" == v2.3.10-2-g* ]] || fail "fixture: $described"
  [ "$(stamp 2>/dev/null)" = 2 ]
}

@test "a pyproject.toml change counts as an agent change" {
  borg_ui 0.1.21
  change pyproject.toml
  [ "$(stamp 2>/dev/null)" = 1 ]
}

@test "server-only changes since the release keep the plain version" {
  borg_ui 0.1.21
  change app/main.py
  change scripts/release.sh
  run --separate-stderr stamp
  [ "$status" -eq 0 ] || fail "$stderr"
  [ -z "$output" ] || fail "stamped $output without an agent change"
  [[ "$stderr" == *"unchanged since v2.3.10"* ]] || fail "$stderr"
}

@test "a pin before scripts/agent_version.py keeps the plain version" {
  # Before karanhudia/borg-ui#1415 every agent PR moved the version itself,
  # and the script that applies the stamp is not there.
  borg_ui 0.1.21 no
  change agent/borg_ui_agent/jobs.py
  run --separate-stderr stamp
  [ "$status" -eq 0 ] || fail "$stderr"
  [ -z "$output" ] || fail "stamped $output without agent_version.py"
  [[ "$stderr" == *"predates scripts/agent_version.py"* ]] || fail "$stderr"
}

@test "the commit decides, not the working tree" {
  borg_ui 0.1.21
  change app/main.py
  echo dirty >>"$SRC/agent/borg_ui_agent/__init__.py"
  [ -z "$(stamp 2>/dev/null)" ]
}

@test "the nearest release tag is the base, not the first" {
  borg_ui 0.1.21
  change agent/borg_ui_agent/jobs.py
  git -C "$SRC" tag v2.3.11
  change app/main.py
  [ -z "$(stamp 2>/dev/null)" ] || fail "agent unchanged since v2.3.11"
  change agent/borg_ui_agent/jobs.py
  [ "$(stamp 2>/dev/null)" = 2 ]
}

@test "tags that are not releases are ignored" {
  borg_ui 0.1.21
  change agent/borg_ui_agent/jobs.py
  git -C "$SRC" tag agent-snapshot
  [ "$(stamp 2>/dev/null)" = 1 ]
}

@test "no reachable release tag fails instead of guessing" {
  borg_ui 0.1.21
  git -C "$SRC" tag -d v2.3.10 >/dev/null
  run --separate-stderr stamp
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"--fetch-tags"* ]] || fail "$stderr"
}

@test "an agent version that is not X.Y.Z fails" {
  # agent_version.py edge refuses it too, but only once the image builds run.
  borg_ui 0.1.21.5
  change agent/borg_ui_agent/jobs.py
  run --separate-stderr stamp
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"is not X.Y.Z"* ]] || fail "$stderr"
}

@test "the pinned submodule gets no stamp or the distance of its UI tag" {
  local s v
  s="$("$STAMP" 2>/dev/null)" || fail "agent-version-stamp.sh failed on the pin — tags fetched (docker/ui-app-version.sh --fetch-tags)?"
  [ -z "$s" ] && return 0
  v="$(ui_app_version)"
  [[ "$v" == *"-$s-g"* ]] || fail "stamp $s is not the distance in the UI tag $v"
}

# --- the workflow: one stamp, both images ---------------------------------------

@test "build.yml computes the stamp once, after fetching the tags" {
  build_workflow | grep -q 'agent_edge="$(./docker/agent-version-stamp.sh)"' \
    || fail "the prep job no longer takes the stamp from docker/agent-version-stamp.sh"
  build_workflow | grep -q 'echo "agent_edge=$agent_edge"' \
    || fail "the prep job no longer outputs agent_edge"
  local fetch stamp_line
  fetch="$(build_workflow | grep -n 'ui-app-version.sh --fetch-tags' | head -1 | cut -d: -f1)"
  stamp_line="$(build_workflow | grep -n 'agent-version-stamp.sh)' | head -1 | cut -d: -f1)"
  [ -n "$fetch" ] && [ "$stamp_line" -gt "$fetch" ] \
    || fail "the stamp is computed before the release tags are fetched"
}

@test "the agent and the server image get the same stamp" {
  # job_input JOB — the agent-edge input a job of build.yml passes on.
  job_input() {
    build_workflow | awk -v job="  $1:" '
      $0 == job { on = 1; next }
      on && /^  [a-z]/ { exit }
      on && $1 == "agent-edge:" { $1 = ""; sub(/^ /, ""); print }'
  }
  local want='${{ needs.prep.outputs.agent_edge }}'
  [ "$(job_input agent)" = "$want" ]  || fail "agent job: '$(job_input agent)'"
  [ "$(job_input server)" = "$want" ] || fail "server job: '$(job_input server)'"
  [ -z "$(job_input runtime-base)" ]  || fail "the runtime base has no agent to stamp"
}

@test "build-image.yml applies the stamp with upstream's edge mode before building" {
  local wf="$REPO_ROOT/.github/workflows/build-image.yml" stamp_line build_line
  grep -q 'run: python3 borg-ui/scripts/agent_version.py edge "$AGENT_EDGE"' "$wf" \
    || fail "build-image.yml no longer stamps with agent_version.py edge"
  grep -q "if: inputs.agent-edge != ''" "$wf" \
    || fail "the stamp step is no longer skipped without a stamp"
  stamp_line="$(grep -n 'agent_version.py edge' "$wf" | cut -d: -f1)"
  build_line="$(grep -n 'uses: docker/build-push-action' "$wf" | cut -d: -f1)"
  [ "$stamp_line" -lt "$build_line" ] || fail "the stamp is applied after the build"
}
