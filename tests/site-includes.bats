#!/usr/bin/env bats
#
# The documentation site (site/) shows sections of README.md, chart/README.md
# and other files by VitePress include instead of a copy. A broken include
# fails quietly: a missing file renders nothing, and a missing region renders
# the whole file. The chart's messages, values.yaml and both READMEs link to
# the site's pages by address, which nothing else checks before the site is
# live, so a renamed page or heading would leave them pointing nowhere.

setup() {
  load helpers/common
  load helpers/site
}

@test "every include names a file that exists, and a region it has once" {
  local page target file name lines
  while IFS= read -r page; do
    while IFS= read -r target; do
      file=$(resolve "$page" "${target%%#*}")
      [ -f "$file" ] || fail "$page: $target: no such file"
      [ "$target" != "${target%%#*}" ] || continue
      name=${target#*#}
      lines=$(region_lines "$file" "$name")
      [ "$(grep -c '^start' <<<"$lines")" -eq 1 ] && [ "$(grep -c '^end' <<<"$lines")" -eq 1 ] \
        || fail "$page: $target: the region is not marked exactly once: $lines"
      [ "$(awk '$1 == "start" { print $2 }' <<<"$lines")" -lt "$(awk '$1 == "end" { print $2 }' <<<"$lines")" ] \
        || fail "$page: $target: the region ends before it starts"
      [ -n "$(region "$file" "$name" | tr -d '[:space:]')" ] || fail "$page: $target: the region is empty"
    done < <(includes "$page")
  done < <(site_pages)
}

@test "the includes are found: the site includes README.md, chart/README.md and whole files" {
  local all
  all=$(site_pages | while IFS= read -r p; do includes "$p"; done)
  grep -qx '\.\./\.\./README\.md#quick-start' <<<"$all" || fail "$all"
  grep -qx '\.\./\.\./chart/README\.md#parameters' <<<"$all" || fail "$all"
  grep -qx '\.\./\.\./CHANGELOG\.md' <<<"$all" || fail "$all"
}

@test "every region of README.md and chart/README.md is closed and shown on the site" {
  local file name all
  all=$(included)
  grep -qx 'chart/README\.md#parameters' <<<"$all" || fail "$all"
  for file in README.md chart/README.md; do
    while IFS= read -r name; do
      [ "$(region_lines "$REPO_ROOT/$file" "$name" | grep -c '^end')" -eq 1 ] || fail "$file: region $name is not closed"
      grep -qxF "$file#$name" <<<"$all" || fail "$file: region $name is on no page of the site"
    done < <(sed -nE 's/^<!-- #region ([^ ]+) -->$/\1/p' "$REPO_ROOT/$file")
  done
}

@test "every file a code snippet imports exists" {
  local page target n=0
  while IFS= read -r page; do
    while IFS= read -r target; do
      n=$((n + 1))
      [ -f "$(resolve "$page" "$target")" ] || fail "$page: <<< $target: no such file"
    done < <(snippets "$page")
  done < <(site_pages)
  [ "$n" -gt 0 ] || fail "no snippet found"
}

@test "every address of the site in the repository names a page and a heading that exist" {
  local url path anchor page n=0
  while IFS= read -r url; do
    n=$((n + 1))
    path=${url#"$SITE_URL"}; path=${path%%#*}; path=${path#/}
    anchor=""; [ "$url" = "${url%%#*}" ] || anchor=${url#*#}
    case "$path" in
      "" | */) page="${path}index.md" ;;
      *) page="$path.md" ;;
    esac
    [ -f "$SITE/$page" ] || fail "$url: no page site/$page"
    [ -z "$anchor" ] || anchors "$page" | grep -qxF -- "$anchor" || fail "$url: no heading #$anchor on site/$page"
  # A backslash ends an address too: in chart/values.schema.json a line break
  # right after one is the escape \n.
  done < <(git -C "$REPO_ROOT" grep -hoE "$SITE_URL[^][:space:])\"'\`<>,;*\\]*" -- ':!site' | sed 's/\.$//' | sort -u)
  [ "$n" -gt 10 ] || fail "only $n addresses found"
}
