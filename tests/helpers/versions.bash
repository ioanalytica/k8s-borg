# shellcheck shell=bash
#
# Extractors for the places a version is written down. Deliberately plain
# sed/awk rather than yq or a YAML library: the check must run anywhere with no
# setup, and it only reads a handful of well-known lines.
#
# Every extractor prints nothing when its pattern is absent, and the tests treat
# an empty result as a failure — a check that silently stops finding the value
# it guards is worse than no check at all.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHART="$REPO_ROOT/chart/Chart.yaml"
VALUES="$REPO_ROOT/chart/values.yaml"
BUILD_WF="$REPO_ROOT/.github/workflows/build.yml"

# The version of the UI application, from the pinned submodule. This is the one
# source of truth: the server image is built from this commit, so every place
# that names a UI image tag has to agree with it.
ui_app_version() { cat "$REPO_ROOT/borg-ui/VERSION" 2>/dev/null | tr -d '[:space:]'; }

chart_version()     { sed -n 's/^version:[[:space:]]*"\{0,1\}\([^"[:space:]]*\).*/\1/p'    "$CHART" | head -1; }
chart_app_version() { sed -n 's/^appVersion:[[:space:]]*"\{0,1\}\([^"[:space:]]*\).*/\1/p' "$CHART" | head -1; }

# annotation_image NAME — the tag of an entry in Chart.yaml's annotations.images
# block, which is a YAML document embedded in a string and therefore invisible
# to a plain YAML query.
annotation_image() {
  awk -v want="$1" '
    $1 == "-" && $2 == "name:" { cur = $3 }
    $1 == "image:" && cur == want { print $2; exit }
  ' "$CHART" | sed 's/.*://'
}

# values_tag REPOSITORY — the `tag:` belonging to a given `repository:` in
# values.yaml. The repository lines are unique, so the first tag after one of
# them is the right one.
values_tag() {
  sed -n "\#repository: $1\$#,/tag:/p" "$VALUES" | sed -n 's/.*tag:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

build_workflow() { cat "$BUILD_WF"; }

fail() { printf '%s\n' "$*" >&2; return 1; }
