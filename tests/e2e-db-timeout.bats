#!/usr/bin/env bats
#
# tests/e2e/db/run.sh stops a server version that takes longer than
# E2E_DB_TIMEOUT, and reports each version's phases. One once hung in CI for 40 minutes without a line of output,
# because a server version's log is printed only when it is done; the job had
# no time limit and would have waited six hours.
#
# run.sh runs here against a fake docker on PATH: the test container's `run`
# and a server's `run -d` can be made to hang, `kill` ends the hung test
# container, and every call is recorded. A hung `run -d` is a server image
# that has not arrived yet: like the docker CLI, ended it creates nothing, and
# left alone it creates its container once the image is there — after run.sh
# has cleaned up, if run.sh merely gave up on it.
#
# Every sleep of a test, run.sh's watchdog's and the fakes', runs as
# $TMP/bin/sleep, a name of that test alone: a run of the suite in another
# checkout on the same machine sleeps as long, and must not count.

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
  REAL_SLEEP="$(command -v sleep)"
  cat >"$TMP/bin/sleep" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$TMP/sleeps"
exec -a "$TMP/bin/sleep" "$REAL_SLEEP" "\$@"
EOF
  chmod +x "$TMP/bin/sleep"
  export PATH="$TMP/bin:$PATH" FAKE_DOCKER="$TMP" E2E_DB_PREFIX="fake-db-$BATS_TEST_NUMBER"
  STARTED=()
}

teardown() {
  [ -z "${STARTED[*]:-}" ] || kill "${STARTED[@]}" 2>/dev/null || true
  pkill -f "$TMP/bin/sleep " || true
  common_teardown
}

# no_sleep_left [LENGTH…] — neither the watchdog's sleep nor a hung fake
# outlived run.sh: no sleep of this test is left. Each LENGTH is a sleep that
# must have run, so that the check looks where those sleeps were.
no_sleep_left() {
  local length
  for length in "$@"; do
    grep -qxF "$length" "$TMP/sleeps" || fail "no sleep $length ran: $(cat "$TMP/sleeps")"
  done
  run pgrep -f "$TMP/bin/sleep "
  [ "$status" -ne 0 ] || fail "left running: $(ps -ww -o pid=,args= -p "$(paste -sd, - <<<"$output")")"
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
  no_sleep_left 2 317
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
  no_sleep_left 2 6.17
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

@test "the summary gives the run's time and each version's phases" {
  run "$RUN_SH" sqlite:alpine postgres:17
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [[ "$output" =~ "── database e2e summary: "[0-9]+"s, 3 at a time ──" ]] || fail "$output"
  local v
  for v in sqlite:alpine postgres:17; do
    [[ "$output" =~ "✓ $v "[0-9]+"s: image "[0-9]+"s, servers "[0-9]+"s, tests "[0-9]+"s (servers ready after 3s)" ]] \
      || fail "no phases for $v: $output"
  done
}

@test "no_sleep_left sees a sleep the test left, and not the sleeps of another run" {
  # Another run of the suite on this machine: its sleeps run as its own
  # $TMP/bin/sleep, or as plain `sleep` in a checkout from before.
  local others=(sleep "$BATS_TEST_TMPDIR/bin/sleep") i j ready
  for j in 0 1; do
    (exec -a "${others[$j]}" "$REAL_SLEEP" 317 3>&-) &
    STARTED+=("$!")
  done
  sleep 317 3>&- &
  local own=$!
  STARTED+=("$own")
  # Started once the test's own sleep has recorded itself and the others run
  # under their names (an emulator such as Rosetta shows itself in front).
  for i in $(seq 50); do
    ready=0
    for j in 0 1; do
      if [[ "$(ps -ww -o args= -p "${STARTED[$j]}")" == *"${others[$j]} 317" ]]; then ready=$((ready + 1)); fi
    done
    if grep -qx 317 "$TMP/sleeps" 2>/dev/null; then ready=$((ready + 1)); fi
    [ "$ready" -lt 3 ] || break
    "$REAL_SLEEP" 0.1
  done
  [ "$ready" -eq 3 ] || fail "the sleeps did not start: $(ps -ww -o pid=,args= -p "$(IFS=,; echo "${STARTED[*]}")")"
  ! (no_sleep_left) 2>/dev/null || fail "the test's own sleep 317 was not seen"
  kill "$own"
  wait "$own" 2>/dev/null || true
  no_sleep_left 317
}
