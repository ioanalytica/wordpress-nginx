// Copyright IO ANALYTICA. SPDX-License-Identifier: Apache-2.0
//
// What the site makes of the text it includes from the repository: its links
// and its heading levels. Apart from config.mts, which needs VitePress to
// load: site/tests/site-test.sh runs siteHref with node alone.
import { existsSync, statSync } from 'node:fs';
import { dirname, posix, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { MarkdownRenderer } from 'vitepress';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
export const siteUrl = 'https://wordpress-nginx.ioanalytica.com';
export const repoUrl = 'https://github.com/ioanalytica/wordpress-nginx';

// Files and README sections with a page of their own on the site: a link to
// them goes there. A heading's anchor differs between GitHub and VitePress
// where it holds a dot, so such a section names its anchor on the page.
const sitePages: Record<string, string> = {
  'CONTRIBUTING.md': '/reference/contributing',
  'SECURITY.md': '/security/reporting',
  'chart/CHANGELOG.md': '/reference/changelog',
  'chart/README.md#chart-versions': '/reference/versioning',
  'chart/README.md#php-execution-allowlist': '/security/php-execution-allowlist',
  'chart/README.md#to-71408': '/operations/upgrading#to-7-1-408',
  'examples/k3d/README.md': '/guide/try-locally',
};

// Pages include sections of README.md and chart/README.md, and the changelog,
// CONTRIBUTING.md and SECURITY.md whole. Their links are written for GitHub:
// relative to the file they stand in, or to this site by its full address. A
// page names that file as `source` in its frontmatter. On the site, a link to
// the repository leads to GitHub, or to the page that shows the file or
// section; an address of the site stays on the site. An address with a scheme
// and an absolute path stay as they are, and so does everything on a page
// without a source: its links are the site's own.
export function siteHref(href: string, source?: string): string {
  if (href === siteUrl || href.startsWith(`${siteUrl}/`) || href.startsWith(`${siteUrl}#`)) {
    const rest = href.slice(siteUrl.length);
    return rest.startsWith('/') ? rest : `/${rest}`;
  }
  if (!source || /^[a-z][a-z\d+.-]*:/i.test(href) || /^[/?]/.test(href)) return href;
  if (href.startsWith('#')) return sitePages[source + href] ?? href;
  const [target, hash] = href.split('#', 2);
  const anchor = hash ? `#${hash}` : '';
  const path = posix.normalize(posix.join(posix.dirname(source), target));
  if (path === '..' || path.startsWith('../')) return href;
  const file = path.replace(/\/$/, '');
  if (sitePages[file + anchor]) return sitePages[file + anchor];
  if (sitePages[file]) return sitePages[file] + anchor;
  const onDisk = resolve(repoRoot, file);
  if (!existsSync(onDisk)) return href;
  const kind = statSync(onDisk).isDirectory() ? 'tree' : 'blob';
  return `${repoUrl}/${kind}/main/${file === '.' ? '' : file}${anchor}`.replace(/\/(#|$)/, '$1');
}

export function repositoryLinks(md: MarkdownRenderer) {
  md.core.ruler.push('wordpress-nginx-repository-links', (state) => {
    const source = state.env.frontmatter?.source as string | undefined;
    for (const block of state.tokens) {
      for (const token of block.children ?? []) {
        const href = token.type === 'link_open' && token.attrGet('href');
        if (href) token.attrSet('href', siteHref(href, source));
      }
    }
  });
}

// headingShift LEVELS — how far the headings below a page's title move up: a
// README section sits two or three levels deep in its file, and its
// subsections with it. On the page that shows it they follow the title
// directly, so the shallowest of them becomes a second-level heading and the
// others keep their distance to it.
export function headingShift(levels: number[]): number {
  const below = levels.filter((level) => level > 1);
  return below.length ? Math.max(0, Math.min(...below) - 2) : 0;
}

// Runs before the rules that give headings their anchors and collect the
// page's outline, so both see the levels the page shows.
export function pageHeadings(md: MarkdownRenderer) {
  md.core.ruler.after('inline', 'wordpress-nginx-page-headings', (state) => {
    const headings = state.tokens.filter((t) => t.type === 'heading_open' || t.type === 'heading_close');
    const shift = headingShift(headings.map((t) => Number(t.tag.slice(1))));
    if (!shift) return;
    for (const token of headings) {
      const level = Number(token.tag.slice(1));
      if (level === 1) continue;
      token.tag = `h${level - shift}`;
      token.markup = '#'.repeat(level - shift);
    }
  });
}
