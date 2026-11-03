// Copyright IO ANALYTICA. SPDX-License-Identifier: AGPL-3.0-only
import { copyFileSync, existsSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineConfigWithTheme, type DefaultTheme, type MarkdownRenderer } from 'vitepress';

const siteRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const repoRoot = resolve(siteRoot, '..');
const siteUrl = 'https://k8s-borg.ioanalytica.com';
const repoUrl = 'https://github.com/ioanalytica/k8s-borg';

// The chart icon doubles as the favicon; it is read from the repository root
// instead of being copied into public/.
const icon = resolve(repoRoot, 'icon.png');

export interface ThemeConfig extends DefaultTheme.Config {
  chartVersion: string;
}

const chartVersion =
  readFileSync(resolve(repoRoot, 'chart/Chart.yaml'), 'utf8').match(/^version:\s*(\S+)/m)?.[1] ?? '';

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
function siteHref(href: string): string {
  if (href === siteUrl || href.startsWith(`${siteUrl}/`) || href.startsWith(`${siteUrl}#`)) {
    return href.slice(siteUrl.length) || '/';
  }
  if (/^[a-z][a-z\d+.-]*:/i.test(href) || /^[/#.]/.test(href)) return href;
  if (sitePages[href]) return sitePages[href];
  const [path, hash] = href.split('#', 2);
  const anchor = hash ? `#${hash}` : '';
  if (sitePages[path]) return sitePages[path] + anchor;
  const file = resolve(repoRoot, path);
  if (!existsSync(file)) return href;
  const kind = statSync(file).isDirectory() ? 'tree' : 'blob';
  return `${repoUrl}/${kind}/main/${path.replace(/\/$/, '')}${anchor}`;
}

function repositoryLinks(md: MarkdownRenderer) {
  md.core.ruler.push('k8s-borg-repository-links', (state) => {
    for (const block of state.tokens) {
      for (const token of block.children ?? []) {
        const href = token.type === 'link_open' && token.attrGet('href');
        if (href) token.attrSet('href', siteHref(href));
      }
    }
  });
}

// ```mermaid blocks render in the browser, from the mermaid package bundled
// with the site (theme/Mermaid.vue).
function mermaidFences(md: MarkdownRenderer) {
  const fence = md.renderer.rules.fence!;
  md.renderer.rules.fence = (tokens, idx, options, env, self) => {
    const token = tokens[idx];
    if (token.info.trim() !== 'mermaid') return fence(tokens, idx, options, env, self);
    return `<ClientOnly><Mermaid code="${encodeURIComponent(token.content)}" /></ClientOnly>`;
  };
}

export default defineConfigWithTheme<ThemeConfig>({
  lang: 'en-US',
  title: 'k8s-borg',
  description: 'BorgBackup for Kubernetes: one Helm chart backs up nodes, the cluster datastore, databases and S3 buckets into Borg repositories.',
  cleanUrls: true,
  head: [['link', { rel: 'icon', type: 'image/png', href: '/favicon.png' }]],
  markdown: {
    config(md) {
      md.use(repositoryLinks);
      md.use(mermaidFences);
    },
  },
  vite: {
    // Mermaid's diagram types are large and load only on a page with a diagram.
    build: { chunkSizeWarningLimit: 2000 },
    plugins: [
      {
        name: 'k8s-borg-favicon',
        configureServer(server) {
          server.middlewares.use('/favicon.png', (_req, res) => {
            res.setHeader('Content-Type', 'image/png');
            res.end(readFileSync(icon));
          });
        },
      },
    ],
  },
  buildEnd(config) {
    copyFileSync(icon, join(config.outDir, 'favicon.png'));
  },
  themeConfig: {
    chartVersion,
    siteTitle: 'k8s-borg',
    nav: [
      { text: 'Home', link: '/' },
      { text: 'Install', link: '/guide/install' },
      { text: 'Configure', link: '/guide/configuration' },
      { text: 'GitHub', link: repoUrl },
    ],
    sidebar: [
      {
        text: 'Getting Started',
        items: [
          { text: 'Introduction', link: '/guide/' },
          { text: 'Install', link: '/guide/install' },
          { text: 'Configuration', link: '/guide/configuration' },
        ],
      },
      {
        text: 'Features',
        items: [
          { text: 'Node backups', link: '/features/node-backups' },
          { text: 'Cluster datastore', link: '/features/datastore' },
          { text: 'SQLite databases', link: '/features/sqlite' },
          { text: 'Database dumps', link: '/features/databases' },
          { text: 'MongoDB', link: '/features/mongodb' },
          { text: 'Redis and Valkey', link: '/features/redis-valkey' },
          { text: 'S3 buckets', link: '/features/s3' },
          { text: 'Repository server', link: '/features/repository-server' },
          { text: 'External copy', link: '/features/external-copy' },
          { text: 'Borg 1 and Borg 2', link: '/features/borg-versions' },
          { text: 'Borg UI agents', link: '/features/borg-ui-agents' },
          { text: 'Borg UI server', link: '/features/borg-ui-server' },
        ],
      },
      {
        text: 'Security',
        items: [
          { text: 'Security posture', link: '/security/' },
          { text: 'What it talks to', link: '/security/connections' },
          { text: 'Verify releases', link: '/security/verify' },
          { text: 'Report a vulnerability', link: '/security/reporting' },
        ],
      },
      {
        text: 'Operations',
        items: [
          { text: 'Restore', link: '/operations/restore' },
          { text: 'Disaster recovery', link: '/operations/disaster-recovery' },
          { text: 'Upgrading', link: '/operations/upgrading' },
          { text: 'Troubleshooting', link: '/operations/troubleshooting' },
        ],
      },
      {
        text: 'Reference',
        items: [
          { text: 'Parameters', link: '/reference/parameters' },
          { text: 'Environment variables', link: '/reference/environment' },
          { text: 'Versioning', link: '/reference/versioning' },
          { text: 'Development', link: '/reference/development' },
          { text: 'Contributing', link: '/reference/contributing' },
          { text: 'Changelog', link: '/reference/changelog' },
          { text: 'License', link: '/reference/license' },
        ],
      },
    ],
    socialLinks: [{ icon: 'github', link: repoUrl }],
    search: { provider: 'local' },
    // A page made of one file's sections names that file as `source`, so the
    // edit link opens what holds its text. The function runs in the browser,
    // without this module's constants.
    editLink: {
      pattern: ({ filePath, frontmatter }) =>
        `https://github.com/ioanalytica/k8s-borg/edit/main/${frontmatter.source ?? `site/${filePath}`}`,
      text: 'Edit this page on GitHub',
    },
    footer: {
      message: 'Distributed under the AGPL-3.0-only license.',
      copyright: 'Copyright © 2024-present IO ANALYTICA',
    },
    outline: { level: [2, 3], label: 'On this page' },
  },
});
