#!/usr/bin/env bash

set -euo pipefail

# ensure we have history + tags
TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
[ -n "$TAG" ] || TAG="1.0.0"   # fallback if no tag at all

echo "Using tag: $TAG"

# Docker tag friendly (no '+')
PROD_IMAGE="harbor.ioanalytica.com/io/devops/k3s-borg:${TAG}"

echo "Linting Dockerfile …"
# hadolint Dockerfile

echo "Building ${PROD_IMAGE} …"
docker buildx build --platform linux/amd64,linux/arm64 -t ${PROD_IMAGE} . --push

# end
