# syntax=docker/dockerfile:1
#
# k8s-borg — Borg UI managed agent, baked image (setup only).
#
# Ships Borg 1 plus the `borg-ui-agent` from the pinned `borg-ui` submodule.
# The image is intentionally "cold": it is NOT enrolled. The agent credential
# (/etc/borg-ui-agent/config.toml) is written by `borg-ui-agent register` at
# enrollment time, which is wired up in a later iteration — not baked here.
#
# Build context is the repository root (so the submodule is reachable):
#   docker build -f docker/Dockerfile -t k8s-borg:local .
FROM python:3.12-alpine

# Runtime dependencies. borgbackup (Borg 1) and the ssh client live in the
# Alpine "community" repository, which is enabled on python:*-alpine images.
# openssh-client is needed for repositories reached over ssh://.
# hadolint ignore=DL3018
RUN apk add --no-cache \
        borgbackup \
        ca-certificates \
        openssh-client \
        tzdata \
    && update-ca-certificates

# Install the agent from the pinned submodule into an isolated virtualenv.
# Only pyproject.toml + the agent package are copied (see .dockerignore); the
# package pulls just `requests` and `websocket-client` (pure-python wheels).
ENV BORG_UI_AGENT_VENV=/opt/borg-ui-agent/.venv
ENV PATH="${BORG_UI_AGENT_VENV}/bin:${PATH}"
COPY borg-ui/pyproject.toml /src/borg-ui/pyproject.toml
COPY borg-ui/agent /src/borg-ui/agent
RUN python -m venv "${BORG_UI_AGENT_VENV}" \
    && "${BORG_UI_AGENT_VENV}/bin/pip" install --no-cache-dir --upgrade pip wheel \
    && "${BORG_UI_AGENT_VENV}/bin/pip" install --no-cache-dir /src/borg-ui \
    && rm -rf /src

# Config directory. config.toml is created at registration, not at build time.
RUN install -d -m 0750 /etc/borg-ui-agent

COPY docker/rootfs/ /
RUN chmod 0755 /entrypoint.sh

# Build-time self-test: fail the build if Borg or the agent are not on PATH.
RUN borg --version && borg-ui-agent --help >/dev/null

ENTRYPOINT ["/entrypoint.sh"]
CMD ["borg-ui-agent", "--help"]
