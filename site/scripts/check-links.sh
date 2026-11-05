#!/usr/bin/env bash
#
# Check the links of the built documentation site that the VitePress build
# does not: print each broken one with its page and exit 1.
#
# - A link relative to the repository. VitePress makes the links of the site's
#   own pages absolute, so such a link comes from a README section a page
#   includes, written for GitHub, that siteHref (site/.vitepress/links.ts) left
#   as it was: a path the repository does not have, or a section on a page that
#   names no `source`. It leads nowhere on the site, while GitHub renders the
#   file fine, and the build takes a link to a file that is not a page for an
#   asset. A link relative to the page (`.` or `..`, alone or before `/`, `#`
#   or `?`) passes.
# - An anchor no element of its page has. The build checks that a linked page
#   exists, not that the heading does; a README heading that was renamed, or
#   whose anchor differs between GitHub and VitePress, would go unnoticed.
#
# The build job of site.yml runs it on what it built.
#
#   site/scripts/check-links.sh site/.vitepress/dist
set -euo pipefail

dir="${1:-}"
[ -n "$dir" ] || { echo "usage: check-links.sh DIR" >&2; exit 2; }
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
relative=$({ grep -vE "$pass" <<<"$hrefs" || true; } | sed 's|^\./||' | LC_ALL=C sort -u)

# page_of PATH — the file that serves the site path PATH (clean URLs), or
# nothing.
page_of() {
  local p=${1#/} f
  p=${p%/}
  [ -n "$p" ] || { printf 'index.html\n'; return; }
  for f in "$p.html" "$p/index.html" "$p"; do
    [ -f "./$f" ] && { printf '%s\n' "$f"; return; }
  done
  return 0
}

# PAGE, TARGET and ANCHOR of each link to an anchor on this site: on the page
# itself (`#a`, TARGET empty) or on another one (`/path#a`); a query before
# the anchor does not change the page. The fields are
# separated by the unit separator: `read` folds a run of tabs into one, which
# would lose an empty TARGET.
sep=$'\x1f'
anchors=$(sed -nE "s/^\.\/([^:]*):href=[\"'](\/[^\"'#?]*)?(\?[^\"'#]*)?#([^\"']+)[\"']$/\1${sep}\2${sep}\4/p" <<<"$hrefs" | LC_ALL=C sort -u)
missing=""
while IFS=$sep read -r page target anchor; do
  [ -n "$page" ] || continue
  file=$page
  [ -z "$target" ] || file=$(page_of "$target")
  # A link to a page that does not exist is the build's to report.
  [ -n "$file" ] && [ -f "./$file" ] || continue
  grep -qF -- " id=\"$anchor\"" "./$file" || missing+="$page: ${target}#$anchor"$'\n'
done <<<"$anchors"

status=0
if [ -n "$relative" ]; then
  sed 's/^/link relative to the repository, leads nowhere on the site: /' <<<"$relative" >&2
  status=1
fi
if [ -n "$missing" ]; then
  printf '%s' "$missing" | sed 's/^/anchor without a target on its page: /' >&2
  status=1
fi
exit "$status"
