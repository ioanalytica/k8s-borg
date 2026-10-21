#!/usr/bin/env bash
#
# agent-version-stamp.sh — the fourth version component the managed agent gets
# in images built from the pinned borg-ui submodule, or nothing.
#
#   ./docker/agent-version-stamp.sh   # prints e.g. 62, or an empty line
#
# Borg UI versions the agent at release time only (karanhudia/borg-ui#1415):
# release.sh bumps its patch version when agent/ or pyproject.toml changed
# since the last release tag. A pin between two releases therefore carries new
# agent code under the previous release's version, and the server, which
# offers an upgrade only to agents reporting a different version than the
# wheel it serves, would leave every enrolled agent on its old code. Upstream's
# own edge images stamp X.Y.Z.<run number> for that reason; ours stamp the pin's
# `git describe` distance, the number the UI image tag already carries
# (2.3.10-62-ga7219d4d6 -> agent 0.1.21.62). That sorts after the release it
# builds on and before the next one, and the same pin always gets the same one.
#
# No stamp, and the plain release version, when
#   - the pin is a release tag (distance 0),
#   - agent/ and pyproject.toml are unchanged since that tag, so a pin move
#     offers no upgrade that changes nothing, or
#   - the pin predates scripts/agent_version.py, which applies the stamp; until
#     then every agent PR moved the version itself.
#
# Both image builds apply this one result (`agent_version.py edge <n>` on their
# checkout, see build-image.yml), so the wheel the server offers and the
# version the agent reports are the same string.
#
# Reads the commit, not the working tree, and needs borg-ui's release tags:
# run ./docker/ui-app-version.sh --fetch-tags first. Without a reachable tag it
# fails instead of guessing. BORG_UI_DIR points it at another checkout (tests).
set -euo pipefail

SUB="${BORG_UI_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/borg-ui}"

[ -e "$SUB/.git" ] || { echo "✗ borg-ui checkout not found at $SUB" >&2; exit 1; }
[ $# -eq 0 ] || { echo "usage: agent-version-stamp.sh" >&2; exit 2; }

# --long gives the distance at a tag too (v2.3.10-0-g…); the tag pattern and
# abbreviation are ui-app-version.sh's, so the distance is the one in the UI tag.
if ! described="$(git -C "$SUB" describe --tags --match 'v[0-9]*' --long --abbrev=9 HEAD 2>/dev/null)"; then
  echo "✗ no borg-ui release tag (v*) reachable from $(git -C "$SUB" rev-parse --short HEAD)" >&2
  echo "  run: $(dirname "$0")/ui-app-version.sh --fetch-tags" >&2
  exit 1
fi
rest="${described%-g*}"     # v2.3.10-62
distance="${rest##*-}"      # 62
tag="${rest%-*}"            # v2.3.10

version="$(git -C "$SUB" show HEAD:pyproject.toml | sed -n 's/^version = "\(.*\)"$/\1/p' | head -n 1)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "✗ borg-ui pyproject.toml: agent version '$version' is not X.Y.Z" >&2; exit 1; }

no_stamp() { echo "agent $version (no stamp: $1)" >&2; echo; exit 0; }

[ "$distance" -gt 0 ] || no_stamp "the pin is release tag $tag"
git -C "$SUB" cat-file -e HEAD:scripts/agent_version.py 2>/dev/null \
  || no_stamp "the pin predates scripts/agent_version.py"
rc=0
git -C "$SUB" diff --quiet "$tag" HEAD -- agent/ pyproject.toml || rc=$?
case "$rc" in
  0) no_stamp "agent/ and pyproject.toml unchanged since $tag" ;;
  1) ;;
  *) echo "✗ git diff $tag HEAD failed in $SUB" >&2; exit 1 ;;
esac

echo "agent $version.$distance (agent/ changed since $tag)" >&2
echo "$distance"
