# syntax=docker/dockerfile:1
#
# k8s-borg — Borg UI managed agent, baked image (setup only).
#
# Ships Borg 1 (`borg`) and Borg 2 (`borg2`) plus the `borg-ui-agent` from the
# pinned `borg-ui` submodule. Runs as the unprivileged `borg` user (1001:1001),
# which may run `borg`/`borg2` via passwordless sudo for privileged source paths.
#
# The image is intentionally "cold": it is NOT enrolled. The agent credential
# (/etc/borg-ui-agent/config.toml) is written by `borg-ui-agent register` at
# enrollment time, which is wired up in a later iteration — not baked here.
#
# Build context is the repository root (so the submodule is reachable):
#   docker build -f docker/Dockerfile -t k8s-borg:local .
FROM python:3.12-alpine

# Runtime dependencies. borgbackup (Borg 1) and the ssh client live in the
# Alpine "community" repository, which is enabled on python:*-alpine images.
# openssh-client is needed for repositories reached over ssh://; sudo lets the
# borg user escalate borg/borg2. lz4-libs/zstd-libs/openssl/libffi are runtime
# libraries Borg 2 links against; they stay as explicit world members after the
# build toolchain is removed below. (libacl + libxxhash arrive via borgbackup.)
# hadolint ignore=DL3018
RUN apk add --no-cache \
        borgbackup \
        ca-certificates \
        openssh-client \
        sudo \
        tzdata \
        lz4-libs \
        zstd-libs \
        openssl \
        libffi \
    && update-ca-certificates

# Borg 2 (beta): no Alpine/musl wheel exists, so compile it into its own venv
# using a throwaway build toolchain, then expose it on PATH as `borg2`.
ENV BORG2_VENV=/opt/borg-ui-agent/borg2-venv
# hadolint ignore=DL3018
RUN apk add --no-cache --virtual .borg2-build \
        build-base \
        python3-dev \
        pkgconf \
        linux-headers \
        acl-dev \
        lz4-dev \
        zstd-dev \
        xxhash-dev \
        openssl-dev \
        libffi-dev \
    && python -m venv "${BORG2_VENV}" \
    && "${BORG2_VENV}/bin/pip" install --no-cache-dir --upgrade pip wheel \
    && "${BORG2_VENV}/bin/pip" install --no-cache-dir --pre "borgbackup>=2.0.0b1,<3" \
    && ln -s "${BORG2_VENV}/bin/borg" /usr/local/bin/borg2 \
    && apk del .borg2-build \
    && borg2 --version

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

# Service user `borg` (1001:1001) with passwordless sudo for borg + borg2.
# The agent itself invokes `borg`/`borg2` directly (no sudo); the sudo grant is
# the capability for privileged source paths — see README for how to use it.
RUN addgroup -g 1001 borg \
    && adduser -D -u 1001 -G borg -h /home/borg -s /bin/sh borg \
    && printf 'borg ALL=(ALL) NOPASSWD: /usr/bin/borg, /usr/local/bin/borg2\n' \
        > /etc/sudoers.d/borg \
    && chmod 0440 /etc/sudoers.d/borg \
    && visudo -cf /etc/sudoers.d/borg \
    && install -d -o borg -g borg -m 0750 /etc/borg-ui-agent

COPY docker/rootfs/ /
RUN chmod 0755 /entrypoint.sh

USER borg

# Build-time self-test from the borg user: borg, borg2, the sudo grants, and the
# agent must all work, or the build fails.
RUN borg --version \
    && borg2 --version \
    && sudo -n borg --version \
    && sudo -n borg2 --version \
    && borg-ui-agent --help >/dev/null

ENTRYPOINT ["/entrypoint.sh"]
CMD ["borg-ui-agent", "--help"]
