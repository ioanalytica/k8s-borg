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
#
# Borg comes from the static binaries published with each upstream release, the
# same ones the managed-agent installer puts on a node. A pod agent and a node
# agent therefore run byte-identical Borg, which is what makes testing one tell
# you anything about the other. That is also why this image is glibc-based:
# those binaries are glibc builds, and there are none for musl.

ARG BORG1_VERSION=1.4.4
ARG BORG2_VERSION=2.0.0b21

# --- Borg binaries: downloaded and verified in a stage of their own ----------
# Checksums are the sha256 digests GitHub publishes per release asset. They are
# pinned here rather than fetched alongside the download, so a substituted file
# cannot authenticate itself. Both majors ship glibc 2.35 builds; Debian 12
# provides 2.36.
FROM python:3.12-slim AS borg-binaries
ARG TARGETARCH
ARG BORG1_VERSION
ARG BORG2_VERSION

# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) asset_arch="x86_64-gh"; \
             borg1_sha="d48d3a31cf1f6fb781fe240945e0b1c246093d3b94b56ce8f501d46a8615f4de"; \
             borg2_sha="1cde53b9d248c1a600df6f938eea3207f27141be0e8d7a80542fa8f901f221c5" ;; \
      arm64) asset_arch="arm64-gh"; \
             borg1_sha="7bfe55dfd4088f5c570a9e0d5513b5e01a20c3555eedc95c2d7de952c260eb0f"; \
             borg2_sha="d008c57e97d977a409e5570a93e805be022ce6a69aef42db4d53dd68f4326a8f" ;; \
      *) echo "No published Borg binary for TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    mkdir -p /out; \
    base="https://github.com/borgbackup/borg/releases/download"; \
    curl -fsSL --proto '=https' --tlsv1.2 -o /out/borg1 \
      "${base}/${BORG1_VERSION}/borg-linux-glibc235-${asset_arch}"; \
    curl -fsSL --proto '=https' --tlsv1.2 -o /out/borg2 \
      "${base}/${BORG2_VERSION}/borg-linux-glibc235-${asset_arch}"; \
    printf '%s  /out/borg1\n%s  /out/borg2\n' "${borg1_sha}" "${borg2_sha}" | sha256sum -c -; \
    chmod 0755 /out/borg1 /out/borg2

# --- agent image -------------------------------------------------------------
FROM python:3.12-slim
ARG BORG1_VERSION
ARG BORG2_VERSION

# s3fs pulls libfuse2 for the s3fs mounts used by some sources. Borg's own FUSE
# support needs nothing here: the release binaries bundle libfuse3.
# rclone is a separate Go program that no Borg release bundles, and borgstore
# drives it over its rc API, so rclone: repositories need it present.
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    s3fs \
    rclone \
    ca-certificates \
    openssh-client \
    tzdata \
    postgresql-client \
    mariadb-client \
    rsync \
    curl \
    && rm -rf /var/lib/apt/lists/* \
    && update-ca-certificates

# Both Borg majors land in version-scoped directories, mirroring the layout the
# managed-agent installer creates on a node. The wrappers on PATH reach them
# through BORG1_BINARY/BORG2_BINARY, so they stay version-agnostic.
#
# The release binaries carry everything Borg needs: every borgstore backend
# (sftp for targets like a Hetzner Storage Box with no server-side Borg, plus
# rclone, rest, s3, and the built-in posixfs) and a bundled libfuse3 for
# `borg mount`. None of that has to be assembled here any more.
ENV BORG1_BINARY=/opt/borg-ui-agent/borg1/${BORG1_VERSION}/borg
ENV BORG2_BINARY=/opt/borg-ui-agent/borg2/${BORG2_VERSION}/borg
COPY --from=borg-binaries /out/borg1 ${BORG1_BINARY}
COPY --from=borg-binaries /out/borg2 ${BORG2_BINARY}

# A version-independent path per major, so the wrappers still resolve Borg when
# they run without this image's environment (`env -i`, a cron with no
# environment, `su -`). Without it their fallback would point at a distribution
# path that no longer exists here.
RUN ln -sfn "${BORG1_VERSION}" /opt/borg-ui-agent/borg1/current \
    && ln -sfn "${BORG2_VERSION}" /opt/borg-ui-agent/borg2/current

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
RUN chmod 0755 /entrypoint.sh /run-agent.sh /usr/local/bin/*

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

LABEL org.opencontainers.image.title="k8s-borg agent"
LABEL org.opencontainers.image.description="Borg UI managed-agent image for k8s-borg (Borg 1.x + Borg 2.x)"
LABEL org.opencontainers.image.source="https://github.com/ioanalytica/k8s-borg"

ENTRYPOINT ["/entrypoint.sh"]
CMD ["borg-ui-agent", "--help"]
