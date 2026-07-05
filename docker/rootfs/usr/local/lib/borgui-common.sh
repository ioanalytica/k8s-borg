# shellcheck shell=bash
#
# borgui-common.sh — shared helpers for the Borg UI agent-side commands.
# Sourced (never executed) by run-agent.sh and the /usr/local/bin provisioning
# commands (register-repo, set-check-schedule, register-backup-plan). Keeps the
# critical, security-relevant code — admin authentication and the repository
# lookup — in ONE place instead of copy-pasted per script.
#
# Contract: the sourcing script has already set `set -euo pipefail` and provides
# BORG_UI_SERVER (validated via borgui_require_server). Functions echo results on
# stdout and diagnostics on stderr.

# die MSG… — print a FATAL line and exit 1
borgui_die() { echo "FATAL: $*" >&2; exit 1; }

# require BORG_UI_SERVER to be set
borgui_require_server() {
  [ -n "${BORG_UI_SERVER:-}" ] \
    || borgui_die "set BORG_UI_SERVER, e.g. http://k8s-borg-ui.borg.svc.cluster.local:8081"
}

# --- authentication: resolve an admin bearer token, PAT-FIRST -----------------
# borgui_bearer echoes a usable admin bearer token on stdout. Order:
#   1. $BORG_UI_JWT if already set  (a token shared by a parent, e.g. run-agent.sh)
#   2. $BORG_UI_ADMIN_PAT if it authenticates (GET /api/auth/me == 200)
#   3. user/password login (BORG_UI_ADMIN_USER/PASS) as a FALLBACK
# Retried up to BORG_UI_LOGIN_RETRIES (5) × BORG_UI_LOGIN_RETRY_SLEEP (30s) while
# the server (and its bootstrap Job) settle. Returns non-zero if nothing worked.
# The resolved token may be a PAT or a JWT — both are `Authorization: Bearer`.
borgui_pat_ok() {  # 0 if the PAT authenticates as a user
  [ -n "${BORG_UI_ADMIN_PAT:-}" ] || return 1
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' \
           -H "Authorization: Bearer ${BORG_UI_ADMIN_PAT}" \
           "${BORG_UI_SERVER}/api/auth/me" 2>/dev/null) || return 1
  [ "$code" = "200" ]
}

borgui_jwt_login() {  # echoes an access_token (admin user/password fallback)
  [ -n "${BORG_UI_ADMIN_USER:-}" ] && [ -n "${BORG_UI_ADMIN_PASS:-}" ] || return 1
  curl -fsS -X POST "${BORG_UI_SERVER}/api/auth/login" \
    --data-urlencode "username=${BORG_UI_ADMIN_USER}" \
    --data-urlencode "password=${BORG_UI_ADMIN_PASS}" 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])' 2>/dev/null
}

borgui_bearer() {
  if [ -n "${BORG_UI_JWT:-}" ]; then printf '%s' "${BORG_UI_JWT}"; return 0; fi
  local tries=0 jwt
  while :; do
    if borgui_pat_ok; then
      echo "Authenticated with admin PAT." >&2
      printf '%s' "${BORG_UI_ADMIN_PAT}"; return 0
    fi
    if jwt=$(borgui_jwt_login) && [ -n "$jwt" ]; then
      echo "Authenticated with admin login (no working PAT)." >&2
      printf '%s' "$jwt"; return 0
    fi
    tries=$((tries + 1))
    if [ "$tries" -ge "${BORG_UI_LOGIN_RETRIES:-5}" ]; then
      echo "auth: no working PAT and admin login failed (set BORG_UI_ADMIN_PAT, or BORG_UI_ADMIN_USER/PASS)" >&2
      return 1
    fi
    echo "  Borg UI auth not ready yet — retrying (${tries}/${BORG_UI_LOGIN_RETRIES:-5}) …" >&2
    sleep "${BORG_UI_LOGIN_RETRY_SLEEP:-30}"
  done
}

# --- HTTP helper: curl against the server with the Bearer header --------------
# borgui_api TOKEN METHOD PATH [extra curl args…]
borgui_api() {
  local token="$1" method="$2" path="$3"; shift 3
  curl -fsS -X "$method" "${BORG_UI_SERVER}${path}" \
    -H "Authorization: Bearer ${token}" "$@"
}

# --- repository lookup (match by name OR path) -------------------------------
# borgui_repo_row TOKEN → echoes "<repo_id>\t<agent_machine_id>" (empty line if
# not found; agent_machine_id empty for non-agent repos). Uses REPO_NAME + BORG_REPO.
borgui_repo_row() {
  local token="$1"
  borgui_api "$token" GET /api/repositories/ \
    | REPO_NAME="${REPO_NAME}" BORG_REPO="${BORG_REPO}" python3 -c '
import sys, json, os
data = json.load(sys.stdin)
repos = data.get("repositories", data if isinstance(data, list) else [])
name, path = os.environ["REPO_NAME"], os.environ["BORG_REPO"]
m = [r for r in repos if r.get("name") == name or r.get("path") == path]
if m:
    aid = m[0].get("agent_machine_id")
    print(str(m[0]["id"]) + "\t" + (str(aid) if aid not in (None, "") else ""))'
}

# --- cron resolution from a projected-ConfigMap directory --------------------
# borgui_resolve_cron OVERRIDE DIR SUFFIX → echoes the trimmed cron (may be empty).
# First match wins: OVERRIDE, then <REPO_NAME><SUFFIX>, then default<SUFFIX>.
borgui_resolve_cron() {
  local cron="$1" dir="$2" suffix="$3"
  [ -z "$cron" ] && [ -f "${dir}/${REPO_NAME}${suffix}" ] && cron=$(cat "${dir}/${REPO_NAME}${suffix}")
  [ -z "$cron" ] && [ -f "${dir}/default${suffix}" ] && cron=$(cat "${dir}/default${suffix}")
  printf '%s' "$cron" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}
