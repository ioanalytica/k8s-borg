#!/usr/bin/env bash
#
# Fail a release build whose git tag does not match the chart version.
#
# The two reach the published artifacts by different routes: image tags come
# from the git tag (docker/metadata-action), the chart version comes from
# chart/Chart.yaml. Nothing used to check that they agree, and a mismatch does
# not fail anything on its own — the build cheerfully packages the version in
# the file and pushes it, overwriting the already published chart of that
# version and attaching it to the new release. Tag 1.1.2 shipped that way: a
# release named 1.1.2 carrying k8s-borg-1.1.1.tgz, and no 1.1.2 chart anywhere.
#
# A prerelease of the chart's version passes too: X.Y.Z-rc.1 goes on the commit
# whose chart/Chart.yaml says X.Y.Z, the one X.Y.Z is tagged on once the
# prerelease passed, and the build packages the chart at the tag's version
# (scripts/chart-release-version.sh).
#
#   ./tests/check-release-tag.sh 1.1.2
#   ./tests/check-release-tag.sh 1.1.2-rc.1
set -euo pipefail

tag="${1:-}"
[ -n "$tag" ] || { echo "usage: check-release-tag.sh TAG" >&2; exit 2; }

# The same extractor the version tests pin, rather than a second copy of the
# parsing that could drift away from it.
# shellcheck source=helpers/versions.bash
. "$(dirname "${BASH_SOURCE[0]}")/helpers/versions.bash"

want="$(chart_version)"
[ -n "$want" ] || { echo "✗ no version: found in chart/Chart.yaml" >&2; exit 1; }

if [ "$tag" = "$want" ]; then
  echo "✓ release tag '$tag' matches chart/Chart.yaml"
  exit 0
fi
# The suffix in SemVer's characters, of a version that has none itself.
suffix="${tag#"$want"-}"
if [[ "$want" != *-* && "$tag" == "$want"-?* && "$suffix" =~ ^[0-9A-Za-z.-]+$ ]]; then
  echo "✓ release tag '$tag' is a prerelease of chart/Chart.yaml's $want"
  exit 0
fi

{
  echo "✗ release tag '$tag' does not match chart/Chart.yaml version '$want'"
  echo
  echo "  Tag $want, or a prerelease of it ($want-rc.1), on the commit whose"
  echo "  chart/Chart.yaml says $want. For another version, bump chart/Chart.yaml"
  echo "  first: version, appVersion, and the k8s-borg entry of"
  echo "  artifacthub.io/images. Publishing as-is would package $want again and"
  echo "  overwrite the chart already published under that version."
} >&2
exit 1
