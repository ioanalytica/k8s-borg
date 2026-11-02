#!/usr/bin/env bash
#
# Read the paths a pull request changes, one per line, and succeed only when
# every one of them is documentation: then Lint & test skips its end-to-end
# jobs, which test the images and the chart, not these files. Any other path
# fails, and so does an empty list — when in doubt, everything runs.
#
# Documentation is
#   *.md at the top level   README.md, CHANGELOG.md, CONTRIBUTING.md, ...
#   LICENSE
#   examples/               the Helm example; examples-helm.bats checks it,
#                           and the unit tests are never skipped
#
# A Markdown file anywhere else is not: chart/README.md ships in the chart,
# and docker/, chart/, tests/, scripts/ and .github/ hold what the suites test
# and how they run. The borg-ui submodule is the one path `borg-ui`.
#
#   git diff --no-renames --name-only BASE HEAD | scripts/docs-only.sh
set -euo pipefail

n=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  n=$((n + 1))
  case "$path" in
    LICENSE | examples/*) continue ;;
    */*) ;;
    *.md) continue ;;
  esac
  echo "not documentation: $path"
  exit 1
done

if [ "$n" -eq 0 ]; then
  echo "no changed paths"
  exit 1
fi
echo "documentation only ($n changed)"
