#!/usr/bin/env bats
#
# backup-cluster-databases, the database dumps of a cluster CronJob run: only
# the engines in BORG_DB_ENGINES run (the chart sets it to the configured
# ones, empty when none is); without the variable every wrapper of the image
# does. A warning of one engine does not stop the others, a failure does.

bats_require_minimum_version 1.5.0   # run --separate-stderr

setup() {
  load helpers/common
  common_setup
  unset BORG_DB_ENGINES
  # Stub wrappers: each records its run and ends with $TMP/rc-<engine>.
  STUBS="$TMP/stubs"
  mkdir -p "$STUBS"
  for engine in mariadb postgres mongodb; do
    cat >"$STUBS/backup-cluster-$engine" <<EOF
#!/usr/bin/env bash
echo $engine >>"$TMP/ran"
exit \$(cat "$TMP/rc-$engine" 2>/dev/null || echo 0)
EOF
    chmod +x "$STUBS/backup-cluster-$engine"
  done
  # The script under test sits next to the stubs, as in the image.
  cp "$BIN/backup-cluster-databases" "$STUBS/"
  export PATH="$STUBS:$PATH" BORG_BIN_DIR="$STUBS"
}

teardown() { common_teardown; }

ran() { tr '\n' ' ' <"$TMP/ran" 2>/dev/null | sed 's/ $//'; }

@test "only the engines in BORG_DB_ENGINES run, in their order" {
  BORG_DB_ENGINES="postgres" run backup-cluster-databases
  [ "$status" -eq 0 ] || fail "rc=$status: $output"
  [ "$(ran)" = "postgres" ] || fail "ran: $(ran)"
  rm -f "$TMP/ran"
  BORG_DB_ENGINES="postgres mariadb" run backup-cluster-databases
  [ "$(ran)" = "postgres mariadb" ] || fail "ran: $(ran)"
}

@test "an empty BORG_DB_ENGINES runs nothing" {
  BORG_DB_ENGINES="" run backup-cluster-databases
  [ "$status" -eq 0 ] || fail "rc=$status: $output"
  [ ! -e "$TMP/ran" ] || fail "ran: $(ran)"
}

@test "without BORG_DB_ENGINES every wrapper of the image runs, itself aside" {
  run backup-cluster-databases
  [ "$status" -eq 0 ] || fail "rc=$status: $output"
  [ "$(ran)" = "mariadb mongodb postgres" ] || fail "ran: $(ran)"
}

@test "a warning (rc 1) of one engine is passed on after the others ran" {
  echo 1 >"$TMP/rc-mariadb"
  BORG_DB_ENGINES="mariadb postgres" run backup-cluster-databases
  [ "$status" -eq 1 ] || fail "rc=$status"
  [ "$(ran)" = "mariadb postgres" ] || fail "ran: $(ran)"
}

@test "a failing engine stops the run with its rc" {
  echo 3 >"$TMP/rc-mariadb"
  BORG_DB_ENGINES="mariadb postgres" run backup-cluster-databases
  [ "$status" -eq 3 ] || fail "rc=$status"
  [ "$(ran)" = "mariadb" ] || fail "ran: $(ran)"
}

@test "an engine without a wrapper fails with rc >= 2" {
  BORG_DB_ENGINES="nosuchengine postgres" run --separate-stderr backup-cluster-databases
  [ "$status" -eq 2 ] || fail "rc=$status"
  [[ "$stderr" == *"nosuchengine has no backup-cluster-nosuchengine"* ]] || fail "$stderr"
  [ ! -e "$TMP/ran" ] || fail "ran: $(ran)"
}
