#!/usr/bin/env bats
#
# Python is single-sourced in borg-ui/docker/runtime-base.env. The Dockerfiles
# take it as ARG PYTHON_VERSION and interpolate it into their FROM lines and the
# site-packages COPY paths. A stray python:X.Y literal — the 3.10-vs-3.12 split
# that left borg-ui/Dockerfile copying a site-packages path its builder never
# produced — must fail here.

setup() { load helpers/versions; }

dockerfiles() {
  printf '%s\n' borg-ui/Dockerfile borg-ui/Dockerfile.runtime-base docker/Dockerfile
}

@test "runtime-base.env states a Python version" {
  [ -n "$(python_version_truth)" ] || fail "no PYTHON_VERSION in runtime-base.env"
}

@test "no Dockerfile hardcodes a python:X.Y or /pythonX.Y/ literal" {
  while read -r df; do
    if grep -nE 'python:3\.[0-9]+|/python3\.[0-9]+/' "$REPO_ROOT/$df"; then
      fail "$df hardcodes a Python version above — use \${PYTHON_VERSION}"
    fi
  done < <(dockerfiles)
}

@test "every Dockerfile's ARG PYTHON_VERSION default matches runtime-base.env" {
  local truth got
  truth="$(python_version_truth)"
  while read -r df; do
    got="$(dockerfile_python_arg "$df")"
    [ -n "$got" ] || fail "$df has no ARG PYTHON_VERSION default"
    [ "$got" = "$truth" ] \
      || fail "$df pins PYTHON_VERSION=$got, runtime-base.env says $truth"
  done < <(dockerfiles)
}
