#!/usr/bin/env bats
#
# chart/values.schema.json: Helm checks the values of every install, upgrade,
# template and lint against it, and Artifact Hub shows it as the values
# reference of the chart. It keeps step with values.yaml: every `## @param` is
# in it, every key in it is one of values.yaml, with the same default, and
# values.yaml passes it.
#
# It may refuse nothing a working release sets, so it is permissive on purpose:
#   - no `required`, no `additionalProperties: false`: the chart itself names a
#     removed section (app, config) and what replaced it;
#   - an `enum` only where validations.yaml refuses any other value;
#   - text also as a number, numbers also as text, as --set, --set-string and
#     Flux valuesFrom deliver them; switches also as 0/1 or text; fractions
#     where the consumer reads them; maps and lists also as an empty value of
#     the other kind ({}, [], ""), and as text where the chart renders them
#     through common.tplvalues.render;
#   - draft-07, which Helm knows in every version since 3.0.
# The schema lets such values through, it does not make the chart read them
# right: a switch given as the text "false" counts as on in a template's if, as
# before. The tests of the chart, the examples and the HelmReleases of our
# clusters all render with it. --skip-schema-validation needs Helm 3.16.

setup() {
  load helpers/common
  common_setup
  command -v helm >/dev/null || fail "helm is required for the chart tests"
  command -v jq >/dev/null || fail "jq is required for the schema tests"
  python3 -c 'import yaml' 2>/dev/null \
    || fail "python3 with PyYAML is required (apt-get install python3-yaml)"
  CHART_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/chart"
  SCHEMA="$CHART_DIR/values.schema.json"
  # values.yaml as Helm reads it: YAML 1.1, as PyYAML does.
  VALUES_JSON="$TMP/values.json"
  python3 -c 'import json, sys, yaml; json.dump(yaml.safe_load(open(sys.argv[1])), sys.stdout)' \
    "$CHART_DIR/values.yaml" >"$VALUES_JSON"
  VALUES="$TMP/base.yaml"
  cat >"$VALUES" <<'YAML'
borg:
  repoBase:
    value: "ssh://borg@backup.example.com/./cluster"
  passphrase:
    value: "test"
ssh:
  privateKey: "test"
  publicKey: "test"
  knownHosts: "test"
YAML
}

teardown() { common_teardown; }

render() { helm template rel "$CHART_DIR" -n backup -f "$VALUES" "$@"; }

# schema_jq FILTER — FILTER on the schema, with props: every property as
# {path, s}, path the list of keys, s its schema.
schema_jq() {
  jq -r --slurpfile v "$VALUES_JSON" '
    def props($pre): (.properties // {}) | to_entries[]
      | ($pre + [.key]) as $p | {path: $p, s: .value}, (.value | props($p));
    '"$1" "$SCHEMA"
}

# passes ARGS… — the chart renders with ARGS, schema and all.
passes() {
  run render "$@"
  [ "$status" -eq 0 ] || fail "refused: $* — $output"
}

@test "values.yaml passes the schema, a draft-07 JSON Schema Helm compiles" {
  [ "$(jq -r '."$schema"' "$SCHEMA")" = "http://json-schema.org/draft-07/schema#" ] \
    || fail "\$schema is $(jq -r '."$schema"' "$SCHEMA")"
  # helm lint compiles the schema against its meta-schema and checks
  # values.yaml with it.
  run helm lint "$CHART_DIR"
  [ "$status" -eq 0 ] || fail "$output"
}

@test "every @param of values.yaml is in the schema" {
  local params missing
  params="$(sed -n 's/^ *## @param \([^ ]*\).*/\1/p' "$CHART_DIR/values.yaml")"
  [ "$(wc -l <<<"$params")" -gt 200 ] || fail "only $(wc -l <<<"$params") @param lines found"
  missing="$(jq -rR --slurpfile s "$SCHEMA" 'split(".") as $p
      | select($s[0] | getpath($p | map(["properties", .]) | add) == null) | $p | join(".")' <<<"$params")"
  [ -z "$missing" ] || fail "not in values.schema.json: $missing"
}

@test "every key of the schema is a key of values.yaml" {
  local stray
  stray="$(schema_jq '[$v[0] | paths] as $have
      | props([]) | select(.path as $p | any($have[]; . == $p) | not) | .path | join(".")')"
  [ -z "$stray" ] || fail "in values.schema.json, not in values.yaml: $stray"
}

@test "every leaf of the schema has the default of values.yaml" {
  local wrong
  wrong="$(schema_jq 'props([]) | select(.s | has("properties") | not)
      | select(. as $e | ($e.s | has("default") | not) or $e.s.default != ($v[0] | getpath($e.path)))
      | .path | join(".")')"
  [ -z "$wrong" ] || fail "no default, or another one than values.yaml: $wrong"
}

@test "every key of the schema has a type and says what it is" {
  local bare
  bare="$(schema_jq 'props([]) | select((.s | has("type") | not) or ((.s.description // .s.title // "") == ""))
      | .path | join(".")')"
  [ -z "$bare" ] || fail "no type, or neither description nor title: $bare"
}

@test "the schema requires no key and refuses none it does not list" {
  [ "$(jq '[.. | objects | select(has("required") or .additionalProperties == false)] | length' "$SCHEMA")" = 0 ] \
    || fail "required or additionalProperties: false in values.schema.json"
  run render --set app.mode=agent
  [ "$status" -ne 0 ] || fail "rendered the removed app section"
  [[ $output == *'The `app` section has moved into `cluster`'* ]] || fail "$output"
  run render --set config.nodeInclude=x
  [ "$status" -ne 0 ] || fail "rendered the removed config section"
  [[ $output == *'The `config` section has moved into `node`/`cluster`'* ]] || fail "$output"
}

@test "an enum is exactly the list validations.yaml accepts" {
  local checks expected actual
  checks="$(sed -n 's/.*(has \.Values\.\([A-Za-z0-9.]*\) (list \(.*\))).*/\1 \2/p' "$CHART_DIR/templates/validations.yaml")"
  [ "$(wc -l <<<"$checks")" -ge 5 ] || fail "only these mode checks found: $checks"
  expected="$(jq -cR 'capture("^(?<path>[^ ]+) (?<list>.*)$") | {path, enum: [.list | scan("\"([^\"]*)\"")[0]]}' \
    <<<"$checks" | sort)"
  actual="$(schema_jq 'props([]) | select(.s | has("enum")) | {path: (.path | join(".")), enum: .s.enum} | tojson' | sort)"
  [ "$actual" = "$expected" ] || fail "schema: $actual"$'\n'"validations.yaml: $expected"
}

@test "a mode outside the list is refused by the schema, and by the chart without it" {
  run render --set cluster.mode=Agent
  [ "$status" -ne 0 ] || fail "rendered cluster.mode=Agent"
  refused_by_schema cluster.mode "$output" || fail "not refused by the schema: $output"
  run render --set cluster.mode=Agent --skip-schema-validation
  [ "$status" -ne 0 ] || fail "rendered cluster.mode=Agent without the schema"
  [[ $output == *'cluster.mode must be "legacy" or "agent" (got "Agent")'* ]] || fail "$output"
}

@test "values in the forms --set, --set-string and Flux deliver pass" {
  passes --set borgUI.redis.cacheTtlMinutes=720
  passes --set-string borgUI.redis.cacheTtlMinutes=720
  passes --set image.tag=2
  passes --set borg.passphrase.value=123456
  passes --set borgUI.oidc.clientId=379018067033786455
  passes --set repoServer.service.nodePort=30022
  passes --set-string borg.version=2
  passes --set-string borg.retention.daily=14
  passes --set-string borgUI.postgres.port=5432
  passes --set-string node.enabled=true
  # 0/1: the templates' if and the scripts (envbool) read them as switches.
  passes --set borg.backupMaintenance.prune=0
  passes --set node.enabled=1
  passes --set borg.checkSchedule.default=false
  passes --set repoServer.offsite.bwlimit=false
  passes --set repoServer.offsite.bwlimit=1024
  # Seconds that sqlite-copy reads as a float, and that sleep takes as they are.
  passes --set-json 'node.sqlite.busyTimeout=0.5'
  passes --set-json 'node.backupIntervalSeconds=1800.5'
  passes --set node.backupIntervalSeconds=30m
}

@test "maps and lists also pass empty as the other kind, and as text where the chart renders text" {
  passes --set-json 'cluster.tolerations={}'
  passes --set-json 'cluster.nodeSelector=[]'
  passes --set-json 'node.exclude={}'
  passes --set 'repoServer.resources='
  passes --set-string 'cluster.tolerations=- operator: Exists'
  passes --set-string 'commonLabels=team: ops'
  passes --set-string 'repoServer.nodeSelector=kubernetes.io/hostname: storage-node'
  passes --set-string 'repoServer.tolerations=- operator: Exists'
  passes --set-string 'repoServer.affinity=nodeAffinity: {}'
  passes --set-string 'repoServer.podAnnotations=team: ops'
}

@test "every value the chart renders through common.tplvalues.render may be text" {
  # The value of each such call (and of the labels, which go through
  # tplvalues.merge), as a values path: .Values.x.y itself, or the field of a
  # variable bound to a section ($rs := .Values.repoServer), named in the call
  # or by the `with` block around it.
  local templates paths missing
  templates="$CHART_DIR/templates"
  paths="$(
    grep -ho '\("value"\|"customLabels"\) \$\{0,1\}\.Values\.[A-Za-z0-9.]*' "$templates"/* \
      | sed 's/.*\.Values\.//'
    {
      grep -ho 'tplvalues.render" (dict "value" \$[a-z]*\.[A-Za-z0-9.]*' "$templates"/* \
        | sed 's/.*"value" \$\([a-z]*\)\.\(.*\)/\1 \2/'
      grep -h -B1 'tplvalues.render" (dict "value" \. ' "$templates"/* \
        | sed -n 's/.*{{- with \$\([a-z]*\)\.\([A-Za-z0-9.]*\) }}.*/\1 \2/p'
    } | while read -r var field; do
      section="$(grep -ho "[\$]$var := \.Values\.[A-Za-z0-9.]*" "$templates"/* | head -1 | sed 's/.*\.Values\.//')"
      [ -z "$section" ] || echo "$section.$field"
    done
  )"
  [ "$(sort -u <<<"$paths" | wc -l)" -ge 15 ] || fail "only these found: $paths"
  missing="$(sort -u <<<"$paths" | jq -rR --slurpfile s "$SCHEMA" 'split(".") as $p
      | ($s[0] | getpath($p | map(["properties", .]) | add)) as $c
      | select($c == null or (($c.type | if type == "array" then . else [.] end | index("string")) == null)
        or ($c | has("maxLength"))) | $p | join(".")')"
  [ -z "$missing" ] || fail "rendered as text by the chart, refused as text by the schema: $missing"
}

@test "a value the chart cannot use is refused" {
  run render --set-json 'node.include="R /node/etc"'
  [ "$status" -ne 0 ] && refused_by_schema node.include "$output" || fail "a text for node.include: $output"
  run render --set-json 'borgUI.enabled=["true"]'
  [ "$status" -ne 0 ] && refused_by_schema borgUI.enabled "$output" || fail "a list for borgUI.enabled: $output"
  run render --set-json 'borg.retention.daily=7.5'
  [ "$status" -ne 0 ] && refused_by_schema borg.retention.daily "$output" || fail "a fraction for borg.retention.daily: $output"
}

@test "the packaged chart carries the schema" {
  helm package "$CHART_DIR" -d "$TMP" >/dev/null
  tar -tzf "$TMP"/k8s-borg-*.tgz | grep -qx 'k8s-borg/values.schema.json' \
    || fail "values.schema.json is not in the package"
}
