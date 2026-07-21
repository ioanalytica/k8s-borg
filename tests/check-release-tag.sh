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
#   ./tests/check-release-tag.sh 1.1.2
set -euo pipefail

tag="${1:-}"
[ -n "$tag" ] || { echo "usage: check-release-tag.sh TAG" >&2; exit 2; }

# The same extractor the version tests pin, rather than a second copy of the
# parsing that could drift away from it.
# shellcheck source=helpers/versions.bash
. "$(dirname "${BASH_SOURCE[0]}")/helpers/versions.bash"

want="$(chart_version)"
[ -n "$want" ] || { echo "✗ no version: found in chart/Chart.yaml" >&2; exit 1; }

if [ "$tag" != "$want" ]; then
  {
    echo "✗ release tag '$tag' does not match chart/Chart.yaml version '$want'"
    echo
    echo "  Bump chart/Chart.yaml before tagging — version, appVersion, and the"
    echo "  k8s-borg entry under annotations.images. Publishing as-is would"
    echo "  package $want again and overwrite the chart already published under"
    echo "  that version."
  } >&2
  exit 1
fi

echo "✓ release tag '$tag' matches chart/Chart.yaml"
