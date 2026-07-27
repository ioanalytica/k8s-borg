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
# The runtime-base image tag is computed from the version facts in the submodule's
# env file (runtime-base-tag.sh) — both docker/docker-build-*.sh and build.yml call
# it. The submodule's own Dockerfile repeats the result as the ARG BASE_IMAGE
# default (for a script-less `docker build`), and that copy is what can drift.
RUNTIME_TAG_SH="$REPO_ROOT/borg-ui/docker/runtime-base-tag.sh"
RUNTIME_ENV="$REPO_ROOT/borg-ui/docker/runtime-base.env"
SUBMODULE_DOCKERFILE="$REPO_ROOT/borg-ui/Dockerfile"

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

# values_tag REPOSITORY [FILE] — the `tag:` belonging to a given `repository:`
# in values.yaml.
#
# Tracking the current repository rather than reading forward to the next `tag:`
# matters: a block that carries no tag of its own must yield nothing, not the
# tag of whatever block comes next. Reading forward would make the "agent image
# tag is left to appVersion" assertion pass on the initImage's tag the moment
# someone deletes the empty `tag: ""` line.
values_tag() {
  awk -v repo="$1" '
    $1 == "repository:" { cur = $2 }
    $1 == "tag:" && cur == repo { gsub(/"/, "", $2); print $2; exit }
  ' "${2:-$VALUES}"
}

build_workflow() { cat "$BUILD_WF"; }

# The authoritative runtime-base tag: computed from the version facts by the same
# helper the build scripts and CI call.
runtime_base_tag() {
  bash "$RUNTIME_TAG_SH"
}

# The tag baked into the submodule Dockerfile's `ARG BASE_IMAGE=` default — the
# part after the image name's colon.
server_base_image_tag() {
  sed -n 's/^ARG BASE_IMAGE=.*:\(runtime-[^"[:space:]]*\).*/\1/p' "$SUBMODULE_DOCKERFILE" | head -1
}

# The single-source Python version.
python_version_truth() {
  sed -n 's/^PYTHON_VERSION=\(.*\)/\1/p' "$RUNTIME_ENV" | head -1
}

# The ARG PYTHON_VERSION default baked into a Dockerfile (empty if none).
dockerfile_python_arg() {
  sed -n 's/^ARG PYTHON_VERSION=\(.*\)/\1/p' "$REPO_ROOT/$1" | head -1
}

fail() { printf '%s\n' "$*" >&2; return 1; }
