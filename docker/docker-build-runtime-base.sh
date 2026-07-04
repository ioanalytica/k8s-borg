#!/usr/bin/env bash
#
# docker-build-runtime-base.sh — build our own Borg UI runtime base
# (versions tracked from upstream's docker/runtime-base.env) from
# Dockerfile-runtime-base.
#   ->  ghcr.io/ioanalytica/k8s-borg-ui-runtime-base
#
# Usage:
#   ./docker-build-runtime-base.sh          # local build (host arch, --load) + smoke test
#   PUSH=1 ./docker-build-runtime-base.sh   # multi-arch build + push to GHCR
#
# Requires: docker (buildx). No host build tools — everything runs in the image.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB="$(cd "$ROOT/.." && pwd)/borg-ui"   # submodule lives at the repo root, one level above docker/
IMAGE="ghcr.io/ioanalytica/k8s-borg-ui-runtime-base"
# Adopt upstream's EXACT pins (borg1/borg2 + tag) from the submodule, so we stay
# in lockstep and a future upstream PR carries no version noise.
# shellcheck disable=SC1091
source "$SUB/docker/runtime-base.env"   # BORG1_VERSION, BORG2_VERSION, BORG_RUNTIME_BASE_TAG
BORGSTORE_VERSION="${BORGSTORE_VERSION:-0.4.1}"   # upstream hardcodes this in Dockerfile.runtime-base
TAG="${IMAGE}:${BORG_RUNTIME_BASE_TAG}"
PUSH="${PUSH:-0}"
SUB_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --push)        PUSH=1; SUB_ARGS+=(--push) ;;
    --no-push)     PUSH=0; SUB_ARGS+=(--no-push) ;;
    -y|--yes)      ASSUME_YES=1 ;;
    *) echo "WARN: unknown argument '$arg' ignored" >&2 ;;
  esac
done

echo "▶ runtime base build"
echo "   borg1 : $BORG1_VERSION"
echo "   borg2 : $BORG2_VERSION"
echo "   store : $BORGSTORE_VERSION"
echo "   tag   : $TAG"
echo "   push  : $PUSH"

# Dockerfile-runtime-base has no COPY — build with an empty context so nothing
# is shipped to the daemon.
CTX="$(mktemp -d)"
trap 'rm -rf "$CTX"' EXIT

BUILD_ARGS=(
  --build-arg "BORG1_VERSION=${BORG1_VERSION}"
  --build-arg "BORG2_VERSION=${BORG2_VERSION}"
  --build-arg "BORGSTORE_VERSION=${BORGSTORE_VERSION}"
)

if [ "$PUSH" = "1" ]; then
  echo "▶ multi-arch build + push …"
  docker buildx build --platform linux/amd64,linux/arm64 \
    -f "$ROOT/Dockerfile-runtime-base" \
    "${BUILD_ARGS[@]}" \
    -t "$TAG" --push \
    "$CTX"
  echo "✓ pushed $TAG"
  exit 0
fi

echo "▶ local build (host arch, --load) …"
docker buildx build \
  -f "$ROOT/Dockerfile-runtime-base" \
  "${BUILD_ARGS[@]}" \
  -t "$TAG" --load \
  "$CTX"
echo "✓ built $TAG (local)"

echo "▶ smoke test (versions + runtime-lib check via C-extension import) …"
docker run --rm "$TAG" borg  --version
docker run --rm "$TAG" borg2 --version
docker run --rm "$TAG" btrfs --version
docker run --rm "$TAG" python3 -c "import pyfuse3; print('pyfuse3 ok')"
docker run --rm "$TAG" python3 -c "import borg.crypto.low_level, borg.compress; print('borg1 C-ext ok (libcrypto/liblz4/libzstd present)')"
docker run --rm "$TAG" /opt/borg2-venv/bin/python -c "import borg.crypto.low_level, borg.compress; import importlib.metadata as m; print('borg2 C-ext ok, borgstore', m.version('borgstore'))"
echo "✓ smoke test passed — $TAG"
