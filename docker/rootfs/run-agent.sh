#!/usr/bin/env bash
#
# Enroll this host as a Borg UI managed agent, register its own repository and set
# its check-schedule (all idempotent), then run the agent.
#
# The provisioning steps form a DEPENDENCY CHAIN — enrolment → repo → plan — and
# are executed FAIL-FAST: if a precondition step fails, the script dies (the pod
# crash-loops and retries) instead of limping on into a broken agent session.
#
# Enrolment is SELF-HEALING: a persisted config.toml is trusted only if the server
# still knows this agent as queueable. A freshly re-created server (or a deleted
# agent) leaves a stale config.toml behind — we detect that and re-enroll rather
# than failing forever.
#
# The heavy lifting lives in standalone commands (also runnable by hand on a
# node): `register-repo`, `set-check-schedule`, `register-backup-plan`. This script
# orchestrates them and shares ONE admin bearer token via BORG_UI_JWT — a PAT
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

  # --- 1) enrolment (self-healing) -------------------------------------------
  # Trust a persisted config.toml only if the server still lists a queueable agent
  # by our name. Otherwise (no config, or a stale one after a server rebuild) mint
  # a fresh enrollment token and re-register. This is a hard precondition: without
  # a recognised agent there is no repo and no plan, so any failure here is fatal.
  agent_id=$(borgui_agent_id "$BORG_UI_JWT" "$BORG_UI_AGENT_NAME") \
    || borgui_die "could not query managed agents"

  if [ -f "$BORG_UI_CONFIG" ] && [ -n "$agent_id" ]; then
    echo "Already enrolled and recognised by the server (agent id ${agent_id}) — skipping enrollment."
  else
    if [ -f "$BORG_UI_CONFIG" ]; then
      echo "Stale enrolment: config present but the server has no queueable agent '${BORG_UI_AGENT_NAME}' (server re-created?) — re-enrolling." >&2
      rm -f "$BORG_UI_CONFIG"
    fi
    echo "Enrolling '${BORG_UI_AGENT_NAME}' at ${BORG_UI_SERVER} …"

    # admin token -> one-time enrollment token
    enroll=$(borgui_api "$BORG_UI_JWT" POST /api/managed-machines/enrollment-tokens \
               -H "Content-Type: application/json" \
               -d "{\"name\":\"${BORG_UI_AGENT_NAME}\",\"expires_in_minutes\":5}" \
             | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])') \
      || borgui_die "could not mint enrollment token (is the admin token an admin?)"

    # register -> writes ${BORG_UI_CONFIG} (also creates the AgentMachine record)
    borg-ui-agent --config "${BORG_UI_CONFIG}" register \
      --server "${BORG_UI_SERVER}" --token "${enroll}" --name "${BORG_UI_AGENT_NAME}" \
      || borgui_die "agent registration failed"

    agent_id=$(borgui_agent_id "$BORG_UI_JWT" "$BORG_UI_AGENT_NAME") || true
    [ -n "$agent_id" ] \
      || borgui_die "server still has no queueable agent '${BORG_UI_AGENT_NAME}' after enrolment"
    echo "Enrolled (agent id ${agent_id})."
  fi

  # --- 2) server-side config: repo -> {check-schedule, backup plan} ----------
  # Declarative and idempotent, run every start so it self-heals across rollouts.
  # FAIL-FAST on the dependency chain: register-repo is a hard precondition for the
  # schedule and the plan, so a failure aborts (the pod retries) rather than
  # continuing into a half-provisioned agent. The check-schedule is auxiliary
  # (repo integrity, nothing depends on it) and stays best-effort.
  #
  # register-backup-plan is gated by BORG_REGISTER_PLAN (default true): when the
  # backups are driven elsewhere (e.g. a k8s CronJob) the agent still enrols and
  # registers its repo — so the repository is browsable in Borg UI — but registers
  # NO backup plan of its own.
  register-repo || borgui_die "repo registration failed — cannot configure schedule/plan"
  set-check-schedule || echo "WARN: check-schedule setup failed — continuing (auxiliary)." >&2
  if [ "${BORG_REGISTER_PLAN:-true}" = "true" ]; then
    register-backup-plan || borgui_die "backup-plan registration failed"
  else
    echo "BORG_REGISTER_PLAN=${BORG_REGISTER_PLAN} — skipping backup-plan registration (backups managed elsewhere)."
  fi
  unset BORG_UI_JWT

  # --- 3) run ----------------------------------------------------------------
  # hand over to the long-running agent as PID 1 (clean signal handling)
  exec borg-ui-agent --config "${BORG_UI_CONFIG}" run
fi
