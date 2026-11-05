// Copyright IO ANALYTICA. SPDX-License-Identifier: Apache-2.0
import { copyFileSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineConfigWithTheme, type DefaultTheme } from 'vitepress';
import { pageHeadings, repoUrl, repositoryLinks } from './links';

const siteRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const repoRoot = resolve(siteRoot, '..');

// The chart icon doubles as the favicon; it is read from the repository root
// instead of being copied into public/.
const icon = resolve(repoRoot, 'icon.png');

export interface ThemeConfig extends DefaultTheme.Config {
  idxVersion: string;
}

// The wordpress-idx release the chart pins; pages link to that release's
// files instead of copying them. The chart's own version is not shown: the
// site is built from main, where a version can stand before its release is
// published.
const idxVersion =
  readFileSync(resolve(repoRoot, 'chart/Chart.yaml'), 'utf8').match(/^\s*idxImageTag:\s*"?([^"\s]+)"?/m)?.[1] ?? '';

export default defineConfigWithTheme<ThemeConfig>({
  lang: 'en-US',
  title: 'wordpress-nginx',
  description:
    'A Helm chart and image for WordPress on NGINX and PHP-FPM on Kubernetes, with the values keys of the Bitnami WordPress chart, hardening, file-integrity monitoring and a full-text search sidecar.',
  cleanUrls: true,
  // No `base`: the site is served from the root of its own domain (siteUrl in
  // links.ts), set as the custom domain in the repository's Pages settings,
  // not from the project path under github.io.
  head: [['link', { rel: 'icon', type: 'image/png', href: '/favicon.png' }]],
  markdown: {
    config(md) {
      md.use(repositoryLinks);
      md.use(pageHeadings);
    },
  },
  vite: {
    plugins: [
      {
        name: 'wordpress-nginx-favicon',
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
    idxVersion,
    siteTitle: 'wordpress-nginx',
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
          { text: 'Try it locally', link: '/guide/try-locally' },
          { text: 'Install', link: '/guide/install' },
          { text: 'Configuration', link: '/guide/configuration' },
          { text: 'Coming from the Bitnami chart', link: '/guide/migrating' },
        ],
      },
      {
        text: 'Features',
        items: [
          { text: 'Database', link: '/features/database' },
          { text: 'Cache', link: '/features/cache' },
          { text: 'Ingress and redirects', link: '/features/ingress' },
          { text: 'Plugins', link: '/features/plugins' },
          { text: 'Mail', link: '/features/mail' },
          { text: 'Search index', link: '/features/search-index' },
          { text: 'Use the index with an agent', link: '/features/search-index-agents' },
          { text: 'Metrics', link: '/features/metrics' },
        ],
      },
      {
        text: 'Security',
        items: [
          { text: 'Overview', link: '/security/' },
          { text: 'PHP execution allowlist', link: '/security/php-execution-allowlist' },
          { text: 'REST API hardening', link: '/security/rest-api-hardening' },
          { text: 'Denied paths and .htaccess', link: '/security/denied-paths' },
          { text: 'Security headers', link: '/security/headers' },
          { text: 'File-integrity monitoring', link: '/security/file-integrity-monitoring' },
          { text: 'Update policy', link: '/security/update-policy' },
          { text: 'Report a vulnerability', link: '/security/reporting' },
        ],
      },
      {
        text: 'Operations',
        items: [
          { text: 'Upgrading', link: '/operations/upgrading' },
          { text: 'Applying NGINX changes', link: '/operations/nginx-changes' },
          { text: 'Troubleshooting', link: '/operations/troubleshooting' },
        ],
      },
      {
        text: 'Reference',
        items: [
          { text: 'Parameters', link: '/reference/parameters' },
          { text: 'The image', link: '/reference/image' },
          { text: 'Versioning', link: '/reference/versioning' },
          { text: 'Changelog', link: '/reference/changelog' },
          { text: 'Contributing', link: '/reference/contributing' },
          { text: 'License', link: '/reference/license' },
        ],
      },
    ],
    socialLinks: [{ icon: 'github', link: repoUrl }],
    search: { provider: 'local' },
    // A page made of one file's sections names that file as `source`, so the
    // edit link opens what holds its text; a page with text of its own next
    // to such sections sets `editPage`. The function runs in the browser,
    // without this module's constants.
    editLink: {
      pattern: ({ filePath, frontmatter }) =>
        `https://github.com/ioanalytica/wordpress-nginx/edit/main/${
          frontmatter.source && !frontmatter.editPage ? frontmatter.source : `site/${filePath}`
        }`,
      text: 'Edit this page on GitHub',
    },
    footer: {
      message:
        'Distributed under the Apache-2.0 license. WordPress, NGINX, Bitnami and other names are trademarks of their owners; this project is not affiliated with or endorsed by them.',
      copyright: 'Copyright © 2024-present IO ANALYTICA',
    },
    outline: { level: [2, 3], label: 'On this page' },
  },
});
