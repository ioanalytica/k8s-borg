#!/usr/bin/env bash
#
# Enroll this host as a Borg UI managed agent (once), register its own repository
# (idempotent), then run the agent.
#
# Idempotent: an existing config skips enrollment; an already-registered repo is
# left untouched. The admin JWT is fetched at most once (lazy login()) and shared
# by both the enrollment and the repository-registration step.
#
set -euo pipefail

: "${BORG_UI_CONFIG:=/etc/borg-ui-agent/config.toml}"   # <- the fix: never empty

if [ "${BORG_UI_AGENT:-}" = "true" ]; then
  : "${BORG_UI_SERVER:?set BORG_UI_SERVER, e.g. http://k8s-borg-ui.borg.svc.cluster.local:8081}"
  : "${BORG_UI_AGENT_NAME:=$(hostname)}"

  echo "k8s-borg agent mode requested."

  # Admin JWT, fetched at most once and reused by every step below. Callers use
  # `login || <handler>`: enrollment treats a failure as fatal, repo registration
  # as best-effort.
  jwt=""
  login() {
    [ -n "$jwt" ] && return 0
    if [ -z "${BORG_UI_ADMIN_USER:-}" ] || [ -z "${BORG_UI_ADMIN_PASS:-}" ]; then
      echo "login: set BORG_UI_ADMIN_USER and BORG_UI_ADMIN_PASS" >&2
      return 1
    fi
    jwt=$(curl -fsS -X POST "${BORG_UI_SERVER}/api/auth/login" \
            --data-urlencode "username=${BORG_UI_ADMIN_USER}" \
            --data-urlencode "password=${BORG_UI_ADMIN_PASS}" \
          | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])') \
      || { echo "login failed (credentials / server reachable?)" >&2; jwt=""; return 1; }
  }

  # Register this node's own repository (BORG_REPO) under the agent's name, bound
  # to this agent (executor_type=agent). Idempotent + best-effort: any problem is
  # a warning, never a reason to keep the agent from starting.
  register_repo() {
    if [ -z "${BORG_REPO:-}" ] || [ -z "${BORG_VERSION:-}" ]; then
      echo "Repo registration skipped: BORG_REPO/BORG_VERSION not set." >&2
      return 0
    fi
    local enc="${BORG_ENCRYPTION:-repokey-blake2}"     # matches borg-init
    local comp="${BORG_COMPRESSION:-auto,lz4}"

    login || { echo "WARN: repo registration skipped (login failed)." >&2; return 0; }

    # already registered? (match by name OR path -> no duplicates)
    local already
    already=$(curl -fsS "${BORG_UI_SERVER}/api/repositories/" \
                -H "Authorization: Bearer ${jwt}" \
              | REPO_NAME="${BORG_UI_AGENT_NAME}" BORG_REPO="${BORG_REPO}" python3 -c '
import sys, json, os
data = json.load(sys.stdin)
repos = data.get("repositories", data if isinstance(data, list) else [])
name, path = os.environ["REPO_NAME"], os.environ["BORG_REPO"]
print("yes" if any(r.get("name") == name or r.get("path") == path for r in repos) else "no")') \
      || { echo "WARN: could not list repositories — skipping registration." >&2; return 0; }
    if [ "${already}" = "yes" ]; then
      echo "Repository '${BORG_UI_AGENT_NAME}' already registered — skipping."
      return 0
    fi

    # resolve this node's agent id (agent-managed repo binds to agent_machine_id)
    local agent_id
    agent_id=$(curl -fsS "${BORG_UI_SERVER}/api/managed-machines/agents" \
                 -H "Authorization: Bearer ${jwt}" \
               | REPO_NAME="${BORG_UI_AGENT_NAME}" python3 -c '
import sys, json, os
agents = json.load(sys.stdin)
name = os.environ["REPO_NAME"]
match = [a for a in agents if a.get("name") == name]
print(match[0]["id"] if match else "")') \
      || { echo "WARN: could not list agents — skipping registration." >&2; return 0; }
    if [ -z "${agent_id}" ]; then
      echo "WARN: no enrolled agent named '${BORG_UI_AGENT_NAME}' — skipping repo registration." >&2
      return 0
    fi

    # build the import payload (python3 handles JSON escaping + int coercion)
    local payload
    payload=$(REPO_NAME="${BORG_UI_AGENT_NAME}" BORG_REPO="${BORG_REPO}" BORG_VERSION="${BORG_VERSION}" \
              BORG_ENCRYPTION="${enc}" BORG_COMPRESSION="${comp}" \
              AGENT_ID="${agent_id}" BORG_PASSPHRASE="${BORG_PASSPHRASE:-}" python3 -c '
import json, os
p = {
    "name": os.environ["REPO_NAME"],
    "path": os.environ["BORG_REPO"],
    "borg_version": int(os.environ["BORG_VERSION"]),
    "encryption": os.environ["BORG_ENCRYPTION"],
    "compression": os.environ["BORG_COMPRESSION"],
    "execution_target": "agent",
    "executor_type": "agent",
    "agent_machine_id": int(os.environ["AGENT_ID"]),
}
pw = os.environ.get("BORG_PASSPHRASE")
if pw:
    p["passphrase"] = pw
print(json.dumps(p))') \
      || { echo "WARN: could not build repo payload (bad BORG_VERSION?) — skipping." >&2; return 0; }

    # import = record an existing repo; no borg init, no agent round-trip
    if curl -fsS -X POST "${BORG_UI_SERVER}/api/repositories/import" \
         -H "Authorization: Bearer ${jwt}" -H "Content-Type: application/json" \
         -d "${payload}" >/dev/null; then
      echo "Repository '${BORG_UI_AGENT_NAME}' registered (agent id ${agent_id})."
    else
      echo "WARN: repository registration failed." >&2
    fi
  }

  # --- 1) enrollment (once) --------------------------------------------------
  if [ ! -f "$BORG_UI_CONFIG" ]; then
    echo "Enrolling '${BORG_UI_AGENT_NAME}' at ${BORG_UI_SERVER} …"

    # admin login -> short-lived JWT (fatal here: no config, no agent)
    login || { echo "FATAL: cannot enroll without an admin JWT" >&2; exit 1; }

    # JWT -> one-time enrollment token
    enroll=$(curl -fsS -X POST "${BORG_UI_SERVER}/api/managed-machines/enrollment-tokens" \
               -H "Authorization: Bearer ${jwt}" -H "Content-Type: application/json" \
               -d "{\"name\":\"${BORG_UI_AGENT_NAME}\",\"expires_in_minutes\":5}" \
             | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])') \
      || { echo "FATAL: could not mint enrollment token (is '${BORG_UI_ADMIN_USER}' an admin?)" >&2; exit 1; }

    # register -> writes ${BORG_UI_CONFIG} (also creates the AgentMachine record)
    borg-ui-agent --config "${BORG_UI_CONFIG}" register \
      --server "${BORG_UI_SERVER}" --token "${enroll}" --name "${BORG_UI_AGENT_NAME}"
  else
    echo "Already enrolled (${BORG_UI_CONFIG}) — skipping enrollment."
  fi

  # --- 2) repository registration (idempotent, best-effort) ------------------
  # Runs every start so it self-heals even for hosts enrolled by an older image.
  register_repo

  # --- 3) run ----------------------------------------------------------------
  # hand over to the long-running agent as PID 1 (clean signal handling)
  exec borg-ui-agent --config "${BORG_UI_CONFIG}" run
fi
