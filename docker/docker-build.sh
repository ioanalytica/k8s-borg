#!/usr/bin/env bash
#
# docker-build.sh — build the k8s-borg AGENT image from the pinned borg-ui
# submodule (same commit as the server → server/agent lockstep).
#   ->  ghcr.io/ioanalytica/k8s-borg
#
# Build context = the repo root (the Dockerfile COPYs borg-ui/ and docker/rootfs/
# from there). By default builds for the host arch, --load into the local docker
# and runs the self-test entry point. PUSH=1 (or --push) builds multi-arch and
# pushes to GHCR — same recipe as docker-build-runtime-base.sh / docker-build-server.sh.
# CI (.github/workflows/docker-build.yml) also builds + pushes on tag pushes.
#
# Usage:
#   ./docker-build.sh [tag]           # local build (host arch, --load) + self-test
#   PUSH=1 ./docker-build.sh [tag]    # multi-arch build + push to GHCR
#   ./docker-build.sh --push [tag]    #  (equivalent)
#   (default tag: local)
#
# Requires: docker (buildx). No host build tools.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root == build context
SUB="$ROOT/borg-ui"
IMAGE="ghcr.io/ioanalytica/k8s-borg"
PUSH="${PUSH:-0}"

# ensure we have history + tags
TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
[ -n "$TAG" ] || TAG="local"   # fallback if no tag at all

for arg in "$@"; do
  case "$arg" in
    --push)     PUSH=1 ;;
    --no-push)  PUSH=0 ;;
    -*)         echo "WARN: unknown argument '$arg' ignored" >&2 ;;
    *)          TAG="$arg" ;;
  esac
done
REF="${IMAGE}:${TAG}"

[ -f "$SUB/pyproject.toml" ] || {
  echo "✗ borg-ui submodule not initialized at $SUB — run: git submodule update --init" >&2
  exit 1
}

echo "▶ k8s-borg agent build"
echo "   submodule commit : $(git -C "$SUB" rev-parse --short HEAD)"
echo "   image tag        : $REF"
echo "   push             : $PUSH"

COMMON=(
  -f "$ROOT/docker/Dockerfile"
  -t "$REF"
)

if [ "$PUSH" = "1" ]; then
  echo "▶ multi-arch build + push …"
  docker buildx build --platform linux/amd64,linux/arm64 "${COMMON[@]}" --push "$ROOT"
  echo "✓ pushed $REF"
  exit 0
fi

echo "▶ local build (host arch, --load) …"
docker buildx build "${COMMON[@]}" --load "$ROOT"
echo "✓ built $REF (local)"

echo "▶ self-test …"
docker run --rm "$REF"
echo "✓ self-test passed — $REF"
