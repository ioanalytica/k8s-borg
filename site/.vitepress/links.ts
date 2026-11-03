// Copyright IO ANALYTICA. SPDX-License-Identifier: AGPL-3.0-only
//
// The links of the site's pages. Apart from config.mts, which needs VitePress
// to load: tests/site-links.bats runs siteHref with node alone.
import { existsSync, statSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { MarkdownRenderer } from 'vitepress';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const siteUrl = 'https://k8s-borg.ioanalytica.com';
export const repoUrl = 'https://github.com/ioanalytica/k8s-borg';

// Files with a page of their own on the site: a link to them goes there.
const sitePages: Record<string, string> = {
  'CHANGELOG.md': '/reference/changelog',
  'CONTRIBUTING.md': '/reference/contributing',
  'SECURITY.md': '/security/reporting',
  'chart/README.md#parameters': '/reference/parameters',
  'chart/README.md#security-posture': '/security/',
};

// Pages include sections of README.md, chart/README.md and other files of the
// repository, whose links are written for GitHub: relative to the repository
// root, or to this site by its full address. On the site, the first lead to
// GitHub (or to the page that holds the file), the second stay on the site.
// An address with a scheme, an absolute path, an anchor and a link relative to
// the page (`.` or `..`, alone or before `/`, `#` or `?`) stay as they are; a
// repository path may start with a dot itself (`.github/`).
export function siteHref(href: string): string {
  if (href === siteUrl || href.startsWith(`${siteUrl}/`) || href.startsWith(`${siteUrl}#`)) {
    return href.slice(siteUrl.length) || '/';
  }
  if (/^[a-z][a-z\d+.-]*:/i.test(href) || /^(?:[/#]|\.\.?(?:[/#?]|$))/.test(href)) return href;
  if (sitePages[href]) return sitePages[href];
  const [path, hash] = href.split('#', 2);
  const anchor = hash ? `#${hash}` : '';
  if (sitePages[path]) return sitePages[path] + anchor;
  const file = resolve(repoRoot, path);
  if (!existsSync(file)) return href;
  const kind = statSync(file).isDirectory() ? 'tree' : 'blob';
  return `${repoUrl}/${kind}/main/${path.replace(/\/$/, '')}${anchor}`;
}

export function repositoryLinks(md: MarkdownRenderer) {
  md.core.ruler.push('k8s-borg-repository-links', (state) => {
    for (const block of state.tokens) {
      for (const token of block.children ?? []) {
        const href = token.type === 'link_open' && token.attrGet('href');
        if (href) token.attrSet('href', siteHref(href));
      }
    }
  });
}
