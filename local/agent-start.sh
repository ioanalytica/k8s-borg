#!/usr/bin/env bash
#
# The managed agent of the local stack. Does by hand what the chart's init
# container and run.sh do for a pod — the SSH identity, the repository — and
# then hands over to the image's own /run-agent.sh, which enrolls the agent,
# registers its repository and runs it.
set -euo pipefail

: "${BORG_UI_AGENT_NAME:=$(hostname)}"
: "${REPO_SERVER:=repo-server:2222}"

install -d -m 0700 /root/.ssh
install -m 0600 /local/ssh/id_ed25519 /root/.ssh/id_ed25519
printf '[%s]:%s %s\n' "${REPO_SERVER%:*}" "${REPO_SERVER#*:}" \
  "$(cut -d' ' -f1,2 /local/ssh/ssh_host_ed25519_key.pub)" >/root/.ssh/known_hosts

# For a server URL on the TLS proxy: the stack's CA joins the system store.
case "${BORG_UI_SERVER}" in
  https://*)
    install -m 0644 /local/ca.crt /usr/local/share/ca-certificates/borg-local-ca.crt
    update-ca-certificates >/dev/null 2>&1
    ;;
esac

# A path relative to the client's directory on the repository server. Borg 2
# named these repositories rest:// up to 2.0.0b24 and ssh:// from then on;
# Borg 1 spells a relative path /./path.
if [ -z "${BORG_REPO:-}" ]; then
  if [ "${BORG_VERSION:-2}" = "2" ]; then
    scheme=ssh
    beta="$(borg2 --version 2>/dev/null | sed -n 's/.*2\.0\.0b\([0-9][0-9]*\).*/\1/p')"
    [ "${beta:-999}" -ge 25 ] || scheme=rest
    BORG_REPO="${scheme}://borg@${REPO_SERVER}/local/${BORG_UI_AGENT_NAME}-borg2"
  else
    BORG_REPO="ssh://borg@${REPO_SERVER}/./local/${BORG_UI_AGENT_NAME}-borg1"
  fi
fi
export BORG_REPO BORG_UI_AGENT_NAME

echo "Agent ${BORG_UI_AGENT_NAME}: server ${BORG_UI_SERVER}, repository ${BORG_REPO} (Borg ${BORG_VERSION:-2})"
borg-init
exec /run-agent.sh
