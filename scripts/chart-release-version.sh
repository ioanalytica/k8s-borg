#!/usr/bin/env bash
#
# Give the chart a release packages the version of its tag. A prerelease is
# tagged on the commit its release will be tagged on (X.Y.Z-rc.1, then X.Y.Z on
# the same commit once the prerelease passed, so the release is the source the
# prerelease tested), and that commit's chart/Chart.yaml carries the release's
# version. The chart of the prerelease gets the tag's version as its version
# and appVersion, which names the agent image the tag built, and that image in
# artifacthub.io/images. For a release the file already says so and stays as
# it is. The chart job of build.yml runs it after check-release-tag.sh.
#
#   scripts/chart-release-version.sh 1.3.4-rc.1 [chart/Chart.yaml]
set -euo pipefail

version="${1:-}"
[ -n "$version" ] || { echo "usage: chart-release-version.sh VERSION [CHART_YAML]" >&2; exit 2; }
chart="${2:-$(dirname "${BASH_SOURCE[0]}")/../chart/Chart.yaml}"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
# Each of the three once, or the file is not the one this was written for.
if ! awk -v v="$version" '
  /^version: /    { print "version: " v; n++; next }
  /^appVersion: / { print "appVersion: \"" v "\""; n++; next }
  /^      image: ghcr\.io\/ioanalytica\/k8s-borg:/ { sub(/:[^:]*$/, ":" v); print; n++; next }
  { print }
  END { exit n != 3 }' "$chart" >"$tmp"; then
  echo "✗ $chart: expected version:, appVersion: and the k8s-borg image of artifacthub.io/images once each" >&2
  exit 1
fi
cat "$tmp" >"$chart"

echo "✓ $chart: version and appVersion $version"
