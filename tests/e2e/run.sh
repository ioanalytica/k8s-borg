#!/usr/bin/env bash
#
# Build the agent image, layer bats and the tests on top, and run the suite once
# per Borg major inside the container.
#
#   ./tests/e2e/run.sh              # build + run both majors
#   ./tests/e2e/run.sh 2            # only Borg 2
#   IMAGE=k8s-borg:test ./tests/e2e/run.sh   # reuse an already built image
#
# FUSE is required (borg-mount). The container needs /dev/fuse and CAP_SYS_ADMIN;
# the host OS does not matter, since on macOS and Windows Docker runs the
# container inside a Linux VM that provides both.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

IMAGE="${IMAGE:-k8s-borg:test}"
E2E_IMAGE="${E2E_IMAGE:-k8s-borg:e2e}"
read -r -a versions <<<"${*:-1 2}"

if ! docker info >/dev/null 2>&1; then
  echo "✗ docker is not available — start Docker and retry" >&2
  exit 1
fi

if [ -z "${SKIP_BUILD:-}" ]; then
  echo "▶ building $IMAGE"
  docker build -f docker/Dockerfile -t "$IMAGE" .
fi

echo "▶ building $E2E_IMAGE (test layer)"
docker build -f tests/e2e/Dockerfile --build-arg "BASE=$IMAGE" -t "$E2E_IMAGE" .

# borg-mount is part of the suite, so a container without working FUSE would
# report a product failure that is really a harness failure. Check it up front
# and say so plainly.
fuse_flags=(--device /dev/fuse --cap-add SYS_ADMIN --security-opt apparmor=unconfined)
if ! docker run --rm "${fuse_flags[@]}" "$E2E_IMAGE" test -c /dev/fuse; then
  echo "✗ /dev/fuse is not usable in the container — borg-mount cannot be tested." >&2
  echo "  On a Linux host: modprobe fuse. In CI: the runner image must expose /dev/fuse." >&2
  exit 1
fi

rc=0
for v in "${versions[@]}"; do
  echo "▶ e2e suite, Borg $v"
  docker run --rm "${fuse_flags[@]}" \
    -e "BORG_TEST_VERSION=$v" \
    -e "BATS_TEST_NAME_PREFIX=borg$v: " \
    "$E2E_IMAGE" || rc=1
done

[ "$rc" -eq 0 ] && echo "✓ e2e suite passed" || echo "✗ e2e suite failed" >&2
exit "$rc"
