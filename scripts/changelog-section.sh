#!/usr/bin/env bash
#
# Print the CHANGELOG.md entry of one version: the lines below its "## VERSION"
# heading up to the next "## " heading, without the heading and the blank lines
# around the entry. A prerelease without a section of its own prints the entry
# of its release (1.3.4-rc.1: "## 1.3.4"): it is tagged on the commit its
# release will be tagged on, and that commit's CHANGELOG.md has one section,
# the release's. A version with no section prints nothing, and the release then
# carries GitHub's generated notes alone.
#
# The release job of build.yml puts this in front of those generated notes, so
# a release page shows what changed, not only the pull requests that changed it.
#
#   scripts/changelog-section.sh 1.2.3 [CHANGELOG.md]
set -euo pipefail

version="${1:-}"
[ -n "$version" ] || { echo "usage: changelog-section.sh VERSION [FILE]" >&2; exit 2; }
file="${2:-$(dirname "${BASH_SOURCE[0]}")/../CHANGELOG.md}"

if [[ "$version" == *-* ]] && ! grep -qxF "## $version" "$file"; then
  version="${version%%-*}"
fi

awk -v want="## $version" '
  $0 == want { inside = 1; next }
  inside && /^## / { exit }
  inside { lines[++n] = $0 }
  END {
    first = 1; while (first <= n && lines[first] == "") first++
    last = n;  while (last >= first && lines[last] == "") last--
    for (i = first; i <= last; i++) print lines[i]
  }
' "$file"
