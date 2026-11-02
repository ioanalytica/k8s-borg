#!/usr/bin/env bats
#
# tests/e2e/run.sh takes Borg majors and files of tests/e2e, so that a CI job
# runs one part of a major's suite. It runs here against a fake docker on
# PATH that records every call; nothing is built or started.

setup() {
  load helpers/common
  common_setup
  RUN_SH="$BATS_TEST_DIRNAME/e2e/run.sh"
  CALLS="$TMP/calls"
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/docker" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DOCKER/calls"
FAKE
  chmod +x "$TMP/bin/docker"
  export PATH="$TMP/bin:$PATH" FAKE_DOCKER="$TMP" SKIP_BUILD=1
}

teardown() { common_teardown; }

# suites — the suite runs among the recorded calls: the major, then what bats
# was given.
suites() {
  sed -n 's/^run .*-e BORG_TEST_VERSION=\([0-9]\) .* bats --print-output-on-failure /\1 /p' "$CALLS"
}

@test "without arguments every file runs, once per major" {
  run "$RUN_SH"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(suites)" = "$(printf '%s\n' '1 /tests/e2e' '2 /tests/e2e')" ] || fail "$(cat "$CALLS")"
}

@test "only the files given run, for the majors given" {
  run "$RUN_SH" 2 prune.bats s3fs.bats
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(suites)" = "2 /tests/e2e/prune.bats /tests/e2e/s3fs.bats" ] || fail "$(cat "$CALLS")"
  [[ "$output" == *"▶ e2e suite, Borg 2: /tests/e2e/prune.bats /tests/e2e/s3fs.bats"* ]] || fail "$output"
}

@test "an argument that is no major and no file of tests/e2e is refused before anything runs" {
  local arg
  for arg in 3 nope.bats db/postgres.bats tests/e2e/prune.bats prune; do
    rm -f "$CALLS"
    run "$RUN_SH" 2 "$arg"
    [ "$status" -eq 2 ] || fail "$arg: status $status: $output"
    [[ "$output" == *"✗ $arg"* || "$output" == *"✗ there is no tests/e2e/$arg"* ]] || fail "$arg: $output"
    [ ! -e "$CALLS" ] || fail "$arg: docker ran: $(cat "$CALLS")"
  done
}
