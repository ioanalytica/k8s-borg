#!/usr/bin/env bash
#
# Run every test layer in this repo and summarise the result.
#
# Layers run cheapest-first, but a failing one does NOT stop the run: a single
# command should tell you everything that is broken, not just the first thing.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

usage() {
  cat <<'EOF'
Usage: ./run-tests.sh [--quick]

  (no argument)   lint + unit tests + end-to-end   (needs docker, ~2-4 min)
  --quick, -q     lint + unit tests only           (~3 s)

Environment passed through to the end-to-end layer:
  SKIP_BUILD=1    reuse the existing k8s-borg:test image. Careful: this skips
                  the AGENT image, so changes under docker/rootfs/ are NOT
                  picked up.
EOF
}

quick=0
for arg in "$@"; do
  case "$arg" in
    -q|--quick) quick=1 ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

# Fail on a missing tool with the command to fix it, rather than a bare
# "command not found" from three levels down.
need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  echo "✗ $1 is not installed — brew install $2   (or: apt-get install $2)" >&2
  exit 2
}
need shellcheck shellcheck
need bats bats-core

if [ -t 1 ]; then bold=$'\033[1m'; off=$'\033[0m'; else bold=''; off=''; fi

results=()
rc=0

# run_layer NAME COMMAND… — run one layer, record pass/fail, keep going.
run_layer() {
  local name="$1" start=$SECONDS
  shift
  printf '\n%s▶ %s%s\n' "$bold" "$name" "$off"
  if "$@"; then
    results+=("✓ $name ($((SECONDS - start))s)")
  else
    results+=("✗ $name ($((SECONDS - start))s)")
    rc=1
  fi
}

run_layer "lint (shellcheck)" ./tests/shellcheck.sh
run_layer "unit tests (bats)" bats --print-output-on-failure tests/

if [ "$quick" = "1" ]; then
  results+=("– end-to-end (skipped: --quick)")
elif docker info >/dev/null 2>&1; then
  run_layer "end-to-end (borg1 + borg2)" ./tests/e2e/run.sh
else
  # Deliberately a failure, not a quiet skip: the run was asked for everything
  # and cannot deliver it. --quick is how you ask for less.
  echo "✗ docker is not running — start it, or use --quick to skip end-to-end" >&2
  results+=("✗ end-to-end (docker unavailable)")
  rc=1
fi

printf '\n%s── summary ──%s\n' "$bold" "$off"
printf '%s\n' "${results[@]}"
exit "$rc"
