# shellcheck shell=bash
#
# Readers for the documentation site (site/) and what its pages include, for
# site-includes.bats, site-links.bats and site-workflow.bats.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SITE="$REPO_ROOT/site"
# shellcheck disable=SC2034  # read by the tests that load this file
SITE_URL=https://k8s-borg.ioanalytica.com

# site_pages — the site's pages, relative to site/.
site_pages() {
  (cd "$SITE" && find . -name node_modules -prune -o -name '*.md' -print) | sed 's|^\./||' | sort
}

# site_href HREF… — what the site makes of each link HREF, one per line:
# siteHref of site/.vitepress/links.ts, run by node (TypeScript needs >= 22.18).
site_href() {
  node --input-type=module -e '
    import { pathToFileURL } from "node:url";
    const [file, ...hrefs] = process.argv.slice(1);
    const { siteHref } = await import(pathToFileURL(file).href);
    for (const href of hrefs) console.log(siteHref(href));' "$SITE/.vitepress/links.ts" "$@"
}

# includes PAGE — the target of each include of PAGE, as written (path[#region]).
includes() {
  sed -nE 's/.*<!--[[:space:]]*@include:[[:space:]]*(.*[^[:space:]])[[:space:]]*-->.*/\1/p' "$SITE/$1"
}

# resolve PAGE PATH — the file an include or snippet of PAGE names: `@/` is
# site/, anything else is relative to the page.
resolve() {
  case "$2" in
    @/*) printf '%s\n' "$SITE/${2#@/}" ;;
    *) printf '%s\n' "$(dirname "$SITE/$1")/$2" ;;
  esac
}

# region_lines FILE NAME — the line numbers of NAME's start and end markers.
region_lines() {
  awk -v start="<!-- #region $2 -->" -v end="<!-- #endregion $2 -->" '
    $0 == start { print "start", NR } $0 == end { print "end", NR }' "$1"
}

# region FILE NAME — the lines between NAME's markers.
region() {
  awk -v start="<!-- #region $2 -->" -v end="<!-- #endregion $2 -->" '
    $0 == end { exit } on { print } $0 == start { on = 1 }' "$1"
}

# page_text PAGE — PAGE with each include replaced by what it includes.
page_text() {
  local line target file
  while IFS= read -r line; do
    target=$(sed -nE 's/^<!--[[:space:]]*@include:[[:space:]]*(.*[^[:space:]])[[:space:]]*-->$/\1/p' <<<"$line")
    if [ -z "$target" ]; then printf '%s\n' "$line"; continue; fi
    file=$(resolve "$1" "${target%%#*}")
    if [ "$target" = "${target%%#*}" ]; then cat "$file"; else region "$file" "${target#*#}"; fi
  done <"$SITE/$1"
}

# anchors PAGE — the heading ids of PAGE: an explicit {#id}, or the heading
# slugified as VitePress does it for plain ASCII headings.
anchors() {
  page_text "$1" | awk '
    /^```/ { code = !code; next }
    code || !/^#+ / { next }
    {
      h = $0; sub(/^#+ +/, "", h)
      if (match(h, /\{#[^}]+\}[[:space:]]*$/)) { h = substr(h, RSTART + 2); sub(/\}[[:space:]]*$/, "", h); print h; next }
      h = tolower(h); gsub(/[^a-z0-9]+/, "-", h); gsub(/^-+|-+$/, "", h); print h
    }'
}

# included — every include of the site as FILE#REGION, FILE relative to the
# repository.
included() {
  local page target path file
  site_pages | while IFS= read -r page; do
    includes "$page" | while IFS= read -r target; do
      path=${target%%#*}
      file=$(resolve "$page" "$path")
      file="$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")"
      printf '%s%s\n' "${file#"$REPO_ROOT/"}" "${target#"$path"}"
    done
  done
}

# snippets PAGE — the file of each code snippet PAGE imports (`<<< path`).
snippets() {
  sed -nE 's/^<<< +([^ {#[]+).*/\1/p' "$SITE/$1"
}

# site_sources — every file outside site/ that the site shows or reads,
# relative to the repository: the files pages include, the files they import
# as code, and the files the VitePress config reads.
site_sources() {
  local page path file
  {
    included | sed 's/#.*//'
    site_pages | while IFS= read -r page; do
      snippets "$page" | while IFS= read -r path; do
        file=$(resolve "$page" "$path")
        file="$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")"
        printf '%s\n' "${file#"$REPO_ROOT/"}"
      done
    done
    sed -nE "s/.*resolve\(repoRoot, '([^']+)'\).*/\1/p" "$SITE/.vitepress/config.mts"
  } | grep -v '^site/' | sort -u
}
