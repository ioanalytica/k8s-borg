#!/usr/bin/env bats
#
# The documentation site shows README.md, chart/README.md, CONTRIBUTING.md and
# other files of the repository, whose links are written for GitHub. siteHref
# (site/.vitepress/links.ts) gives each link its target on the site: a
# repository path its GitHub address or the page that shows the file, an
# address of the site a path on it. A wrong target shows only on the live
# site: GitHub renders the files fine, and the site build checks no link that
# leaves the site (#99). The site build runs scripts/site-relative-links.sh
# on what it built, which fails on a link left relative to the repository.

bats_require_minimum_version 1.5.0   # run --separate-stderr

setup() {
  load helpers/common
  load helpers/site
  REPO_URL=https://github.com/ioanalytica/k8s-borg
  CHECK="$REPO_ROOT/scripts/site-relative-links.sh"
  DIST="$BATS_TEST_TMPDIR/dist"
}

# targets HREF TARGET… — siteHref makes each HREF its TARGET.
targets() {
  local hrefs=() want got
  want=$(while [ $# -gt 0 ]; do printf '%s\t%s\n' "$1" "$2"; shift 2; done)
  while IFS=$'\t' read -r href _; do hrefs+=("$href"); done <<<"$want"
  got=$(paste <(printf '%s\n' "${hrefs[@]}") <(site_href "${hrefs[@]}"))
  [ "$got" = "$want" ] || fail "$(diff <(echo "$want") <(echo "$got"))"
}

@test "a repository path that starts with a dot leads to GitHub like any other" {
  targets \
    .github/renovate.json "$REPO_URL/blob/main/.github/renovate.json" \
    .github/workflows/site.yml#L1 "$REPO_URL/blob/main/.github/workflows/site.yml#L1" \
    .coderabbit.yaml "$REPO_URL/blob/main/.coderabbit.yaml" \
    .github "$REPO_URL/tree/main/.github" \
    .github/workflows/ "$REPO_URL/tree/main/.github/workflows" \
    .github/workflows#readme "$REPO_URL/tree/main/.github/workflows#readme" \
    .no-such-file .no-such-file
}

@test "a repository path leads to GitHub, or to the page that shows the file" {
  targets \
    chart/values.yaml "$REPO_URL/blob/main/chart/values.yaml" \
    examples/ "$REPO_URL/tree/main/examples" \
    CONTRIBUTING.md /reference/contributing \
    CHANGELOG.md#unreleased /reference/changelog#unreleased \
    chart/README.md#parameters /reference/parameters \
    no-such-file.md no-such-file.md
}

@test "a link relative to the page, an anchor, an absolute path and an address with a scheme stay" {
  targets \
    ./restore ./restore \
    ../reference/parameters#borg ../reference/parameters#borg \
    . . \
    .. .. \
    .#quick-start .#quick-start \
    ..#borg ..#borg \
    '.?tab=1' '.?tab=1' \
    '#quick-start' '#quick-start' \
    /guide/install /guide/install \
    https://example.com/x https://example.com/x \
    mailto:security@example.com mailto:security@example.com
}

@test "an address of the site becomes a path on it" {
  targets \
    "$SITE_URL" / \
    "$SITE_URL/" / \
    "$SITE_URL/guide/install#quick-start" /guide/install#quick-start \
    "${SITE_URL}.example/" "${SITE_URL}.example/"
}

# page FILE HREF… — a built page FILE of $DIST with a link to each HREF.
page() {
  local file=$1 href
  shift
  mkdir -p "$(dirname "$DIST/$file")"
  for href in "$@"; do printf '<a href="%s">x</a>\n' "$href"; done >"$DIST/$file"
}

@test "the built site's link check passes absolute paths, anchors, addresses with a scheme and links relative to the page" {
  page index.html / /guide/install '#features' '?tab=1' '' https://example.com/x mailto:security@example.com
  page operations/restore.html ./disaster-recovery ../reference/parameters#borg . .. .#top '..?q=1'
  page reference/contributing.html "$REPO_URL/blob/main/.github/renovate.json" /reference/changelog#unreleased
  printf 'href="not/a/page"\n' >"$DIST/app.js"
  run --separate-stderr "$CHECK" "$DIST"
  [ "$status" -eq 0 ] || fail "status $status: $stderr"
  [ -z "$output$stderr" ] || fail "$output$stderr"
}

@test "a link relative to the repository fails the built site's link check, named with its page" {
  page index.html /guide/
  page reference/contributing.html .github/renovate.json /reference/changelog ../ok
  page guide/install.html chart/values.yaml examples/ ..github
  run --separate-stderr "$CHECK" "$DIST"
  [ "$status" -eq 1 ] || fail "status $status: $stderr"
  [ "$stderr" = 'link relative to the repository, leads nowhere on the site: guide/install.html:href="..github"
link relative to the repository, leads nowhere on the site: guide/install.html:href="chart/values.yaml"
link relative to the repository, leads nowhere on the site: guide/install.html:href="examples/"
link relative to the repository, leads nowhere on the site: reference/contributing.html:href=".github/renovate.json"' ] || fail "$stderr"
}

@test "the built site's link check without a directory of pages is a usage error" {
  run --separate-stderr "$CHECK"
  [ "$status" -eq 2 ] || fail "no argument: status $status"
  mkdir -p "$DIST"
  run --separate-stderr "$CHECK" "$DIST"
  [ "$status" -eq 2 ] || fail "no pages: status $status"
  run --separate-stderr "$CHECK" "$DIST/missing"
  [ "$status" -eq 2 ] || fail "no directory: status $status"
}
