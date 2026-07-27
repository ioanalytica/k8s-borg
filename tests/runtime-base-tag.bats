#!/usr/bin/env bats
#
# The runtime-base image tag is computed from the version facts in
# borg-ui/docker/runtime-base.env (runtime-base-tag.sh, which the build scripts
# and build.yml call), and repeated as the ARG BASE_IMAGE default in the
# submodule's borg-ui/Dockerfile for a script-less `docker build`. The build path
# overrides the default via --build-arg, so that repeated copy can drift silently
# — a Borg bump moved the versions to r5 while the (then forked) server Dockerfile
# sat at r4, an image tag that need not exist. This pins the two together.

setup() { load helpers/versions; }

@test "both runtime-base tag sources are readable" {
  [ -n "$(runtime_base_tag)" ] \
    || fail "runtime-base-tag.sh produced nothing — is the submodule checked out?"
  [ -n "$(server_base_image_tag)" ] \
    || fail "no ARG BASE_IMAGE=...:runtime-... default in borg-ui/Dockerfile"
}

@test "the submodule Dockerfile's base-image default matches the authoritative tag" {
  [ "$(server_base_image_tag)" = "$(runtime_base_tag)" ] \
    || fail "borg-ui/Dockerfile pins $(server_base_image_tag), runtime-base.env says $(runtime_base_tag)"
}
