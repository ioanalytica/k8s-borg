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

# --- Borg binaries: downloaded and verified in a stage of their own ----------
# Versions and checksums both come from the borg-ui submodule's manifest, which
# is generated from the version its runtime base builds. There is no version
# literal and no digest in this file: a Borg bump happens in one place, in
# borg-ui, and this image follows.
#
# The checksums are committed there rather than fetched next to the download,
# so a substituted file cannot authenticate itself.
FROM python:3.12-slim AS borg-binaries
ARG TARGETARCH

# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY borg-ui/app/api/borg_binaries.json docker/select-borg-binaries.py /build/

RUN set -eu; \
    mkdir -p /out; \
    python /build/select-borg-binaries.py /build/borg_binaries.json "${TARGETARCH}" \
      > /build/plan; \
    cat /build/plan; \
    while read -r name version sha url; do \
      curl -fsSL --proto '=https' --tlsv1.2 -o "/out/${name}" "${url}"; \
      printf '%s  /out/%s\n' "${sha}" "${name}" | sha256sum -c - >/dev/null; \
      echo "verified ${name} ${version}"; \
    done < /build/plan; \
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

# Both Borg majors land under the same version-independent paths the wrappers
# fall back to, so they resolve Borg even without this image's environment
# (`env -i`, a cron with no environment, `su -`). An image is immutable, so
# there is nothing to install beside anything: the node installer keeps its
# version-scoped layout because it upgrades in place, this does not.
#
# The release binaries carry everything Borg needs: every borgstore backend
# (sftp for targets like a Hetzner Storage Box with no server-side Borg, plus
# rclone, rest, s3, and the built-in posixfs) and a bundled libfuse3 for
# `borg mount`. None of that has to be assembled here any more.
ENV BORG1_BINARY=/opt/borg-ui-agent/borg1/current/borg
ENV BORG2_BINARY=/opt/borg-ui-agent/borg2/current/borg
COPY --from=borg-binaries /out/borg1 ${BORG1_BINARY}
COPY --from=borg-binaries /out/borg2 ${BORG2_BINARY}

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
