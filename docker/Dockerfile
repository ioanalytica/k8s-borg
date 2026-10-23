# syntax=docker/dockerfile:1
#
# k8s-borg — Borg UI managed agent, baked image (setup only).
#
# Ships Borg 1 (`borg`) and Borg 2 (`borg2`) plus the `borg-ui-agent` from the
# pinned `borg-ui` submodule. Everything runs as root, so backups can read any
# source path; the `borg`/`borg2` commands are thin wrappers that inject default
# params (e.g. --remote-path). SSH credentials live in /root/.ssh.
#
# The same image is the optional repository server (/prepare-repo-server.sh,
# then /run-repo-server.sh): sshd as an unprivileged user, every client key
# bound to `borg serve --rest` for its own path. Server and clients therefore
# always run the same Borg 2.
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
# server-side Borg, plus rclone, rest and s3; posixfs is built in — and blake3,
# the hash Borg 2 stores its objects under.
#
# The versions come from the borg-ui submodule, so a Borg bump still happens in
# exactly one place, in borg-ui, and this image follows: Borg from its manifest,
# borgstore from its runtime-base.env. borgstore is pinned to exactly that
# version. Borg 2 and borgstore belong together, on the client and on the
# repository server; a pin that no longer fits the Borg 2 being built fails the
# build instead of installing something else.
#
# Python tracks borg-ui/docker/runtime-base.env, same as the server image, kept
# in step by a guard test.
ARG PYTHON_VERSION=3.12
# The MySQL client of databases.mysql (see the mysql-client stage), pinned to
# the official image's multi-arch index digest: a bump changes both lines.
ARG MYSQL_VERSION=8.4.11
ARG MYSQL_IMAGE_DIGEST=sha256:24989179f58856db763f418010c1169fecc944e3ec1ea7e921572d83eb070f70

FROM python:${PYTHON_VERSION}-alpine AS borg-builder

# hadolint ignore=DL3018
RUN apk add --no-cache \
        build-base python3-dev pkgconf linux-headers \
        acl-dev lz4-dev zstd-dev xxhash-dev openssl-dev libffi-dev fuse3-dev

COPY borg-ui/app/api/borg_binaries.json borg-ui/docker/runtime-base.env docker/borg-versions.py /build/

# hadolint ignore=DL3013
RUN set -eu; \
    eval "$(python /build/borg-versions.py /build/borg_binaries.json /build/runtime-base.env)"; \
    echo "compiling Borg ${BORG1_VERSION} and ${BORG2_VERSION}, with borgstore ${BORGSTORE_VERSION}"; \
    python -m venv /opt/borg-ui-agent/borg1/venv; \
    /opt/borg-ui-agent/borg1/venv/bin/pip install --no-cache-dir -q \
        pyfuse3 "borgbackup==${BORG1_VERSION}"; \
    python -m venv /opt/borg-ui-agent/borg2/venv; \
    /opt/borg-ui-agent/borg2/venv/bin/pip install --no-cache-dir -q --pre \
        "borgbackup==${BORG2_VERSION}" \
        "borgstore[rclone,sftp,rest,s3,blake3]==${BORGSTORE_VERSION}" mfusepy

# --- s3fs: the release plus one upstream fix ----------------------------------
# s3fs 1.96 and 1.97 serve a two-entry listing for a directory that has no
# directory object of its own (what rclone and most S3 writers leave behind)
# once the directory's stat cache entry has expired: the implicit-directory
# check stores its max-keys=2 probe as the directory's listing. Borg then
# archives two files of such a directory. The fix is upstream (s3fs-fuse
# #2929) but in no release yet, so the 1.97 release is built here with that
# one change; Alpine's package is the same release without it. Drop this stage
# and go back to the package once a release carries the fix.
FROM python:${PYTHON_VERSION}-alpine AS s3fs-builder

ARG S3FS_VERSION=1.97
ARG S3FS_SHA512=24b70877a5c162252f08e55176a9e9fa2fd380ed3bbe8f51306f0e1489038a80cbd2a07699689431e3294661fa8d0f2434e7fc94cd14e6c9b4b8fa8be2e1f8a7

# hadolint ignore=DL3018
RUN apk add --no-cache \
        build-base automake autoconf curl curl-dev libxml2-dev openssl-dev fuse3-dev

COPY docker/s3fs/*.patch /build/s3fs-patches/

WORKDIR /build
RUN set -eu; \
    curl -fsSL -o s3fs.tar.gz "https://github.com/s3fs-fuse/s3fs-fuse/archive/v${S3FS_VERSION}.tar.gz"; \
    printf '%s  s3fs.tar.gz\n' "${S3FS_SHA512}" >s3fs.tar.gz.sha512; \
    sha512sum -c s3fs.tar.gz.sha512; \
    tar -xzf s3fs.tar.gz

WORKDIR /build/s3fs-fuse-${S3FS_VERSION}
RUN set -eu; \
    for p in /build/s3fs-patches/*.patch; do patch -p1 --forward <"${p}"; done; \
    ./autogen.sh; \
    ./configure --prefix=/usr; \
    make -j"$(nproc)"; \
    install -D -s -m 0755 src/s3fs /out/usr/bin/s3fs

# --- etcd client: etcdctl and etcdutl -----------------------------------------
# For the node backup's datastore snapshot (datastore-snapshot): etcdctl takes
# the snapshot from the node's etcd, etcdutl checks it, and restores it. The
# official release build, pinned with its checksum per architecture; tested
# against the etcd 3.6 of k3s and the etcd 3.7 of kubeadm.
FROM python:${PYTHON_VERSION}-alpine AS etcd-fetch

ARG TARGETARCH
ARG ETCD_VERSION=3.6.15
ARG ETCD_SHA256_AMD64=b51d86e6bff2168de5ba8cd631c0fe6c785c7a1b32b083079f5677d6b7e2772c
ARG ETCD_SHA256_ARM64=567d9b8fa9e75b349600d2b64ef9bf6bc6d512cea75a2ce1c39b1b3046131244

# hadolint ignore=DL3018
RUN apk add --no-cache curl

WORKDIR /build
RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) sum="${ETCD_SHA256_AMD64}" ;; \
      arm64) sum="${ETCD_SHA256_ARM64}" ;; \
      *) echo "no etcd checksum for ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    name="etcd-v${ETCD_VERSION}-linux-${TARGETARCH}"; \
    curl -fsSL -o etcd.tar.gz "https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/${name}.tar.gz"; \
    printf '%s  etcd.tar.gz\n' "${sum}" >etcd.tar.gz.sha256; \
    sha256sum -c etcd.tar.gz.sha256; \
    tar -xzf etcd.tar.gz; \
    install -D -m 0755 "${name}/etcdctl" /out/usr/local/bin/etcdctl; \
    install -D -m 0755 "${name}/etcdutl" /out/usr/local/bin/etcdutl

# --- rclone -----------------------------------------------------------------
# The official static build, pinned with its checksum per architecture. The
# version and checksums are docker/rclone.env's (tests/rclone-pin.bats keeps
# these defaults equal to it); Alpine's package lags behind upstream fixes.
FROM python:${PYTHON_VERSION}-alpine AS rclone-fetch

ARG TARGETARCH
ARG RCLONE_VERSION=1.75.2
ARG RCLONE_SHA256_AMD64=349ac8fba6ff65d6247043f1750cdcb518ec5d500ef91463a10d37c0ccdf3702
ARG RCLONE_SHA256_ARM64=7e1e8d69654941b7b7df84ee74c5f7fb09cce7d5496947fb7bf16b55ff427d10

# hadolint ignore=DL3018
RUN apk add --no-cache curl unzip

WORKDIR /build
RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) sum="${RCLONE_SHA256_AMD64}" ;; \
      arm64) sum="${RCLONE_SHA256_ARM64}" ;; \
      *) echo "no rclone checksum for ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    name="rclone-v${RCLONE_VERSION}-linux-${TARGETARCH}"; \
    curl -fsSL -o rclone.zip "https://downloads.rclone.org/v${RCLONE_VERSION}/${name}.zip"; \
    printf '%s  rclone.zip\n' "${sum}" >rclone.zip.sha256; \
    sha256sum -c rclone.zip.sha256; \
    unzip -q rclone.zip "${name}/rclone"; \
    install -D -m 0755 "${name}/rclone" /out/usr/bin/rclone; \
    # rclone reads RCLONE_* variables as flags, and these ARGs are such
    # variables here: RCLONE_VERSION would set --version.
    env -u RCLONE_VERSION -u RCLONE_SHA256_AMD64 -u RCLONE_SHA256_ARM64 /out/usr/bin/rclone version

# --- MySQL client: Oracle's build, with the glibc it runs on ------------------
# databases.mysql dumps with MySQL's own mysqldump: mariadb-dump writes the
# values of generated columns into its INSERTs, which MySQL rejects on restore
# (ERROR 3105), and copies system tables MySQL does not take back. Alpine has
# no MySQL client and gcompat cannot run Oracle's glibc build, so mysql and
# mysqldump come with the glibc libraries they link against and are started
# through that glibc's loader (wrappers in /opt/mysql/bin). Nothing outside
# /opt/mysql sees these libraries. The character set files go where the client
# looks for them, the license texts of what is copied to /opt/mysql/licenses.
FROM mysql:${MYSQL_VERSION}@${MYSQL_IMAGE_DIGEST} AS mysql-client
ARG MYSQL_VERSION
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN set -eu; \
    install -d /out/opt/mysql/bin /out/opt/mysql/libexec /out/opt/mysql/lib; \
    for prog in mysql mysqldump; do \
        cp "/usr/bin/${prog}" /out/opt/mysql/libexec/; \
        printf '#!/bin/sh\nexec /opt/mysql/lib/ld.so --library-path /opt/mysql/lib /opt/mysql/libexec/%s "$@"\n' \
            "${prog}" >"/out/opt/mysql/bin/${prog}"; \
        chmod 0755 "/out/opt/mysql/bin/${prog}"; \
    done; \
    ldd /usr/bin/mysql /usr/bin/mysqldump \
        | awk '$2 == "=>" && $3 ~ /^\// {print $3} $1 ~ /^\/.*ld-linux/ {print $1}' | sort -u \
        | while read -r lib; do cp -L "${lib}" /out/opt/mysql/lib/; done; \
    loaders=(/out/opt/mysql/lib/ld-linux-*); \
    [ "${#loaders[@]}" -eq 1 ] && [ -e "${loaders[0]}" ] || { echo "expected one glibc loader, got: ${loaders[*]}" >&2; exit 1; }; \
    ln -s "${loaders[0]##*/}" /out/opt/mysql/lib/ld.so; \
    share="/usr/share/mysql-${MYSQL_VERSION%.*}"; \
    install -d "/out${share}"; \
    cp -r "${share}/charsets" "/out${share}/"; \
    install -d /out/opt/mysql/licenses/mysql; \
    cp /usr/share/doc/mysql-community-server-minimal/LICENSE \
        /usr/share/doc/mysql-community-server-minimal/README /out/opt/mysql/licenses/mysql/; \
    for pkg in glibc openssl-libs zlib ncurses-base libgcc; do \
        cp -r "/usr/share/licenses/${pkg}" /out/opt/mysql/licenses/; \
    done

# --- agent image -------------------------------------------------------------
FROM python:${PYTHON_VERSION}-alpine

# `fuse` (the FUSE 2 library) is what mfusepy loads for `borg2 mount`; Alpine
# already ships libfuse3.so.4, so fuse3 alone does not satisfy it. s3fs comes
# from its own stage (see above) for the s3fs mounts some sources use; it links
# against libcurl, libxml2 and libstdc++, and fuse3 brings its library and
# fusermount3. mariadb-connector-c holds the client's authentication plugins
# (caching_sha2_password, ed25519, parsec); mariadb-client comes without them
# and could not log in as a user that needs one. rclone, from its own stage
# (see above), is a separate Go program that no Borg release bundles, and
# borgstore drives it over its rc API, so rclone: repositories need it present;
# s3-verify-listing lists the mounted buckets with it as well. openssh-server is
# only started by the repository server. mongodb-tools brings mongodump and
# mongorestore for the MongoDB dumps; the package's six other tools, ~13 MB
# each and unused here, are removed in the same layer. valkey-cli (the client
# alone, without a server) is for working with Redis and Valkey from the
# console pod; backup-redis talks to the servers through redis-rdb-sync.
# hadolint ignore=DL3018
RUN apk add --no-cache \
        bash \
        ca-certificates \
        openssh-client \
        openssh-server \
        tzdata \
        rsync \
        curl \
        postgresql-client \
        mariadb-client \
        mongodb-tools \
        mariadb-connector-c \
        valkey-cli \
        libcurl \
        libxml2 \
        libstdc++ \
        fuse3 \
        fuse \
        acl \
        lz4-libs \
        zstd-libs \
        libxxhash \
        openssl \
        libffi \
    && update-ca-certificates \
    && rm -f /usr/bin/bsondump /usr/bin/mongoexport /usr/bin/mongofiles \
        /usr/bin/mongoimport /usr/bin/mongostat /usr/bin/mongotop

# The compiled virtualenvs, without the toolchain that produced them. Their
# extensions link against acl, lz4, zstd, xxhash, openssl, libffi and libfuse3,
# all of which the runtime packages above provide.
COPY --from=borg-builder /opt/borg-ui-agent/borg1/venv /opt/borg-ui-agent/borg1/venv
COPY --from=borg-builder /opt/borg-ui-agent/borg2/venv /opt/borg-ui-agent/borg2/venv
COPY --from=s3fs-builder /out/usr/bin/s3fs /usr/bin/s3fs
COPY --from=etcd-fetch /out/usr/local/bin/ /usr/local/bin/
COPY --from=rclone-fetch /out/usr/bin/rclone /usr/bin/rclone
COPY --from=mysql-client /out/ /

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

# mongodb-admin (topology, dropping a database before a restore, reading an
# archive's prelude) speaks to MongoDB through pymongo: the image has no
# MongoDB shell, and mongosh would add a Node runtime. PyPI has no musl wheel
# of pymongo, so it is installed without its optional C extensions (NO_EXT),
# which only speed up BSON for large volumes. PyYAML reads the credentials
# file. Pinned, dnspython (pymongo's only dependency) included.
ARG PYMONGO_VERSION=4.18.3
ARG DNSPYTHON_VERSION=2.9.0
ARG PYYAML_VERSION=6.0.3
RUN python -m venv /opt/mongodb-admin/venv \
    && NO_EXT=1 /opt/mongodb-admin/venv/bin/pip install --no-cache-dir \
        "pymongo==${PYMONGO_VERSION}" "dnspython==${DNSPYTHON_VERSION}" "PyYAML==${PYYAML_VERSION}"

# Agent config dir; config.toml is written by `borg-ui-agent register`. The whole
# image runs as root, so no service user or sudo is needed.
RUN install -d -m 0750 /etc/borg-ui-agent

COPY docker/rootfs/ /
RUN chmod 0755 /entrypoint.sh /run-agent.sh /prepare-repo-server.sh /run-repo-server.sh \
        /usr/local/bin/* \
        /usr/local/libexec/borg-ui-agent-bin/*

# Explicit HOME so `~` resolves to /root everywhere (the agent, borg's
# cache/security dirs, and ~/.ssh).
ENV HOME=/root
# Default common params injected by the borg/borg2 wrappers — empty by default,
# set per deployment. E.g. a Hetzner Storage Box reached by Borg 1 over ssh://
# needs `--remote-path=borg-1.4` to pick its server-side Borg; Borg 2 over
# sftp:// needs nothing.
ENV BORG1_DEFAULT_PARAMS=""
ENV BORG2_DEFAULT_PARAMS=""
# Borg 2.0.0b23's pack cache: borgstore serves archive metadata as whole-pack
# loads, so on remote repositories every listing re-transfers packs; the
# writethrough cache under ~/.cache/borg (persisted in our deployments)
# downloads each pack once. Set at image level so interactive shells and the
# wrapper scripts get it too — the borg-ui-agent only defaults it for the
# processes it spawns itself. Pod env overrides both values; BORG_STORE_CACHE=""
# disables the cache. Borg 1 ignores them.
ENV BORG_STORE_CACHE=1
ENV BORG_PACK_CACHE_SIZE=2147483648

# Build-time self-test: both Borg majors (via the wrappers), s3fs, the etcd
# client, both MySQL clients, the MongoDB tools, valkey-cli and the agent CLI
# must work, or the build fails.
RUN borg --version \
    && borg2 --version \
    && s3fs --version \
    && etcdctl version \
    && etcdutl version \
    && /opt/mysql/bin/mysql --version \
    && /opt/mysql/bin/mysqldump --version \
    && test -e /usr/lib/mariadb/plugin/caching_sha2_password.so \
    && mongodump --version \
    && mongorestore --version \
    && mongodb-admin --help >/dev/null \
    && valkey-cli --version \
    && borg-ui-agent --help >/dev/null

# The repository server's sshd_config must parse with the OpenSSH this image
# installed: an option a release no longer knows stops sshd at start.
RUN ssh-keygen -q -t ed25519 -N "" -f /tmp/selftest_key \
    && /usr/sbin/sshd -t -f /etc/borg-repo-server/sshd_config -h /tmp/selftest_key \
    && rm -f /tmp/selftest_key /tmp/selftest_key.pub

WORKDIR /root

LABEL org.opencontainers.image.title="k8s-borg agent"
LABEL org.opencontainers.image.description="Borg UI managed-agent image for k8s-borg (Borg 1.x + Borg 2.x)"
LABEL org.opencontainers.image.source="https://github.com/ioanalytica/k8s-borg"

ENTRYPOINT ["/entrypoint.sh"]
CMD ["borg-ui-agent", "--help"]
