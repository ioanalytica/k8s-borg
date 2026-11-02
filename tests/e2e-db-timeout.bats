#!/usr/bin/env bats
#
# tests/e2e/db/run.sh stops a server version that takes longer than
# E2E_DB_TIMEOUT, pulls the server images from the start, and reports each
# version's phases. One once hung in CI for 40 minutes without a line of output,
# because a server version's log is printed only when it is done; the job had
# no time limit and would have waited six hours.
#
# run.sh runs here against a fake docker on PATH: the test container's `run`
# and a server's `run -d` can be made to hang, `kill` ends the hung test
# container, and every call is recorded. A hung `run -d` is a server image
# that has not arrived yet: like the docker CLI, ended it creates nothing, and
# left alone it creates its container once the image is there — after run.sh
# has cleaned up, if run.sh merely gave up on it.

setup() {
  load helpers/common
  common_setup
  RUN_SH="$BATS_TEST_DIRNAME/e2e/db/run.sh"
  CALLS="$TMP/calls"
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DOCKER/calls"
case "$1" in
  run)
    if [ "$2" = -d ]; then
      if [ "${FAKE_HANG:-}" = server ]; then
        trap 'kill "$s" 2>/dev/null; exit 143' TERM
        sleep 6.17 3>&- & s=$!
        wait "$s"
        echo "created after the cleanup: $*" >>"$FAKE_DOCKER/calls"
      fi
      exit 0
    fi
    echo "1..2"
    echo "# servers ready after 3s"
    echo "ok 1 the first test"
    if [ "${FAKE_HANG:-}" = tests ]; then
      echo $$ >"$FAKE_DOCKER/tests.pid"
      exec sleep 317 3>&-
    fi
    echo "ok 2 the second test" ;;
  network)
    [ "$2:${FAKE_FAIL:-}" != create:network ] || exit 1 ;;
  exec)
    [ -s "$FAKE_DOCKER/tests.pid" ] || exit 1
    [ "$3" = true ] || printf '%s\n' "PID   PPID  ELAPSED COMMAND" "   64    59  0:45   valkey-cli --cluster create" ;;
  kill)
    kill "$(cat "$FAKE_DOCKER/tests.pid")" && rm -f "$FAKE_DOCKER/tests.pid" ;;
esac
exit 0
EOF
  chmod +x "$TMP/bin/docker"
  export PATH="$TMP/bin:$PATH" FAKE_DOCKER="$TMP" E2E_DB_PREFIX="fake-db-$BATS_TEST_NUMBER"
}

teardown() { common_teardown; }

# no_sleep_left — neither the watchdog's sleep nor a hung fake outlived run.sh.
no_sleep_left() {
  run pgrep -fx "sleep (317|31|6\.17)"
  [ "$status" -ne 0 ] || fail "left running: $output"
}

@test "a hung test container is stopped: the version fails with what it was running" {
  FAKE_HANG=tests E2E_DB_TIMEOUT=2 run "$RUN_SH" sqlite:alpine
  [ "$status" -eq 1 ] || fail "status $status: $output"
  [[ "$output" == *"ok 1 the first test"* ]] || fail "the tests' output so far is missing: $output"
  [[ "$output" == *"✗ sqlite:alpine: no result after 2s (E2E_DB_TIMEOUT), stopped"* ]] || fail "$output"
  [[ "$output" == *"valkey-cli --cluster create"* ]] || fail "what the container was running is missing: $output"
  [[ "$output" == *"── database e2e summary"*"✗ sqlite:alpine"* ]] || fail "$output"
  grep -qx "kill fake-db-1-sqlitealpine-tests" "$CALLS" || fail "the test container was not stopped: $(cat "$CALLS")"
  # The run's own cleanup, after the stop.
  sed -n '/^kill fake-db-1-sqlitealpine-tests$/,$p' "$CALLS" | grep -q "^rm -f -v fake-db-1-sqlitealpine-tests$" \
    || fail "nothing removed after the stop: $(cat "$CALLS")"
  no_sleep_left
}

@test "a server that does not start in time is ended, and nothing is created after the cleanup" {
  FAKE_HANG=server E2E_DB_TIMEOUT=2 run "$RUN_SH" sqlite:alpine
  [ "$status" -eq 1 ] || fail "status $status: $output"
  [[ "$output" == *"✗ sqlite:alpine: no result after 2s (E2E_DB_TIMEOUT), stopped"* ]] || fail "$output"
  [[ "$output" == *"── database e2e summary"*"✗ sqlite:alpine"* ]] || fail "$output"
  ! grep -q "^run -q --name fake-db-2-sqlitealpine-tests" "$CALLS" || fail "the tests ran after the hang: $(cat "$CALLS")"
  # A docker that run.sh gave up on would still be running, and create later.
  local i
  for i in $(seq 20); do pgrep -f "$TMP/bin/docker" >/dev/null || break; sleep 0.5; done
  ! grep -q "^created after the cleanup" "$CALLS" || fail "a container was created after the cleanup: $(cat "$CALLS")"
  [ "$(tail -1 "$CALLS")" = "network rm fake-db-2-sqlitealpine" ] \
    || fail "the cleanup is not the last thing run.sh did: $(cat "$CALLS")"
  no_sleep_left
}

@test "a version that finishes in time passes, and the watchdog does not outlive it" {
  local start=$SECONDS
  E2E_DB_TIMEOUT=31 run "$RUN_SH" sqlite:alpine
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [[ "$output" == *"ok 2 the second test"* ]] || fail "$output"
  [[ "$output" != *"no result after"* ]] || fail "$output"
  [ $((SECONDS - start)) -lt 20 ] || fail "run.sh waited for its watchdog: $((SECONDS - start))s"
  no_sleep_left
}

@test "a version that fails before its tests stops its watchdog with it" {
  # Left running, the watchdog would report the version stuck after
  # E2E_DB_TIMEOUT and look for its parent's children by a PID long gone; and
  # it holds run.sh's output open (a copy bash keeps of the redirected fd), so
  # whatever reads that output waits for it.
  local start=$SECONDS
  FAKE_FAIL=network E2E_DB_TIMEOUT=31 run "$RUN_SH" sqlite:alpine
  [ "$status" -eq 1 ] || fail "status $status: $output"
  [[ "$output" == *"── database e2e summary"*"✗ sqlite:alpine"* ]] || fail "$output"
  ! grep -q "^run " "$CALLS" || fail "a container was started: $(cat "$CALLS")"
  [ $((SECONDS - start)) -lt 20 ] || fail "run.sh's output stayed open for its watchdog: $((SECONDS - start))s"
  no_sleep_left
}

@test "the summary gives each version's phases and each image's pull" {
  run "$RUN_SH" sqlite:alpine postgres:17
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [[ "$output" =~ "── database e2e summary: "[0-9]+"s, 3 at a time ──" ]] || fail "$output"
  local v
  for v in sqlite:alpine postgres:17; do
    [[ "$output" =~ "✓ $v "[0-9]+"s: image "[0-9]+"s, servers "[0-9]+"s, tests "[0-9]+"s (servers ready after 3s)" ]] \
      || fail "no phases for $v: $output"
  done
  [[ "$output" == *"── image pulls, from the start, four at a time ──"* ]] || fail "$output"
  [[ "$output" =~ "python:3.13-alpine: pulled in "[0-9]+"s" ]] || fail "$output"
  [[ "$output" =~ "postgres:17-alpine: pulled in "[0-9]+"s" ]] || fail "$output"
}

@test "each image is pulled once from the start, and a version finds it there" {
  run "$RUN_SH" sqlite:alpine sqlite:alpine postgres:17
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(grep -cx "pull -q python:3.13-alpine" "$CALLS")" -eq 1 ] || fail "$(cat "$CALLS")"
  [ "$(grep -cx "pull -q postgres:17-alpine" "$CALLS")" -eq 1 ] || fail "$(cat "$CALLS")"
  # The fake has every image, so no version pulls one of its own.
  [ "$(grep -c "^pull " "$CALLS")" -eq 2 ] || fail "$(cat "$CALLS")"
  grep -qx "image inspect postgres:17-alpine" "$CALLS" || fail "$(cat "$CALLS")"
}
