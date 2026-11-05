#!/usr/bin/env bats
#
# scripts/changelog-section.sh, which build.yml uses for the body of a release.

setup() {
  load helpers/common
  common_setup
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/changelog-section.sh"
  cat >"$TMP/CHANGELOG.md" <<'MD'
# Changelog

## Unreleased

* Not yet.

## 1.2.3

* **First.** Line one
  continues.

* **Second.**

## 1.2.3-beta.1

* The beta.

## 1.2.2

* Older.
MD
}

teardown() { common_teardown; }

@test "prints the entry of the version, without its heading and the blank lines around it" {
  run "$SCRIPT" 1.2.3 "$TMP/CHANGELOG.md"
  [ "$status" -eq 0 ] || fail "$output"
  [ "$output" = "$(printf '%s\n' '* **First.** Line one' '  continues.' '' '* **Second.**')" ] \
    || fail "got: $output"
}

@test "a version is matched whole, not as the start of another one" {
  run "$SCRIPT" 1.2.3-beta.1 "$TMP/CHANGELOG.md"
  [ "$output" = "* The beta." ] || fail "got: $output"
  run "$SCRIPT" 1.2 "$TMP/CHANGELOG.md"
  [ "$status" -eq 0 ] && [ -z "$output" ] || fail "got: $output"
}

@test "the last section ends at the end of the file" {
  run "$SCRIPT" 1.2.2 "$TMP/CHANGELOG.md"
  [ "$output" = "* Older." ] || fail "got: $output"
}

@test "a version without a section prints nothing and succeeds" {
  run "$SCRIPT" 9.9.9 "$TMP/CHANGELOG.md"
  [ "$status" -eq 0 ] && [ -z "$output" ] || fail "status $status: $output"
}

@test "a prerelease without a section of its own prints the entry of its release" {
  # It is tagged on the commit its release will be tagged on.
  local want
  want="$("$SCRIPT" 1.2.3 "$TMP/CHANGELOG.md")"
  [ -n "$want" ] || fail "no entry for 1.2.3"
  run "$SCRIPT" 1.2.3-rc.1 "$TMP/CHANGELOG.md"
  [ "$status" -eq 0 ] && [ "$output" = "$want" ] || fail "got: $output"
  # A section of its own wins, and a prerelease of an unknown release has none.
  run "$SCRIPT" 1.2.3-beta.1 "$TMP/CHANGELOG.md"
  [ "$output" = "* The beta." ] || fail "got: $output"
  run "$SCRIPT" 9.9.9-rc.1 "$TMP/CHANGELOG.md"
  [ "$status" -eq 0 ] && [ -z "$output" ] || fail "got: $output"
  # An empty section of its own is its section.
  awk '$0 == "## 1.2.3" { print "## 1.2.3-rc.2\n" } { print }' "$TMP/CHANGELOG.md" >"$TMP/empty.md"
  run "$SCRIPT" 1.2.3-rc.2 "$TMP/empty.md"
  [ "$status" -eq 0 ] && [ -z "$output" ] || fail "got: $output"
}

@test "no version is a usage error, a missing file a failure" {
  run "$SCRIPT"
  [ "$status" -eq 2 ] || fail "status $status"
  run "$SCRIPT" 1.2.3 "$TMP/missing.md"
  [ "$status" -ne 0 ] || fail "a missing file passed"
}

@test "the repository's CHANGELOG.md has an entry for the chart version" {
  load helpers/versions
  run "$SCRIPT" "$(chart_version)"
  [ "$status" -eq 0 ] && [ -n "$output" ] \
    || fail "no '## $(chart_version)' section in CHANGELOG.md (status $status): $output"
}
