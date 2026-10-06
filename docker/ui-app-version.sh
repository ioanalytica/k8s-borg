#!/usr/bin/env bash
#
# ui-app-version.sh — the version of the pinned borg-ui submodule, which names
# the UI server image (ghcr.io/ioanalytica/k8s-borg-ui:<version>) and is its
# APP_VERSION build argument.
#
#   ./docker/ui-app-version.sh               # print it
#   ./docker/ui-app-version.sh --fetch-tags  # fetch borg-ui's release tags first
#
# It is `git describe` of the pinned commit against borg-ui's release tags,
# without the leading "v": 2.3.10 when the pin is exactly tag v2.3.10, and
# 2.3.10-27-gcdd5712c9 for a commit 27 commits past it. borg-ui/VERSION alone
# does not tell main commits apart — it said 2.3.10 for every commit since that
# release — and a tag reused for a different pin overwrites the image that the
# previous chart still points at, so no rollback reaches it any more.
#
# The submodule's remote is our fork, which carries no tags. --fetch-tags takes
# them from upstream (BORG_UI_UPSTREAM) and first completes a shallow history,
# since describe has to walk from the pin back to the tag. Without a reachable
# tag the script fails instead of falling back: a wrong image tag is what this
# replaces.
#
# Used by build.yml (the tag CI builds and pushes), docker-build-server.sh, and
# tests/chart-versions.bats (the tag the chart names), so the three cannot drift.
set -euo pipefail

SUB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/borg-ui"
UPSTREAM="${BORG_UI_UPSTREAM:-https://github.com/karanhudia/borg-ui.git}"

[ -e "$SUB/.git" ] || { echo "✗ borg-ui submodule not initialized at $SUB" >&2; exit 1; }

case "${1:-}" in
  "") ;;
  --fetch-tags)
    if [ "$(git -C "$SUB" rev-parse --is-shallow-repository)" = true ]; then
      git -C "$SUB" fetch --quiet --unshallow --no-tags "$UPSTREAM" HEAD
    fi
    git -C "$SUB" fetch --quiet --no-tags "$UPSTREAM" '+refs/tags/v*:refs/tags/v*'
    ;;
  *) echo "usage: ui-app-version.sh [--fetch-tags]" >&2; exit 2 ;;
esac

# A fixed --abbrev keeps the string the same in a full clone and in CI's
# checkout, whose object counts would otherwise pick different lengths.
if ! described="$(git -C "$SUB" describe --tags --match 'v[0-9]*' --abbrev=9 HEAD 2>/dev/null)"; then
  echo "✗ no borg-ui release tag (v*) reachable from $(git -C "$SUB" rev-parse --short HEAD)" >&2
  echo "  run: $0 --fetch-tags" >&2
  exit 1
fi
echo "${described#v}"
