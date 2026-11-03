#!/usr/bin/env bash
#
# The page "Try it locally" (site/guide/try-locally.md) end to end: a k3d
# cluster and the page's own shell blocks, with the files of this checkout in
# place of its raw URLs. What the page does in Borg UI goes through Borg UI's
# API instead, with the admin token the reconcile Job keeps in Secret
# k8s-borg-ui-pat: the node plan runs, and after the database step the
# cluster plan. borg in the pods then checks what they archived: the
# datastore snapshot and the k3s token, a file extracted from the archive,
# the database dump.
#
#   tests/try-locally/run.sh           # the latest release, as the page installs it
#   tests/try-locally/run.sh ./chart   # the chart of this checkout
#
# A chart directory is installed with the images it names. When one of them
# is not published yet (a release, a move of the borg-ui pin), the run stops
# before the cluster, says so and succeeds: the tag's build publishes them.
#
# The page's restore in Borg UI is left out: borg extract restores the same
# file from the same archive.
#
# Creates the page's k3d cluster and deletes it at the end, KEEP_CLUSTER=1
# keeps it; refuses to start when a cluster of that name exists. kubectl and
# helm use a kubeconfig of the run's own, so no other cluster is reachable
# from here. Needs docker, k3d, kubectl, helm, ssh-keygen, openssl, curl, jq.
set -euo pipefail

# shellcheck source=lib.bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.bash"

# block HEADING N — the page's Nth shell block under HEADING, localized:
# the checkout's files, and the chart of the command line if there is one.
block() {
  local code
  code="$(page_block "$1" sh "$2" | localize "$CHART")"
  [ -n "$code" ] || { echo "✗ the page has no shell block $2 under '$1'" >&2; return 1; }
  if grep -qF "$PAGE_URL" <<<"$code" || { [ -n "$CHART" ] && grep -qF "$PAGE_CHART" <<<"$code"; }; then
    echo "✗ block $2 under '$1' still names the page's URL or chart:" >&2
    echo "$code" >&2
    return 1
  fi
  printf '%s\n' "$code"
}

# show HEADING N CODE — the block as the log shows it, after how many
# seconds of the run.
show() {
  echo "▶ ${SECONDS}s, the page, '$1…' block $2:"
  sed 's/^/  $ /' <<<"$3"
}

# page HEADING N — run the block in this shell: the page's steps go on in
# one terminal, where the directory and $url stay as the last step left them.
page() {
  local code
  code="$(block "$1" "$2")"
  show "$1" "$2" "$code"
  eval "$code"
}

# page_out HEADING N — run the block in a shell of its own, its output on
# stdout. Bash drops `set -e` inside $(…) and in conditions; the block's own
# shell keeps it, so a failing command in the block fails the block.
page_out() {
  local code
  code="$(block "$1" "$2")" || return 1
  show "$1" "$2" "$code" >&2
  bash -euo pipefail -c "$code"
}

# expect WHAT REGEX TEXT — fail unless a line of TEXT matches REGEX.
expect() {
  grep -qE "$2" <<<"$3" || { echo "✗ $1: no line matches $2" >&2; return 1; }
  echo "✓ $1"
}

# pf_stop — end the port-forward, if one runs; the wait keeps bash from
# reporting it as terminated.
pf_stop() {
  [ -n "$PF_PID" ] || return 0
  kill "$PF_PID" 2>/dev/null || true
  wait "$PF_PID" 2>/dev/null || true
  PF_PID=""
}

# ui_connect — the page's port-forward to Borg UI (step 4), started anew;
# its address in $UI. The address is the one kubectl says it listens on:
# another service on the port, which may answer /health as well, must not
# get the admin token.
ui_connect() {
  local code port deadline log="$WORK/port-forward.log"
  code="$(block "## 4. " 1)"
  port="$(sed -n 's/.* \([0-9][0-9]*\):[0-9][0-9]*$/\1/p' <<<"$code")"
  [ "$(wc -l <<<"$code")" -eq 1 ] && [ -n "$port" ] \
    || { echo "✗ step 4 is no single port-forward: $code" >&2; return 1; }
  pf_stop
  show "## 4. " 1 "$code"
  eval "exec $code" >"$log" 2>&1 &
  PF_PID=$!
  UI="http://127.0.0.1:$port"
  deadline=$((SECONDS + 60))
  until grep -q "^Forwarding from 127\.0\.0\.1:$port " "$log" \
        && curl -fsS --max-time 5 -o /dev/null "$UI/health" 2>/dev/null; do
    kill -0 "$PF_PID" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ] \
      || { echo "✗ no port-forward to Borg UI at $UI:" >&2; cat "$log" >&2; return 1; }
    sleep 2
  done
}

# api METHOD PATH — Borg UI's answer, as the admin. The time limit keeps a
# server that takes the connection and never answers from outlasting the
# callers' deadlines.
api() {
  curl -sS --fail-with-body --max-time 30 -X "$1" -H "Authorization: Bearer $PAT" "$UI$2"
}

# run_plan NAME — what the page does in Borg UI: run the plan NAME once it is
# registered, and wait for the run. Completed with warnings passes: Borg warns
# about the files Docker mounts into the k3d node (the page says why).
run_plan() {
  local name="$1" id="" resp run status deadline failed
  ui_connect
  deadline=$((SECONDS + 300))
  until id="$(api GET /api/backup-plans/ | jq -r --arg n "$name" '.backup_plans[] | select(.name == $n) | .id')" \
        && [ -n "$id" ]; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "✗ Borg UI has no plan $name after 5 minutes" >&2; return 1; }
    sleep 5
  done
  resp="$(api POST "/api/backup-plans/$id/run")" \
    || { echo "✗ Borg UI did not start plan $name: $resp" >&2; return 1; }
  run="$(jq -r .id <<<"$resp")"
  echo "▶ ${SECONDS}s, plan $name (id $id): run $run"
  deadline=$((SECONDS + 600))
  while :; do
    api GET "/api/backup-plans/runs/$run" >"$WORK/run.json" || true
    status="$(jq -r '.status // empty' "$WORK/run.json" 2>/dev/null || true)"
    case "$status" in
      pending|running|"") ;;
      *) break ;;
    esac
    [ "$SECONDS" -lt "$deadline" ] || { echo "✗ run $run still ${status:-unknown} after 10 minutes" >&2; return 1; }
    sleep 5
  done
  jq -r '"  run \(.id): \(.status)\(if .error_message then " — " + .error_message else "" end)",
         (.script_executions[]? | "  \(.hook_type) hook \(.script_name): \(.status)"),
         (.repositories[]? | "  repository \(.repository.name // .repository_id): \(.status)\(if .error_message then " — " + .error_message else "" end)")' \
    "$WORK/run.json"
  case "$status" in
    completed|completed_with_warnings) ;;
    *) echo "✗ plan $name: $status" >&2; return 1 ;;
  esac
  # Borg's warnings may pass, a hook that failed may not: a run whose
  # snapshot was not removed afterwards can still end with warnings.
  failed="$(jq -r '.script_executions[]? | select(.status != "completed") | "\(.hook_type) hook \(.script_name): \(.status)"' "$WORK/run.json")"
  [ -z "$failed" ] || { echo "✗ plan $name: a hook did not complete: $failed" >&2; return 1; }
  echo "✓ plan $name: $status"
}

# diagnose — what the cluster shows, for a run that failed.
diagnose() {
  local ns pod
  echo "▶ the cluster after the failure"
  kubectl get pods -A -o wide || true
  kubectl get pvc -A || true
  kubectl get events -A --sort-by=.lastTimestamp | tail -n 60 || true
  for ns in k8s-borg demo; do
    for pod in $(kubectl -n "$ns" get pods -o name 2>/dev/null); do
      echo "--- $ns $pod"
      kubectl -n "$ns" logs "$pod" --all-containers --prefix --tail=150 || true
    done
  done
  if [ -s "$WORK/run.json" ]; then
    echo "--- the last plan run"
    jq . "$WORK/run.json" || true
  fi
}

cleanup() {
  local rc=$?
  pf_stop
  if [ -n "$CREATED" ]; then
    [ "$rc" -eq 0 ] || diagnose
    if [ -n "${KEEP_CLUSTER:-}" ]; then
      echo "◆ kept: k3d cluster $CLUSTER, KUBECONFIG=$KUBECONFIG"
      exit "$rc"
    fi
    # A cluster left behind would stop the next run, which refuses to start
    # next to one of its name.
    if ! k3d cluster delete "$CLUSTER" >/dev/null 2>&1; then
      echo "✗ k3d cluster $CLUSTER is left: k3d cluster delete $CLUSTER" >&2
      [ "$rc" -ne 0 ] || rc=1
    fi
  fi
  rm -rf "$WORK"
  exit "$rc"
}

# --- before the cluster ------------------------------------------------------

CHART=""
case $# in
  0) ;;
  1) [ -f "$1/Chart.yaml" ] || { echo "✗ $1 is no chart directory" >&2; exit 2; }
     CHART="$(cd "$1" && pwd)" ;;
  *) echo "usage: $0 [CHART_DIR]" >&2; exit 2 ;;
esac

# The page's commands take $url unquoted, as a reader's raw URL can be, and
# the paths go into them as they are: a space would split them.
for path in "$EXAMPLES" ${CHART:+"$CHART"}; do
  case "$path" in
    *[!A-Za-z0-9._/+@-]*)
      echo "✗ $path: the page's commands take paths of letters, digits and ._/+@- alone" >&2
      exit 2 ;;
  esac
done

for tool in docker k3d kubectl helm ssh-keygen openssl curl jq; do
  command -v "$tool" >/dev/null || { echo "✗ $tool is required" >&2; exit 1; }
done

# A block the page lost fails here, in a second, rather than after the install.
for b in "${PAGE_BLOCKS[@]}"; do
  block "${b%|*}" "${b#*|}" >/dev/null
done

CLUSTER="$(block "## 1. " 1 | sed -n 's/^k3d cluster create \([^ ]*\)$/\1/p')"
[ -n "$CLUSTER" ] || { echo "✗ the page's step 1 creates no k3d cluster" >&2; exit 1; }
NODE="k3d-$CLUSTER-server-0"
if k3d cluster get "$CLUSTER" >/dev/null 2>&1; then
  echo "✗ a k3d cluster $CLUSTER exists: this run creates its own and deletes it" >&2
  exit 1
fi

if [ -n "$CHART" ]; then
  images="$(chart_images "$CHART")"
  [ -n "$images" ] || { echo "✗ the chart names no image of ghcr.io/ioanalytica" >&2; exit 1; }
  # shellcheck disable=SC2086 # one image per word
  missing="$(unpublished $images)"
  if [ -n "$missing" ]; then
    msg="not run: the chart names images the tag's build has not published yet: $(paste -sd ' ' - <<<"$missing")"
    echo "◆ $msg"
    [ -z "${GITHUB_ACTIONS:-}" ] || echo "::notice title=Try it locally::$msg"
    exit 0
  fi
  echo "▶ the chart in $CHART, with $(paste -sd ' ' - <<<"$images")"
else
  echo "▶ the latest release of $PAGE_CHART"
fi

WORK="$(mktemp -d)"
export KUBECONFIG="$WORK/kubeconfig"
CREATED=""
PF_PID=""
trap cleanup EXIT
cd "$WORK"

# --- the page ----------------------------------------------------------------

# 1. A cluster. Ours once k3d made it: a create that fails, for a cluster of
# the name that another run made in the meantime, must not delete that one.
page "## 1. " 1
CREATED=1
page "## 1. " 2

# 2. Keys and passwords
page "## 2. " 1

# 3. Install
page "## 3. " 1

# Step 3's second block waits for the rollouts, then shows the node pod's
# log lines. The pods enroll and register after their rollout, so the lines
# come a few seconds later: the waits run once, and fail the run when the
# page's own time limit ends them, the rest of the block until the plan is
# registered, for up to five minutes. A node pod that started before the
# repository server could take it ends, and the kubelet starts it again; its
# rollout may have finished before it ended, as the pod has no readiness
# probe, so the rest of the block is what waits for it.
code="$(block "## 3. " 2)"
waits="$(grep ' rollout status ' <<<"$code" || true)"
rest="$(grep -v ' rollout status ' <<<"$code" || true)"
[ -n "$waits" ] && [ -n "$rest" ] \
  || { echo "✗ step 3's second block is no rollout wait and log: $code" >&2; exit 1; }
show "## 3. " 2 "$code"
bash -euo pipefail -c "$waits"
norm() { sed -E 's/[0-9]+/N/g'; }
deadline=$((SECONDS + 300))
until out="$(bash -euo pipefail -c "$rest" 2>&1)" && grep -q "^Backup plan '$NODE_PLAN' " <<<"$out"; do
  [ "$SECONDS" -lt "$deadline" ] || { echo "$out"; echo "✗ the node pod registered no plan $NODE_PLAN" >&2; exit 1; }
  sleep 5
done
echo "$out"
# The lines the page shows, ids aside.
missing="$(page_block "## 3. " "" 1 | norm | grep -vxF -f <(norm <<<"$out") || true)"
[ -z "$missing" ] || { echo "✗ the node pod's log lacks lines the page shows:" >&2; echo "$missing" >&2; exit 1; }
echo "✓ the node pod's log has the lines the page shows"

PAT="$(kubectl -n k8s-borg get secret k8s-borg-ui-pat -o jsonpath='{.data.BORG_UI_ADMIN_PAT}' | base64 -d)"
[ -n "$PAT" ] || { echo "✗ Secret k8s-borg-ui-pat holds no token" >&2; exit 1; }

# 5. A backup
run_plan "$NODE_PLAN"
out="$(page_out "## 5. " 1)"
echo "$out"
expect "the archive holds the datastore snapshot" '(^| )var/lib/k8s-borg/(.*/)?state\.db$' "$out"
expect "the archive holds the k3s server token" '(^| )var/lib/k8s-borg/(.*/)?token$' "$out"

# 6. A restore, with Borg alone
out="$(page_out "## 6. " 2)"
[ -n "$out" ] && [ "$out" = "$(docker exec "$NODE" cat /etc/os-release)" ] \
  || { echo "$out"; echo "✗ the extracted node/etc/os-release is not the node's /etc/os-release" >&2; exit 1; }
echo "✓ node/etc/os-release extracted, the same as the node's"

# 7. A database
page "## 7. " 1
run_plan "$CLUSTER_PLAN"
out="$(page_out "## 7. " 2)"
echo "$out"
expect "the archive holds the dump of shop" '/shop\.dump$' "$out"
expect "the archive holds the global objects" '/globals\.sql$' "$out"

echo "✓ the page end to end in ${SECONDS}s"
