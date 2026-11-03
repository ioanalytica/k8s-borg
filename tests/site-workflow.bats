#!/usr/bin/env bats
#
# .github/workflows/site.yml builds the documentation site and publishes it.
# Its paths filters decide which changes reach the site: a file the site shows
# but the filters miss would change on main and the site would keep the old
# text until something else touched it. And only main may publish.

setup() {
  load helpers/common
  load helpers/site
  load helpers/workflows
  WF="$REPO_ROOT/.github/workflows/site.yml"
}

# trigger_paths EVENT — the paths filter of one trigger of site.yml.
trigger_paths() {
  awk -v head="  $1:" '
    $0 == head { ev = 1; next }
    ev && /^  [^ ]/ { exit }
    ev && $1 == "paths:" { on = 1; next }
    on && $1 == "-" { p = $2; gsub(/"/, "", p); print p; next }
    on { on = 0 }' "$WF"
}

@test "the extractors find the triggers' paths, the source files and the jobs" {
  [ -n "$(trigger_paths push)" ] || fail "no paths for push"
  [ -n "$(trigger_paths pull_request)" ] || fail "no paths for pull_request"
  site_sources | grep -qx README.md || fail "$(site_sources)"
  site_sources | grep -qx examples/helm/k8s-borg.yaml || fail "$(site_sources)"
  [ -n "$(wf_job "$WF" build)" ] || fail "no build job"
  [ -n "$(wf_job "$WF" deploy)" ] || fail "no deploy job"
}

@test "pushes and pull requests run on the same paths" {
  [ "$(trigger_paths push)" = "$(trigger_paths pull_request)" ] \
    || fail "push: $(trigger_paths push | tr '\n' ' ') pull_request: $(trigger_paths pull_request | tr '\n' ' ')"
}

@test "every file the site shows or reads triggers the workflow, and so do site/, the workflow and its scripts" {
  local paths file scripts
  paths=$(trigger_paths push)
  scripts=$(wf_job "$WF" build | sed -nE 's/^ +run: (scripts\/[^ ]+).*/\1/p')
  [ -n "$scripts" ] || fail "the build job runs no script of scripts/"
  for file in 'site/**' .github/workflows/site.yml $scripts $(site_sources); do
    grep -qxF "$file" <<<"$paths" || fail "$file is in no paths filter of site.yml"
  done
}

@test "the build checks the links of what it built, before anything is uploaded" {
  local steps
  steps=$(wf_job "$WF" build | sed -nE 's/^      - name: //p')
  [ "$(grep -A1 -x Build <<<"$steps" | tail -1)" = "Check the links" ] || fail "$steps"
  [ "$(grep -A1 -x 'Check the links' <<<"$steps" | tail -1)" = "Upload the site" ] || fail "$steps"
  wf_step "$WF" 'name: Check the links' | grep -qxF '        run: scripts/site-relative-links.sh site/.vitepress/dist' \
    || fail "$(wf_step "$WF" 'name: Check the links')"
  ! wf_step "$WF" 'name: Check the links' | grep -q 'if:' || fail "the check does not run on every build"
}

@test "only main publishes, and only the deploy job may write to Pages" {
  local cond="if: github.event_name != 'pull_request' && github.ref == 'refs/heads/main'"
  wf_job "$WF" deploy | grep -qxF "    $cond" || fail "$(wf_job "$WF" deploy)"
  wf_step "$WF" 'name: Upload the site' | grep -qxF "        $cond" || fail "$(wf_step "$WF" 'name: Upload the site')"
  [ "$(sed -n '/^permissions:/,/^[^ p]/p' "$WF" | grep -c '^  ')" -eq 1 ] || fail "top-level permissions are more than contents"
  grep -qx '  contents: read' "$WF" || fail "no read-only default"
  [ "$(grep -c 'pages: write' "$WF")" -eq 1 ] && wf_job "$WF" deploy | grep -q 'pages: write' \
    || fail "pages: write outside the deploy job"
}

@test "every job has a time limit" {
  local job
  for job in build deploy; do
    wf_job "$WF" "$job" | grep -qE '^    timeout-minutes: [0-9]+$' || fail "$job has no timeout-minutes"
  done
}
