#!/usr/bin/env bash
#
# Enroll this host as a Borg UI managed agent (once), register its own repository
# and set its check-schedule (both idempotent), then run the agent.
#
# The heavy lifting lives in standalone commands (also runnable by hand on a
# node): `register-repo` and `set-check-schedule`. This script only orchestrates
# them and shares ONE admin bearer token with them via BORG_UI_JWT — a PAT
# (BORG_UI_ADMIN_PAT) when available, else a user/password JWT login as fallback.
#
set -euo pipefail

. /usr/local/lib/borgui-common.sh

: "${BORG_UI_CONFIG:=/etc/borg-ui-agent/config.toml}"   # <- the fix: never empty

if [ "${BORG_UI_AGENT:-}" = "true" ]; then
  borgui_require_server
  : "${BORG_UI_AGENT_NAME:=$(hostname)}"

  echo "k8s-borg agent mode requested."

  # Resolve the admin bearer token ONCE (PAT-first; see borgui-common.sh) and share
  # it with every step below and the register-* sub-commands via the exported
  # BORG_UI_JWT. Dies after the built-in retry if neither a PAT nor an admin login
  # works — the wait-for-borgui init container should already have ensured health.
  BORG_UI_JWT=$(borgui_bearer) \
    || borgui_die "cannot authenticate to Borg UI (no working PAT, and admin login failed)"
  export BORG_UI_JWT

  # --- 1) enrollment (once) --------------------------------------------------
  if [ ! -f "$BORG_UI_CONFIG" ]; then
    echo "Enrolling '${BORG_UI_AGENT_NAME}' at ${BORG_UI_SERVER} …"

    # admin token -> one-time enrollment token
    enroll=$(borgui_api "$BORG_UI_JWT" POST /api/managed-machines/enrollment-tokens \
               -H "Content-Type: application/json" \
               -d "{\"name\":\"${BORG_UI_AGENT_NAME}\",\"expires_in_minutes\":5}" \
             | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])') \
      || borgui_die "could not mint enrollment token (is the admin token an admin?)"

    # register -> writes ${BORG_UI_CONFIG} (also creates the AgentMachine record)
    borg-ui-agent --config "${BORG_UI_CONFIG}" register \
      --server "${BORG_UI_SERVER}" --token "${enroll}" --name "${BORG_UI_AGENT_NAME}"
  else
    echo "Already enrolled (${BORG_UI_CONFIG}) — skipping enrollment."
  fi

  # --- 2) server-side config: repo + check-schedule + backup plan ------------
  # Idempotent/declarative, best-effort: runs every start so it self-heals hosts
  # enrolled by an older image. The shared BORG_UI_JWT lets the commands skip
  # re-auth; a failure here never blocks the agent. Order matters: the repo must
  # exist before its schedule/plan can bind to it.
  #
  # register-backup-plan is gated by BORG_REGISTER_PLAN (default true): when the
  # backups are driven elsewhere (e.g. a k8s CronJob), the agent still enrols and
  # registers its repo + check-schedule — so the repository is visible/browsable
  # in Borg UI — but registers NO backup plan of its own.
  register-repo        || echo "WARN: repo registration failed — continuing." >&2
  set-check-schedule   || echo "WARN: check-schedule setup failed — continuing." >&2
  if [ "${BORG_REGISTER_PLAN:-true}" = "true" ]; then
    register-backup-plan || echo "WARN: backup-plan setup failed — continuing." >&2
  else
    echo "BORG_REGISTER_PLAN=${BORG_REGISTER_PLAN} — skipping backup-plan registration (backups managed elsewhere)."
  fi
  unset BORG_UI_JWT

  # --- 3) run ----------------------------------------------------------------
  # hand over to the long-running agent as PID 1 (clean signal handling)
  exec borg-ui-agent --config "${BORG_UI_CONFIG}" run
fi
