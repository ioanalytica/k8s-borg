#!/usr/bin/env bash
#
# Fail on a link of the built documentation site that is relative to the
# repository: print each one with its page and exit 1. VitePress makes the links
# of the site's own pages absolute, so such a link comes from a file the site
# includes, written for GitHub, that siteHref (site/.vitepress/links.ts) left as
# it was: a repository path it missed (#99) or one the repository does not
# have. It leads nowhere on the site, while GitHub renders the file fine. A link
# relative to the page (`.` or `..`, alone or before `/`, `#` or `?`) is one
# siteHref leaves alone on purpose, and passes.
#
# The build job of site.yml runs it on what it built.
#
#   scripts/site-relative-links.sh site/.vitepress/dist
set -euo pipefail

dir="${1:-}"
[ -n "$dir" ] || { echo "usage: site-relative-links.sh DIR" >&2; exit 2; }
[ -d "$dir" ] || { echo "no such directory: $dir" >&2; exit 2; }
cd "$dir"
[ -n "$(find . -name '*.html' | head -1)" ] || { echo "no pages in $dir" >&2; exit 2; }

# PAGE:href="…" for each link, quoted either way; not data-href or the like.
# grep finding none is no error.
hrefs=$(grep -roE --include='*.html' "(^|[[:space:]])href=(\"[^\"]*\"|'[^']*')" . \
  | sed -E 's/^([^:]*):[[:space:]]*/\1:/') || [ $? -eq 1 ]
# An absolute path, an anchor, a query or an empty link (the page itself), an
# address with a scheme and a link relative to the page pass.
pass=":href=[\"'](/|#|\\?|[\"']|[a-zA-Z][a-zA-Z0-9+.-]*:|\\.\\.?([/#?]|[\"']))"
links=$({ grep -vE "$pass" <<<"$hrefs" || true; } | sed 's|^\./||' | LC_ALL=C sort -u)

if [ -n "$links" ]; then
  sed 's/^/link relative to the repository, leads nowhere on the site: /' <<<"$links" >&2
  exit 1
fi
