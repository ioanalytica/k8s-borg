#!/usr/bin/env bats
#
# Borg 2 and borgstore belong together, on the client and on the repository
# server. The agent image used to install whatever borgstore satisfied Borg's
# requirement on the day of the build, so two builds of the same commit could
# differ, and neither had to match what the submodule states.
#
# The image now takes Borg 2 from the submodule's manifest and borgstore from its
# runtime-base.env. Two sources for one pair: they have to name the same Borg 2.

setup() {
  load helpers/versions
  DOCKERFILE="$REPO_ROOT/docker/Dockerfile"
  VERSIONS_PY="$REPO_ROOT/docker/borg-versions.py"
}

# versions_py BORG2_IN_MANIFEST ENV_LINE… — run the script on made-up sources.
versions_py() {
  printf '{"current": {"1": "1.4.5", "2": "%s"}}\n' "$1" >"$BATS_TEST_TMPDIR/manifest.json"
  shift
  printf '%s\n' "# a comment" "$@" >"$BATS_TEST_TMPDIR/runtime-base.env"
  run python3 "$VERSIONS_PY" "$BATS_TEST_TMPDIR/manifest.json" "$BATS_TEST_TMPDIR/runtime-base.env"
}

@test "the submodule states a borgstore version" {
  [ -n "$(runtime_env_value BORGSTORE_VERSION)" ] || fail "no BORGSTORE_VERSION in runtime-base.env"
  [ -n "$(runtime_env_value BORG2_VERSION)" ]     || fail "no BORG2_VERSION in runtime-base.env"
  [ -n "$(manifest_borg2_version)" ]              || fail "no current Borg 2 in the manifest — is the submodule checked out?"
}

@test "manifest and runtime-base.env name the same Borg 2" {
  [ "$(manifest_borg2_version)" = "$(runtime_env_value BORG2_VERSION)" ] \
    || fail "manifest says $(manifest_borg2_version), runtime-base.env says $(runtime_env_value BORG2_VERSION)"
}

@test "the image installs exactly the stated borgstore" {
  # Every requirement handed to pip that names borgstore. Anything softer than
  # == would install something else instead of failing.
  requirements="$(grep -o '"borgstore[^"]*"' "$DOCKERFILE")"
  [ -n "$requirements" ] || fail "docker/Dockerfile installs no borgstore"
  while read -r requirement; do
    [[ "$requirement" == *']==${BORGSTORE_VERSION}"' ]] \
      || fail "docker/Dockerfile installs $requirement, not pinned with == to BORGSTORE_VERSION"
  done <<<"$requirements"
}

@test "the image installs borgstore with the blake3 extra" {
  grep -q '"borgstore\[[a-z0-9,]*blake3[a-z0-9,]*\]==' "$DOCKERFILE"
}

@test "the build context carries the file the pin comes from" {
  grep -qx '!borg-ui/docker/runtime-base.env' "$REPO_ROOT/.dockerignore"
  grep -q 'COPY .*borg-ui/docker/runtime-base.env' "$DOCKERFILE"
}

@test "borg-versions.py prints the three versions" {
  versions_py 2.0.0b24 BORG2_VERSION=2.0.0b24 BORGSTORE_VERSION=0.6.1
  [ "$status" -eq 0 ] || fail "$output"
  [ "$output" = "BORG1_VERSION=1.4.5
BORG2_VERSION=2.0.0b24
BORGSTORE_VERSION=0.6.1" ] || fail "$output"
}

@test "a borgstore pin left behind by a Borg 2 bump stops the build" {
  versions_py 2.0.0b25 BORG2_VERSION=2.0.0b24 BORGSTORE_VERSION=0.6.1
  [ "$status" -ne 0 ]
  [[ "$output" == *"belongs to another Borg 2"* ]] || fail "$output"
}

@test "a missing borgstore version stops the build" {
  versions_py 2.0.0b24 BORG2_VERSION=2.0.0b24
  [ "$status" -ne 0 ]
  [[ "$output" == *"no BORGSTORE_VERSION"* ]] || fail "$output"
}

@test "a value that is no version is not handed to the shell" {
  versions_py 2.0.0b24 BORG2_VERSION=2.0.0b24 'BORGSTORE_VERSION=0.6.1; touch /tmp/pwned'
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a version"* ]] || fail "$output"
}
