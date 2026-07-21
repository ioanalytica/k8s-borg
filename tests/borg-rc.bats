#!/usr/bin/env bats
#
# borg-rc.sh — the exit-code semantics shared by every borg wrapper and script.
# Pure functions, sourced directly; no fake borg needed.

setup() {
  load helpers/common
  # shellcheck source=../docker/rootfs/usr/local/lib/borg-rc.sh
  . "$BORG_LIB_DIR/borg-rc.sh"
}

# --- borg_rc_is_warning -------------------------------------------------------
# A warning is 1 (both schemes) or 100..127 (modern only). Everything else is
# either success or a real error and must NOT be swallowed.

@test "is_warning: 0 is success, not a warning" {
  run borg_rc_is_warning 0
  [ "$status" -ne 0 ]
}

@test "is_warning: 1 is the generic warning in both schemes" {
  borg_rc_is_warning 1
}

@test "is_warning: 2 is the generic error" {
  run borg_rc_is_warning 2
  [ "$status" -ne 0 ]
}

@test "is_warning: modern error range 3..99 is not a warning" {
  for rc in 3 42 73 99; do
    run borg_rc_is_warning "$rc"
    [ "$status" -ne 0 ] || fail "rc=$rc was classified as a warning"
  done
}

@test "is_warning: modern warning range 100..127 inclusive" {
  for rc in 100 113 127; do
    borg_rc_is_warning "$rc" || fail "rc=$rc was not classified as a warning"
  done
}

@test "is_warning: 128 (signal range) is not a warning" {
  run borg_rc_is_warning 128
  [ "$status" -ne 0 ]
}

@test "is_warning: empty and non-numeric input are not warnings" {
  run borg_rc_is_warning ""
  [ "$status" -ne 0 ]
  run borg_rc_is_warning "boom"
  [ "$status" -ne 0 ]
}

# --- borg_rc_worst ------------------------------------------------------------
# Precedence is error > warning > ok — NOT numeric max. Under modern codes a
# warning (100..127) is numerically larger than an error (2..99), so a plain
# max() would report "warning" for a run that actually failed. That is the whole
# reason this function exists, so it is pinned from both argument orders.

@test "worst: no arguments is 0" {
  [ "$(borg_rc_worst)" = "0" ]
}

@test "worst: all-ok stays 0" {
  [ "$(borg_rc_worst 0 0 0)" = "0" ]
}

@test "worst: warnings only collapse to 1" {
  [ "$(borg_rc_worst 0 1)" = "1" ]
  [ "$(borg_rc_worst 1 100)" = "1" ]
  [ "$(borg_rc_worst 127 0 100)" = "1" ]
}

@test "worst: an error outranks a numerically larger warning" {
  [ "$(borg_rc_worst 2 100)" = "2" ]
  [ "$(borg_rc_worst 100 2)" = "2" ]
}

@test "worst: error code is preserved, not flattened to 2" {
  [ "$(borg_rc_worst 0 73)" = "73" ]
  [ "$(borg_rc_worst 100 73)" = "73" ]
}

@test "worst: with several errors the last one wins" {
  [ "$(borg_rc_worst 3 5)" = "5" ]
}

@test "worst: prune-then-compact, the real-world shape" {
  # prune warned (a file vanished), compact failed hard → must surface the error.
  [ "$(borg_rc_worst 100 2)" = "2" ]
  # prune failed, compact fine → the error must not be lost.
  [ "$(borg_rc_worst 2 0)" = "2" ]
}
