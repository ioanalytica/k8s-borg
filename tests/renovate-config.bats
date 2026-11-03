#!/usr/bin/env bats
#
# .github/renovate.json, the dependency update bot: the pins it must leave
# alone stay excluded, every action is pinned to a commit, and every version
# pin of the agent image is one its custom manager finds. A pin added without
# its `# renovate:` line would quietly never be updated.

setup() {
  load helpers/versions
  CONFIG="$REPO_ROOT/.github/renovate.json"
}

# py SCRIPT — run SCRIPT with the repository root and the config as arguments.
py() { python3 - "$REPO_ROOT" "$CONFIG" <<<"$1"; }

@test "the release-managed pins stay excluded" {
  run py '
import json, sys
c = json.load(open(sys.argv[2]))
problems = []
for manager in ("git-submodules", "helm-values", "helmv3"):
    if c.get(manager, {}).get("enabled") is not False:
        problems.append(f"{manager} is not disabled")
if "borg-ui/**" not in c.get("ignorePaths", []):
    problems.append("borg-ui/** is not in ignorePaths")
if not any(r.get("matchManagers") == ["dockerfile"] and r.get("matchDepNames") == ["python"]
           and r.get("enabled") is False for r in c.get("packageRules", [])):
    problems.append("the runtime base Python is not disabled")
print("\n".join(problems))
sys.exit(1 if problems else 0)
'
  [ "$status" -eq 0 ] || fail "$output"
}

@test "every action is pinned to a commit, with its release in a comment" {
  local uses
  uses="$(grep -hE '^ *(- )?uses: ' "$REPO_ROOT"/.github/workflows/*.y*ml | grep -v 'uses: \./')"
  [ -n "$uses" ] || fail "no action found"
  run grep -vE 'uses: [^ ]+@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$' <<<"$uses"
  [ "$status" -eq 1 ] || fail "not pinned to a commit with its release: $output"
}

@test "every runner label is one Renovate reads: after runs-on, or in a matrix under runner" {
  # The github-actions manager reads runs-on alone; a custom manager reads the
  # labels a matrix hands to it, or a runner update would leave them behind.
  run py '
import glob, json, os, re, sys
root, c = sys.argv[1], json.load(open(sys.argv[2]))
strings = [re.compile(s.replace("(?<", "(?P<")) for m in c["customManagers"]
           if m.get("datasourceTemplate") == "github-runners" for s in m["matchStrings"]]
problems = [] if strings else ["no custom manager reads runner labels"]
for wf in sorted(glob.glob(f"{root}/.github/workflows/*.y*ml")):
    for n, line in enumerate(open(wf), 1):
        if not re.search(r"\bubuntu-\d", line) or re.match(r" *runs-on: ubuntu-", line):
            continue
        if not any(s.search(line) for s in strings):
            problems.append(f"{os.path.relpath(wf, root)}:{n}: {line.strip()}")
print("\n".join(problems))
sys.exit(1 if problems else 0)
'
  [ "$status" -eq 0 ] || fail "runner labels Renovate does not read: $output"
}

@test "the custom managers find every version pin of the agent image and the workflows, PYTHON_VERSION aside" {
  # PYTHON_VERSION is borg-ui's (tests/python-version.bats). The match strings
  # are JavaScript regular expressions; their named groups are the only syntax
  # Python spells differently.
  run py '
import glob, json, os, re, sys
root, c = sys.argv[1], json.load(open(sys.argv[2]))
managers = [([re.compile(p.strip("/")) for p in m["managerFilePatterns"]],
             [re.compile(s.replace("(?<", "(?P<")) for s in m["matchStrings"]])
            for m in c["customManagers"] if m.get("datasourceTemplate") != "github-runners"]
# Where a version pin is written down, and how it reads there.
pins = {"docker/Dockerfile": r"^ARG (\w+_VERSION)=", "docker/rclone.env": r"^(\w+_VERSION)="}
for wf in sorted(glob.glob(f"{root}/.github/workflows/*.y*ml")):
    pins[os.path.relpath(wf, root)] = r"^ *(\w+_VERSION): "
problems = []
for path, pin in pins.items():
    strings = [s for patterns, ss in managers if any(p.search(path) for p in patterns) for s in ss]
    text = open(f"{root}/{path}").read()
    wanted = set(re.findall(pin, text, re.M)) - {"PYTHON_VERSION"}
    if wanted and not strings:
        problems.append(f"{path}: not a file of a custom manager")
    found = {}
    for s in strings:
        for m in s.finditer(text):
            found[re.search(r"(\w+_VERSION)[=:]", m.group(0)).group(1)] = m.groupdict()
    for name in sorted(wanted - found.keys()):
        problems.append(f"{path}: {name} has no # renovate: line above it")
    for name, groups in sorted(found.items()):
        if not groups.get("datasource") or not groups.get("depName"):
            problems.append(f"{path}: {name} names no datasource or depName")
    if path == "docker/Dockerfile" and not (found.get("MYSQL_VERSION") or {}).get("currentDigest"):
        problems.append(f"{path}: the MySQL digest does not move with its version")
print("\n".join(problems))
sys.exit(1 if problems else 0)
'
  [ "$status" -eq 0 ] || fail "$output"
}

@test "renovate-config-validator accepts the config" {
  # Renovate is a Node package, not part of the test setup: the bats job skips
  # this, .github/workflows/renovate-config.yml runs it on every change.
  command -v renovate-config-validator >/dev/null || skip "renovate-config-validator is not installed"
  run renovate-config-validator --strict --no-global "$CONFIG"
  [ "$status" -eq 0 ] || fail "$output"
}
