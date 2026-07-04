#!/usr/bin/env bash
#
# Enroll this host as a Borg UI managed agent (once), register its own repository
# and set its check-schedule (both idempotent), then run the agent.
#
# The heavy lifting lives in standalone commands (also runnable by hand on a
# node): `register-repo` and `set-check-schedule`. This script only orchestrates
# them and shares ONE admin JWT with them via BORG_UI_JWT.
#
set -euo pipefail

: "${BORG_UI_CONFIG:=/etc/borg-ui-agent/config.toml}"   # <- the fix: never empty

if [ "${BORG_UI_AGENT:-}" = "true" ]; then
  : "${BORG_UI_SERVER:?set BORG_UI_SERVER, e.g. http://k8s-borg-ui.borg.svc.cluster.local:8081}"
  : "${BORG_UI_AGENT_NAME:=$(hostname)}"

  echo "k8s-borg agent mode requested."

  # Admin JWT, fetched at most once and reused by every step below (enrollment
  # here, and register-repo / set-check-schedule via the exported BORG_UI_JWT).
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

  # --- 1) enrollment (once) --------------------------------------------------
  if [ ! -f "$BORG_UI_CONFIG" ]; then
    echo "Enrolling '${BORG_UI_AGENT_NAME}' at ${BORG_UI_SERVER} …"

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

  # --- 2) server-side config: repo + check-schedule (idempotent, best-effort) -
  # Runs every start so it self-heals hosts enrolled by an older image. One admin
  # JWT is shared with both commands; a failure here never blocks the agent.
  if login; then
    export BORG_UI_JWT="$jwt"
    register-repo      || echo "WARN: repo registration failed — continuing." >&2
    set-check-schedule || echo "WARN: check-schedule setup failed — continuing." >&2
    unset BORG_UI_JWT
  else
    echo "WARN: no admin JWT — skipping repo registration and check-schedule." >&2
  fi

  # --- 3) run ----------------------------------------------------------------
  # hand over to the long-running agent as PID 1 (clean signal handling)
  exec borg-ui-agent --config "${BORG_UI_CONFIG}" run
fi
