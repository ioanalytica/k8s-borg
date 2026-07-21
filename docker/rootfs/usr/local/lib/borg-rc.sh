# shellcheck shell=bash
#
# borg-rc.sh — shared Borg exit-code semantics for the `borg`/`borg2` wrappers
# and the standalone `borg-backup` / `borg-prune` / `borg-mount` scripts.
# Sourced (never executed); defines functions only — no side effects, no output.
# Callers source it as "${BORG_LIB_DIR:-/usr/local/lib}/borg-rc.sh"; BORG_LIB_DIR
# (and BORG_BIN_DIR for the borg->borg2 hand-off) let the wrappers run from a
# checkout, e.g. under tests/. Unset in the image = the paths below.
# Keeps the "what is a borg warning?" rule in ONE place instead of copy-pasted
# per script (same spirit as borgui-common.sh).
#
# Borg has two exit-code schemes, chosen by the USER via BORG_EXIT_CODES
# (borg1 defaults to legacy, borg2 defaults to modern — see borg's errors.py).
# We deliberately DO NOT override that choice, and we do not need to read it:
# the two schemes use DISJOINT numeric ranges, so one predicate is correct under
# both.
#
#   ok      : 0
#   warning : 1                (generic, both schemes)  |  100..127  (modern only)
#   error   : 2                (generic, both schemes)  |    3..99   (modern only)
#
# We only ever act on WARNINGS — tolerate them, so a routine warning (a file
# that vanished mid-backup on a live filesystem) does not fail a managed-agent
# job. Every ERROR code passes through untouched, so a modern user keeps the
# granular error codes (lock = 73, …) and a legacy user keeps plain 0/1/2.

# borg_rc_is_warning RC — succeed (return 0) iff RC is a borg warning in either
# scheme. Non-numeric / empty RC is treated as not-a-warning.
borg_rc_is_warning() {
  [ "${1:-0}" -eq 1 ] 2>/dev/null && return 0
  [ "${1:-0}" -ge 100 ] 2>/dev/null && [ "${1:-0}" -le 127 ] 2>/dev/null
}

# borg_rc_worst RC… — reduce several borg exit codes to a single one using borg
# precedence (error > warning > ok), NOT numeric size. A plain max() is WRONG
# under modern codes because a warning (100..127) is numerically larger than an
# error (2..99) and would mask it. Prints 0 (all ok), 1 (warnings only), or the
# last real error code seen.
borg_rc_worst() {
  _brc_worst=0
  for _brc in "$@"; do
    [ "${_brc:-0}" -eq 0 ] && continue
    if borg_rc_is_warning "$_brc"; then
      [ "$_brc_worst" -eq 0 ] && _brc_worst=1
    else
      _brc_worst="$_brc"
    fi
  done
  printf '%s' "$_brc_worst"
}
