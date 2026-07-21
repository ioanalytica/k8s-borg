#!/usr/bin/env bash
#
# Run shellcheck over every shell script in the repo. Used by CI and locally —
# same discovery, same flags, so a green run here means a green run there.
#
# Scripts in docker/rootfs/usr/local/bin have no .sh extension, so files are
# discovered by shebang (plus an explicit "shellcheck shell=" directive for the
# sourced-only libraries).
#
# -x follows the "# shellcheck source=" directives into the sourced libraries.
# -S warning keeps the gate at real problems; SC2086 (unquoted expansion) is
# info-level and deliberate in the wrappers, where BORG*_DEFAULT_PARAMS must
# word-split into separate borg arguments.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Selected by shebang, or by a shell directive for the sourced-only libraries.
# ".bats" files are excluded: @test blocks are not valid shell syntax.
# git ls-files -co --exclude-standard = tracked AND new-but-not-ignored, so a
# script is linted before it is ever committed.
# No mapfile: this must also run on the bash 3.2 that ships with macOS.
files=()
while IFS= read -r f; do
  [ -f "$f" ] || continue
  if head -1 "$f" | grep -qE '^#!.*(bash|sh)([[:space:]]|$)|shellcheck shell='; then
    files+=("$f")
  fi
done < <(git ls-files -co --exclude-standard docker scripts tests '*.sh' | grep -vE '\.(py|env|conf|yml|yaml|json|md|bats)$')

[ "${#files[@]}" -gt 0 ] || { echo "shellcheck: no scripts found — discovery broken?" >&2; exit 1; }

echo "shellcheck: ${#files[@]} scripts"
shellcheck -x -S warning "${files[@]}"
echo "shellcheck: OK"
