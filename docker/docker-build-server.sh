#!/usr/bin/env bash
#
# docker-build-server.sh — build the hermetic Borg UI SERVER image from the
# pinned borg-ui submodule (same commit as the agent → server/agent lockstep).
#   ->  ghcr.io/ioanalytica/k8s-borg-ui
#
# Built from the submodule's borg-ui/Dockerfile (no fork copy of the recipe),
# under our own tag. The frontend is built INSIDE that Dockerfile (no host npm,
# no staged artifact). FROM our own runtime base — build that first:
#   ./docker-build-runtime-base.sh
#
# Usage:
#   ./docker-build-server.sh          # local build (host arch, --load) + smoke test
#   PUSH=1 ./docker-build-server.sh   # multi-arch build + push to GHCR
#
# Requires: docker (buildx). No host build tools.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB="$(cd "$ROOT/.." && pwd)/borg-ui"   # submodule lives at the repo root, one level above docker/
IMAGE="ghcr.io/ioanalytica/k8s-borg-ui"
# The base tag is computed from the submodule's runtime-base.env (single source),
# so server and base stay in lockstep without a stored tag to drift.
# shellcheck disable=SC1091
source "$SUB/docker/runtime-base.env"   # PYTHON_VERSION (+ versions for the tag helper)
BASE_IMAGE="${BASE_IMAGE:-ghcr.io/ioanalytica/k8s-borg-ui-runtime-base:$("$SUB/docker/runtime-base-tag.sh")}"
PUSH="${PUSH:-0}"
SUB_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --push)        PUSH=1; SUB_ARGS+=(--push) ;;
    --no-push)     PUSH=0; SUB_ARGS+=(--no-push) ;;
    -y|--yes)      ;;   # accepted as a no-op: this script never prompts
    *) echo "WARN: unknown argument '$arg' ignored" >&2 ;;
  esac
done

[ -d "$SUB/frontend" ] || { echo "✗ borg-ui submodule not initialized at $SUB"; exit 1; }

APP_VERSION="$(git -C "$SUB" tag -l 'v*' | grep -vE '\-(alpha|beta|rc)' | sort -V | tail -1 | sed 's/^v//')"
[ -n "$APP_VERSION" ] || APP_VERSION="$(cat "$SUB/VERSION")"
TAG="${IMAGE}:${APP_VERSION}"

echo "▶ k8s-borg-ui server build (hermetic)"
echo "   submodule commit : $(git -C "$SUB" rev-parse --short HEAD)"
echo "   app version      : $APP_VERSION"
echo "   base image       : $BASE_IMAGE"
echo "   image tag        : $TAG"
echo "   push             : $PUSH"

COMMON=(
  -f "$SUB/Dockerfile"
  --build-arg "BASE_IMAGE=${BASE_IMAGE}"
  --build-arg "APP_VERSION=${APP_VERSION}"
  --build-arg "PYTHON_VERSION=${PYTHON_VERSION}"
  # Override the submodule's upstream labels so the published image is ours.
  --label "org.opencontainers.image.source=https://github.com/ioanalytica/k8s-borg"
  --label "org.opencontainers.image.title=k8s-borg-ui"
  -t "$TAG"
)

if [ "$PUSH" = "1" ]; then
  echo "▶ multi-arch build + push …"
  docker buildx build --platform linux/amd64,linux/arm64 "${COMMON[@]}" --push "$SUB"
  echo "✓ pushed $TAG"
  exit 0
fi

echo "▶ local build (host arch, --load) …"
docker buildx build "${COMMON[@]}" --load "$SUB"
echo "✓ built $TAG (local)"

echo "▶ smoke test …"
NAME=k8s-borg-ui-smoke
docker rm -f "$NAME" >/dev/null 2>&1 || true
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT
docker run -d --rm --name "$NAME" \
  -p 18081:8081 \
  -e PORT=8081 \
  -e SECRET_KEY=test-secret-key-local \
  -e ENABLE_STARTUP_LICENSE_SYNC=false \
  -e ACTIVATION_SERVICE_URL= \
  "$TAG" >/dev/null

echo "   waiting for http://127.0.0.1:18081/ …"
tries=0
until curl -fsS http://127.0.0.1:18081/ >/dev/null 2>&1; do
  tries=$((tries + 1))
  if [ "$tries" -ge 30 ]; then
    echo "   ✗ server did not come up within ~60s — last logs:"
    docker logs "$NAME" 2>&1 | tail -40
    exit 1
  fi
  sleep 2
done
echo "   ✓ HTTP up"
docker exec "$NAME" borg  --version || true
docker exec "$NAME" borg2 --version || true
echo "✓ smoke test passed — $TAG"
