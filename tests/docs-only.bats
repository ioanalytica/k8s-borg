#!/usr/bin/env bats
#
# scripts/docs-only.sh decides whether a pull request may skip the end-to-end
# jobs of Lint & test. A path it wrongly calls documentation lets a change to
# the images or the chart through untested, so the list is short and anything
# not on it runs everything.

setup() {
  load helpers/common
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/docs-only.sh"
}

# docs_only PATH... — the script on these paths, one per line.
docs_only() { printf '%s\n' "$@" | "$SCRIPT"; }

@test "Markdown at the top level, LICENSE, examples/ and site/ are documentation" {
  run docs_only README.md CHANGELOG.md CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md \
    LICENSE examples/README.md examples/helm/k8s-borg.yaml \
    site/index.md site/.vitepress/config.mts site/package-lock.json
  [ "$status" -eq 0 ] || fail "$output"
  [ "$output" = "documentation only (11 changed)" ] || fail "$output"
}

@test "anything below docker/, chart/, tests/, scripts/ or .github/ runs everything" {
  local p
  for p in docker/Dockerfile docker/rootfs/usr/local/bin/borg-backup chart/README.md \
    chart/values.yaml tests/README.md tests/e2e/clients.bats scripts/docs-only.sh \
    .github/workflows/lint-test.yml .github/ISSUE_TEMPLATE/config.yml; do
    run docs_only README.md "$p"
    [ "$status" -eq 1 ] || fail "$p: status $status: $output"
    [ "$output" = "not documentation: $p" ] || fail "$p: $output"
  done
}

@test "the submodule, Markdown below the top level and other files run everything" {
  local p
  for p in borg-ui local/README.md run-tests.sh icon.png .gitmodules .coderabbit.yaml \
    README.md.orig site sites/index.md; do
    run docs_only "$p"
    [ "$status" -eq 1 ] || fail "$p: status $status: $output"
    [ "$output" = "not documentation: $p" ] || fail "$p: $output"
  done
}

@test "no paths runs everything, blank lines are no paths" {
  run "$SCRIPT" </dev/null
  [ "$status" -eq 1 ] || fail "status $status: $output"
  [ "$output" = "no changed paths" ] || fail "$output"
  run docs_only "" README.md ""
  [ "$status" -eq 0 ] || fail "$output"
  [ "$output" = "documentation only (1 changed)" ] || fail "$output"
}
