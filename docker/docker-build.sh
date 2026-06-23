#!/usr/bin/env bash
# Local build helper for testing the k8s-borg agent image.
#
# CI (.github/workflows/docker-build.yml) builds and pushes multi-arch images
# to ghcr.io on tag pushes. This script is only for local verification: it
# builds for the host architecture, loads the image into the local docker, and
# runs the self-test entry point.
#
# Usage: docker/docker-build.sh [tag]   (default tag: local)
set -euo pipefail

cd "$(dirname "$0")/.."   # repository root == build context

TAG="${1:-local}"
IMAGE="k8s-borg:${TAG}"

if [ ! -f borg-ui/pyproject.toml ]; then
  echo "borg-ui submodule is not checked out. Run:" >&2
  echo "  git submodule update --init" >&2
  exit 1
fi

echo "Building ${IMAGE} for the host architecture …"
docker build -f docker/Dockerfile -t "${IMAGE}" .

echo
echo "Running self-test for ${IMAGE}:"
docker run --rm "${IMAGE}"
