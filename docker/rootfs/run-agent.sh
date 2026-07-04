#!/usr/bin/env bash
#
# Enroll this host as a Borg UI managed agent (once), then run the agent.
# Idempotent: an existing config skips enrollment and goes straight to "run".
#
set -euo pipefail

: "${BORG_UI_CONFIG:=/etc/borg-ui-agent/config.toml}"   # <- the fix: never empty

if [ "${BORG_UI_AGENT:-}" = "true" ]; then
  : "${BORG_UI_SERVER:?set BORG_UI_SERVER, e.g. http://k8s-borg-ui.borg.svc.cluster.local:8081}"
  : "${BORG_UI_AGENT_NAME:=$(hostname)}"

  echo "k8s-borg agent mode requested."

  if [ ! -f "$BORG_UI_CONFIG" ]; then
    # credentials only needed for the one-time enrollment
    : "${BORG_UI_ADMIN_USER:?set BORG_UI_ADMIN_USER to enroll}"
    : "${BORG_UI_ADMIN_PASS:?set BORG_UI_ADMIN_PASS to enroll}"
    echo "Enrolling '${BORG_UI_AGENT_NAME}' at ${BORG_UI_SERVER} …"

    # 1) admin login -> short-lived JWT
    jwt=$(curl -fsS -X POST "${BORG_UI_SERVER}/api/auth/login" \
            --data-urlencode "username=${BORG_UI_ADMIN_USER}" \
            --data-urlencode "password=${BORG_UI_ADMIN_PASS}" \
          | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])') \
      || { echo "FATAL: login failed (credentials / server reachable?)" >&2; exit 1; }

    # 2) JWT -> one-time enrollment token
    enroll=$(curl -fsS -X POST "${BORG_UI_SERVER}/api/managed-machines/enrollment-tokens" \
               -H "Authorization: Bearer ${jwt}" -H "Content-Type: application/json" \
               -d "{\"name\":\"${BORG_UI_AGENT_NAME}\",\"expires_in_minutes\":5}" \
             | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])') \
      || { echo "FATAL: could not mint enrollment token (is '${BORG_UI_ADMIN_USER}' an admin?)" >&2; exit 1; }

    # 3) register -> writes ${BORG_UI_CONFIG}
    borg-ui-agent --config "${BORG_UI_CONFIG}" register \
      --server "${BORG_UI_SERVER}" --token "${enroll}" --name "${BORG_UI_AGENT_NAME}"
  else
    echo "Already enrolled (${BORG_UI_CONFIG}) — skipping enrollment."
  fi

  # hand over to the long-running agent as PID 1 (clean signal handling)
  exec borg-ui-agent --config "${BORG_UI_CONFIG}" run
fi
