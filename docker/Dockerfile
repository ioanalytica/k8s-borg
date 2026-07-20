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
# Borg is compiled from the sdists at the versions the borg-ui submodule pins,
# because no musl build is published and the image is Alpine-based. The agent
# therefore runs the same Borg *version* as the server and as a node agent,
# though not the same build: nodes install the published static binaries, which
# exist only for glibc.
#
# Compiling buys back what those binaries cost: the image is ~100 MB smaller and
# Borg starts in about a third of the time, because a single-file binary unpacks
# itself on every invocation. The build toolchain never reaches the final image.

# --- Borg: compiled in a stage of its own -------------------------------------
# The venvs are built at the exact paths they will occupy in the final image: a
# virtualenv records its own location, so building elsewhere and copying would
# leave every console script pointing at a directory that does not exist.
#
# borg1 takes pyfuse3, a compiled extension; borg2 takes mfusepy, which loads
# libfuse through ctypes at run time. The borgstore extras add every Borg 2
# repository backend — sftp for targets like a Hetzner Storage Box with no
# server-side Borg, plus rclone, rest and s3; posixfs is built in.
#
# The versions come from the borg-ui manifest, so a Borg bump still happens in
# exactly one place, in borg-ui, and this image follows.
FROM python:3.12-alpine AS borg-builder

# hadolint ignore=DL3018
RUN apk add --no-cache \
        build-base python3-dev pkgconf linux-headers \
        acl-dev lz4-dev zstd-dev xxhash-dev openssl-dev libffi-dev fuse3-dev

COPY borg-ui/app/api/borg_binaries.json docker/borg-versions.py /build/

# hadolint ignore=DL3013
RUN set -eu; \
    eval "$(python /build/borg-versions.py /build/borg_binaries.json)"; \
    echo "compiling Borg ${BORG1_VERSION} and ${BORG2_VERSION}"; \
    python -m venv /opt/borg-ui-agent/borg1/venv; \
    /opt/borg-ui-agent/borg1/venv/bin/pip install --no-cache-dir -q \
        pyfuse3 "borgbackup[fuse]==${BORG1_VERSION}"; \
    python -m venv /opt/borg-ui-agent/borg2/venv; \
    /opt/borg-ui-agent/borg2/venv/bin/pip install --no-cache-dir -q --pre \
        "borgbackup==${BORG2_VERSION}" "borgstore[rclone,sftp,rest,s3]" mfusepy

# --- agent image -------------------------------------------------------------
FROM python:3.12-alpine

# `fuse` (the FUSE 2 library) is what mfusepy loads for `borg2 mount`; Alpine
# already ships libfuse3.so.4, so fuse3 alone does not satisfy it. s3fs-fuse
# covers the s3fs mounts some sources use. rclone is a separate Go program that
# no Borg release bundles, and borgstore drives it over its rc API, so rclone:
# repositories need it present.
# hadolint ignore=DL3018
RUN apk add --no-cache \
        bash \
        ca-certificates \
        openssh-client \
        tzdata \
        rsync \
        curl \
        rclone \
        postgresql-client \
        mariadb-client \
        s3fs-fuse \
        fuse3 \
        fuse \
        acl \
        lz4-libs \
        zstd-libs \
        libxxhash \
        openssl \
        libffi \
    && update-ca-certificates

# The compiled virtualenvs, without the toolchain that produced them. Their
# extensions link against acl, lz4, zstd, xxhash, openssl, libffi and libfuse3,
# all of which the runtime packages above provide.
COPY --from=borg-builder /opt/borg-ui-agent/borg1/venv /opt/borg-ui-agent/borg1/venv
COPY --from=borg-builder /opt/borg-ui-agent/borg2/venv /opt/borg-ui-agent/borg2/venv

# Version-independent paths, so the wrappers resolve Borg even without this
# image's environment (`env -i`, a cron with no environment, `su -`).
ENV BORG1_BINARY=/opt/borg-ui-agent/borg1/current/borg
ENV BORG2_BINARY=/opt/borg-ui-agent/borg2/current/borg
RUN install -d /opt/borg-ui-agent/borg1/current /opt/borg-ui-agent/borg2/current \
    && ln -sfn /opt/borg-ui-agent/borg1/venv/bin/borg "${BORG1_BINARY}" \
    && ln -sfn /opt/borg-ui-agent/borg2/venv/bin/borg "${BORG2_BINARY}"

# mfusepy finds libfuse through ctypes, and Alpine has no ldconfig for it to
# consult, so the path has to be handed over. Resolved at build time rather than
# hardcoded: Alpine has already moved to libfuse3.so.4 while mfusepy wants the
# FUSE 2 ABI, so a guessed path ages badly. Without this, borg2 raises
# "Unable to find libfuse" on import — it cannot even print its version.
RUN set -eu; \
    lib="$(find /usr/lib -maxdepth 1 -name 'libfuse.so.2' | head -n 1)"; \
    [ -n "${lib}" ] || { echo "no FUSE 2 library found for mfusepy" >&2; exit 1; }; \
    printf 'FUSE_LIBRARY_PATH=%s\n' "${lib}" > /etc/borg-fuse.env; \
    cat /etc/borg-fuse.env

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
