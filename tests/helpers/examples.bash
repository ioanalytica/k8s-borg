# shellcheck shell=bash
#
# Readers for the examples (examples/), for examples-helm.bats and
# examples-k3d.bats.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# unknown_keys VALUES — every key VALUES sets that chart/values.yaml does not
# know, as a values path, one per line. Helm drops such a key without a word.
# A map the chart leaves empty ({}) takes any key; below it nothing is checked.
unknown_keys() {
  python3 - "$1" "$REPO_ROOT/chart/values.yaml" <<'PY'
import sys, yaml
ex, known = (yaml.safe_load(open(p)) for p in sys.argv[1:3])
def walk(e, k, path):
    for key, val in e.items():
        p = f"{path}.{key}" if path else key
        if not isinstance(k, dict) or key not in k:
            print(p)
        elif isinstance(val, dict) and isinstance(k[key], dict) and k[key]:
            walk(val, k[key], p)
walk(ex, known, "")
PY
}
