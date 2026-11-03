#!/usr/bin/env bats
#
# The documentation site shows README.md, chart/README.md, CONTRIBUTING.md and
# other files of the repository, whose links are written for GitHub. siteHref
# (site/.vitepress/links.ts) gives each link its target on the site: a
# repository path its GitHub address or the page that shows the file, an
# address of the site a path on it. A wrong target shows only on the live
# site: GitHub renders the files fine, and the site build checks no link that
# leaves the site (#99).

setup() {
  load helpers/common
  load helpers/site
  REPO_URL=https://github.com/ioanalytica/k8s-borg
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
