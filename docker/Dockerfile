# syntax=docker/dockerfile:1
#
# k8s-borg — Borg UI managed agent, baked image (setup only).
#
# Ships Borg 1 (`borg`) and Borg 2 (`borg2`) plus the `borg-ui-agent` from the
# pinned `borg-ui` submodule. Everything runs as root, so backups can read any
# source path; the `borg`/`borg2` commands are thin wrappers that inject default
# params (e.g. --remote-path). SSH credentials live in /root/.ssh.
#
# The image is intentionally "cold": it is NOT enrolled. The agent credential
# (/etc/borg-ui-agent/config.toml) is written by `borg-ui-agent register` at
# enrollment time, which is wired up in a later iteration — not baked here.
FROM python:3.12-alpine

# hadolint ignore=DL3018
RUN apk add --no-cache \
        bash \
        borgbackup \
        s3fs-fuse \
        py3-llfuse \
        ca-certificates \
        openssh-client \
        tzdata \
        lz4-libs \
        zstd-libs \
        openssl \
        libffi \
        postgresql-client \
        mariadb-client \
        rsync \
    && update-ca-certificates

# Borg 2 (beta): no Alpine/musl wheel exists for borgbackup itself, so compile
# it into its own venv using a throwaway build toolchain. The `borg2` command is
# exposed on PATH later by a wrapper (docker/rootfs/usr/local/bin/borg2).
# The `borgstore[sftp]` extra adds the SFTP repository backend
# (paramiko + cryptography, all prebuilt musllinux wheels — no compiler needed),
# which lets borg2 use plain SFTP targets such as a Hetzner Storage Box without
# any server-side Borg.
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
    && "${BORG2_VENV}/bin/pip" install --no-cache-dir --pre \
        "borgbackup>=2.0.0b1,<3" "borgstore[sftp]" \
    && apk del .borg2-build \
    && "${BORG2_VENV}/bin/borg" --version

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

# Agent config dir; config.toml is written by `borg-ui-agent register`. The whole
# image runs as root, so no service user or sudo is needed.
RUN install -d -m 0750 /etc/borg-ui-agent

COPY docker/rootfs/ /
RUN chmod 0755 /entrypoint.sh /usr/local/bin/borg* /usr/local/bin/backup* /usr/local/bin/restore*

# Explicit HOME so `~` resolves to /root everywhere (the agent, borg's
# cache/security dirs, and ~/.ssh).
ENV HOME=/root
# Default common params injected by the borg/borg2 wrappers — empty by default,
# set per deployment. E.g. a Hetzner Storage Box reached by Borg 1 over ssh://
# needs `--remote-path=borg-1.4` to pick its server-side Borg; Borg 2 over
# sftp:// needs nothing.
ENV BORG1_DEFAULT_PARAMS=""
ENV BORG2_DEFAULT_PARAMS=""

# Build-time self-test: both Borg majors (via the wrappers) and the agent CLI
# must work, or the build fails.
RUN borg --version \
    && borg2 --version \
    && borg-ui-agent --help >/dev/null

WORKDIR /root

ENTRYPOINT ["/entrypoint.sh"]
CMD ["borg-ui-agent", "--help"]
