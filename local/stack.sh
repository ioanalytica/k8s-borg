#!/usr/bin/env bash
#
# stack.sh — build Borg UI and the agent image from a source tree and run them
# locally: server, PostgreSQL, Redis, repository server and one managed agent.
# No tag, no chart version, no registry. See README.md.
#
#   ./stack.sh build [SRC]    build both images from SRC (default: ../borg-ui)
#   ./stack.sh up             start the stack (builds first if an image is missing)
#   ./stack.sh target         start the bare Debian machine for install.sh tests
#   ./stack.sh status         what runs, from which commit
#   ./stack.sh logs [SVC…]    follow the logs
#   ./stack.sh sh SVC         a shell in a service's container
#   ./stack.sh token [NAME]   mint an enrollment token (for an agent outside the stack)
#   ./stack.sh down           stop; data stays
#   ./stack.sh reset          stop and delete all data (database, repositories, enrollment)
#
# SRC is any borg-ui checkout: the submodule, a scratch clone, a PR head. Only
# committed and uncommitted files of that directory count; nothing is fetched.
#
# Requires: docker (buildx, compose), ssh-keygen, openssl.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STATE="$HERE/.state"
UI_IMAGE="k8s-borg-ui:local"
AGENT_IMAGE="k8s-borg:local"
TARGET_IMAGE="borg-local-target:latest"
BASE_REPO="ghcr.io/ioanalytica/k8s-borg-ui-runtime-base"

die() { echo "✗ $*" >&2; exit 1; }
compose() { docker compose -f "$HERE/compose.yaml" --project-directory "$HERE" "$@"; }

# --- keys and certificates ----------------------------------------------------
# Created once and kept: the agent's enrollment and the clients' known_hosts
# refer to them.
ensure_state() {
  install -d -m 0700 "$STATE" "$STATE/ssh" "$STATE/tls"

  if [ ! -f "$STATE/ssh/id_ed25519" ]; then
    # The comment names the client on the repository server: its directory.
    ssh-keygen -q -t ed25519 -N "" -C "local" -f "$STATE/ssh/id_ed25519"
    ssh-keygen -q -t ed25519 -N "" -C "" -f "$STATE/ssh/ssh_host_ed25519_key"
    cp "$STATE/ssh/id_ed25519.pub" "$STATE/ssh/authorized_keys"
  fi

  if [ ! -f "$STATE/tls/server.crt" ]; then
    # A private CA and a server certificate signed by it: what a server behind
    # a self-signed or company certificate looks like to a client.
    openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
      -subj "/CN=borg-local test CA" \
      -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -keyout "$STATE/tls/ca.key" -out "$STATE/tls/ca.crt" 2>/dev/null
    openssl req -newkey rsa:2048 -nodes -subj "/CN=server-tls" \
      -keyout "$STATE/tls/server.key" -out "$STATE/tls/server.csr" 2>/dev/null
    # TLS_EXTRA_SAN adds the name a machine outside the stack uses for this
    # host, e.g. TLS_EXTRA_SAN=DNS:mac.local,IP:10.211.55.2
    printf 'subjectAltName=DNS:server-tls,DNS:localhost,IP:127.0.0.1%s\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n' \
      "${TLS_EXTRA_SAN:+,$TLS_EXTRA_SAN}" >"$STATE/tls/server.ext"
    openssl x509 -req -days 825 -in "$STATE/tls/server.csr" \
      -CA "$STATE/tls/ca.crt" -CAkey "$STATE/tls/ca.key" -CAcreateserial \
      -extfile "$STATE/tls/server.ext" -out "$STATE/tls/server.crt" 2>/dev/null
    # Caddy runs as root in its container, the key is read through a bind mount.
    chmod 0644 "$STATE/tls/server.key"
  fi
}

# --- build ----------------------------------------------------------------------
build() {
  local src="${1:-$ROOT/borg-ui}"
  src="$(cd "$src" 2>/dev/null && pwd)" || die "no such directory: ${1:-}"
  [ -f "$src/pyproject.toml" ] && [ -d "$src/frontend" ] || die "$src is not a borg-ui checkout"

  local commit app_version base_tag base
  commit="$(git -C "$src" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  git -C "$src" diff --quiet HEAD 2>/dev/null || commit="$commit+dirty"
  app_version="$(tr -d '[:space:]' <"$src/VERSION")-local.$commit"
  base_tag="$("$src/docker/runtime-base-tag.sh")"
  base="${BASE_IMAGE:-$BASE_REPO:$base_tag}"
  # shellcheck disable=SC1091
  PYTHON_VERSION="$(. "$src/docker/runtime-base.env" && echo "$PYTHON_VERSION")"

  echo "▶ source  : $src ($commit)"
  echo "▶ version : $app_version, agent $(sed -n 's/^version = "\(.*\)"/\1/p' "$src/pyproject.toml")"
  echo "▶ base    : $base"

  if ! docker image inspect "$base" >/dev/null 2>&1; then
    echo "▶ the runtime base is not here yet, pulling it"
    docker pull "$base" || die "no runtime base $base_tag, locally or in the registry.
  Build it from this source first:
    docker buildx build --load -f \"$src/Dockerfile.runtime-base\" -t \"$base\" \\
      \$(sed -n 's/^\\([A-Z0-9_]*\\)=\\(.*\\)/--build-arg \\1=\\2/p' \"$src/docker/runtime-base.env\") \"$src/docker\""
  fi

  echo "▶ building $UI_IMAGE"
  docker buildx build --load \
    -f "$src/Dockerfile" \
    --build-arg "BASE_IMAGE=$base" \
    --build-arg "APP_VERSION=$app_version" \
    --build-arg "PYTHON_VERSION=$PYTHON_VERSION" \
    --label "local.borg.source=$src" --label "local.borg.commit=$commit" \
    -t "$UI_IMAGE" "$src"

  # docker/Dockerfile copies borg-ui/… from the repository root. A context of
  # its own, with the few files it reads taken from SRC, builds the same recipe
  # from any checkout without touching the submodule.
  local ctx="$STATE/agent-context"
  rm -rf "$ctx"
  install -d "$ctx/borg-ui/app/api" "$ctx/borg-ui/docker"
  cp -R "$ROOT/docker" "$ctx/docker"
  cp "$src/pyproject.toml" "$ctx/borg-ui/"
  cp -R "$src/agent" "$ctx/borg-ui/agent"
  cp "$src/app/api/borg_binaries.json" "$ctx/borg-ui/app/api/"
  cp "$src/docker/runtime-base.env" "$ctx/borg-ui/docker/"

  echo "▶ building $AGENT_IMAGE"
  docker buildx build --load \
    -f "$ctx/docker/Dockerfile" \
    --build-arg "PYTHON_VERSION=$PYTHON_VERSION" \
    --label "local.borg.source=$src" --label "local.borg.commit=$commit" \
    -t "$AGENT_IMAGE" "$ctx"

  echo "✓ built $UI_IMAGE and $AGENT_IMAGE from $commit"
}

have_images() {
  docker image inspect "$UI_IMAGE" >/dev/null 2>&1 && docker image inspect "$AGENT_IMAGE" >/dev/null 2>&1
}

image_commit() { docker image inspect -f '{{ index .Config.Labels "local.borg.commit" }}' "$1" 2>/dev/null || echo "-"; }

# --- commands -------------------------------------------------------------------
cmd="${1:-}"
[ $# -gt 0 ] && shift
docker info >/dev/null 2>&1 || die "docker is not available — start Docker and retry"

case "$cmd" in
  build)
    ensure_state
    build "${1:-}"
    ;;
  up)
    ensure_state
    have_images || build ""
    # --force-recreate: the tag stays the same across builds, so a running
    # container would otherwise keep the image it was started from.
    compose up -d --force-recreate --wait server repo-server server-tls
    compose up -d --force-recreate agent
    echo
    echo "✓ Borg UI      http://localhost:${SERVER_PORT:-8081}   (admin / ${ADMIN_PASSWORD:-local-admin})"
    echo "  with TLS     https://localhost:${SERVER_TLS_PORT:-8443}  (CA: $STATE/tls/ca.crt)"
    echo "  repositories ssh://borg@localhost:${REPO_SERVER_PORT:-2222}/local/<name>  (key: $STATE/ssh/id_ed25519)"
    echo "  agent        ./stack.sh logs agent"
    ;;
  target)
    ensure_state
    docker build -q -f "$HERE/target.Dockerfile" -t "$TARGET_IMAGE" "$HERE" >/dev/null
    compose --profile target up -d --force-recreate target
    echo "✓ target-1 is up: ./stack.sh sh target"
    echo "  the server from there: http://server:8081 and https://server-tls:8443 (CA in /local/ca.crt)"
    ;;
  status)
    echo "images: $UI_IMAGE ($(image_commit "$UI_IMAGE")), $AGENT_IMAGE ($(image_commit "$AGENT_IMAGE"))"
    compose --profile target ps
    ;;
  logs)
    compose --profile target logs -f --tail 100 "$@"
    ;;
  sh)
    [ $# -ge 1 ] || die "usage: ./stack.sh sh SERVICE"
    compose --profile target exec "$1" sh -c 'command -v bash >/dev/null && exec bash || exec sh'
    ;;
  token)
    name="${1:-manual-agent}"
    base="http://localhost:${SERVER_PORT:-8081}"
    jwt="$(curl -fsS -X POST "$base/api/auth/login" \
      --data-urlencode "username=admin" --data-urlencode "password=${ADMIN_PASSWORD:-local-admin}" \
      | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')" || die "admin login failed"
    curl -fsS -X POST "$base/api/managed-machines/enrollment-tokens" \
      -H "Authorization: Bearer $jwt" -H "Content-Type: application/json" \
      -d "{\"name\":\"$name\",\"expires_in_minutes\":60}" \
      | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])'
    ;;
  down)
    compose --profile target down
    ;;
  reset)
    compose --profile target down -v
    echo "✓ all data of the stack is gone; keys and certificates in $STATE stay"
    ;;
  *)
    sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    [ -z "$cmd" ] || exit 1
    ;;
esac
