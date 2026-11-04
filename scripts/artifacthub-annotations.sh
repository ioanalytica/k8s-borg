#!/usr/bin/env bash
#
# Add the per-version annotations Artifact Hub shows to the chart a release
# packages: artifacthub.io/changes, the lead sentences of the version's
# CHANGELOG.md entry, and artifacthub.io/prerelease, "true" for a version with
# a -suffix. The chart job of build.yml runs it on the checkout before
# `helm package`; chart/Chart.yaml in the repository never carries either key,
# and the script fails when it finds one, rather than write a second.
#
# A change is the bold lead of a bullet of the entry ("* **Lead.** More…"),
# or, for a bullet without one, its first sentence: up to a full stop that a
# capital letter follows, so "e.g. the" does not end it. Artifact Hub shows changes
# as plain text, so Markdown emphasis and code marks are dropped. Bullets under
# a "### Project and CI" heading are left out: they change the repository, not
# the chart or its images, and the Changelog link has them. A version with no
# CHANGELOG entry gets no changes annotation.
#
#   scripts/artifacthub-annotations.sh 1.3.0 [chart/Chart.yaml [CHANGELOG.md]]
set -euo pipefail

version="${1:-}"
[ -n "$version" ] || { echo "usage: artifacthub-annotations.sh VERSION [CHART_YAML [CHANGELOG]]" >&2; exit 2; }
here="$(dirname "${BASH_SOURCE[0]}")"
chart="${2:-$here/../chart/Chart.yaml}"
changelog="${3:-$here/../CHANGELOG.md}"

grep -qx 'annotations:' "$chart" || { echo "✗ $chart has no annotations: block" >&2; exit 1; }
for key in artifacthub.io/changes artifacthub.io/prerelease; do
  if grep -q "^  $key:" "$chart"; then
    echo "✗ $chart already has $key; a release writes it" >&2
    exit 1
  fi
done

# One change per line, then one double-quoted YAML list entry per change.
changes="$(
  "$here/changelog-section.sh" "$version" "$changelog" | awk '
    function flush(  d) {
      if (item == "") return
      if (match(item, /^\*\*[^*]+\*\*/)) {
        d = substr(item, 3, RLENGTH - 4)
      } else {
        d = item
        if (match(d, /[.!?] [A-Z]/)) d = substr(d, 1, RSTART)
      }
      gsub(/\*\*|`/, "", d)
      sub(/^ +/, "", d); sub(/ +$/, "", d)
      if (d != "") print d
      item = ""
    }
    /^### / { flush(); skip = ($0 == "### Project and CI"); next }
    /^[*-] / { flush(); if (!skip) item = substr($0, 3); next }
    /^  +[^ ]/ && item != "" { line = $0; sub(/^ +/, "", line); item = item " " line; next }
    { flush() }
    END { flush() }' \
  | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/- "/; s/$/"/'
)"

case "$version" in
  *-*) prerelease=true ;;
  *) prerelease=false ;;
esac

block="$(
  echo "  artifacthub.io/prerelease: \"$prerelease\""
  if [ -n "$changes" ]; then
    echo "  artifacthub.io/changes: |"
    sed 's/^/    /' <<<"$changes"
  fi
)"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
# ENVIRON, not -v: awk would read the escapes of the quoted changes.
BLOCK="$block" awk '{ print } $0 == "annotations:" { print ENVIRON["BLOCK"] }' "$chart" >"$tmp"
cat "$tmp" >"$chart"

echo "✓ $chart: prerelease $prerelease, $(grep -c . <<<"$changes" || true) changes from the $version entry"
