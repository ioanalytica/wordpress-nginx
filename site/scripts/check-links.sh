#!/usr/bin/env bash
#
# Check the links of the built documentation site that the VitePress build
# does not: print each broken one with its page and exit 1.
#
# - A link to a page the site does not have. The build checks the links of the
#   Markdown text only, not those of the home page's frontmatter (hero actions,
#   feature cards), of the navigation or of HTML written into a page. And it
#   takes a link to a file that is not a page for an asset: a README section a
#   page includes is written for GitHub, and a link relative to the repository
#   (`chart/values.yaml`) that siteHref (site/.vitepress/links.ts) left as it
#   was leads nowhere on the site, while GitHub renders the file fine.
# - An anchor no element of its page has. The build checks that a linked page
#   exists, not that the heading does; a README heading that was renamed, or
#   whose anchor differs between GitHub and VitePress, would go unnoticed.
#
# Every link that stays on the site is followed as a browser follows it: an
# absolute path as it is, any other from the directory of its page, an anchor
# or a query alone on the page itself. An address with a scheme or a host
# (`https://…`, `//host/…`) leaves the site and is not checked.
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

# PAGE and HREF of each link, quoted either way, with or without blanks
# around the `=`; not data-href or the like. The fields are separated by the
# unit separator, which no address holds. grep finding none is no error.
sep=$'\x1f'
links=$(grep -roE --include='*.html' "(^|[[:space:]])href[[:space:]]*=[[:space:]]*(\"[^\"]*\"|'[^']*')" . \
  | sed -E "s/^\.\/([^:]*):[[:space:]]*href[[:space:]]*=[[:space:]]*[\"'](.*)[\"']$/\1${sep}\2/" | LC_ALL=C sort -u) || [ $? -eq 1 ]

# site_path DIR PATH — PATH as a path from the site's root, without `.` and
# `..` segments: an absolute one as it is, any other read from DIR, the
# directory of the page that links to it. As in a browser, `..` at the root
# stays at the root.
site_path() {
  local path=$2 part parts=() out=() IFS=/
  case "$path" in /*) ;; *) path="$1/$path" ;; esac
  read -ra parts <<<"$path"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      '' | .) ;;
      ..) [ ${#out[@]} -eq 0 ] || unset "out[$((${#out[@]} - 1))]" ;;
      *) out+=("$part") ;;
    esac
  done
  printf '/%s\n' "${out[*]-}"
}

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

absent="" missing=""
while IFS=$sep read -r page href; do
  [ -n "$page" ] || continue
  # Another site.
  if [[ "$href" =~ ^(//|[a-zA-Z][a-zA-Z0-9+.-]*:) ]]; then continue; fi
  path=${href%%[?#]*}
  anchor=""
  case "$href" in *'#'*) anchor=${href#*#} ;; esac
  file=$page
  if [ -n "$path" ]; then
    file=$(page_of "$(site_path "/$(dirname "$page")" "$path")")
    if [ -z "$file" ]; then absent+="$page: $href"$'\n'; continue; fi
  fi
  [ -z "$anchor" ] || grep -qF -- " id=\"$anchor\"" "./$file" || missing+="$page: $href"$'\n'
done <<<"$links"

# report PREFIX LINES — print each line with PREFIX on stderr.
report() {
  local line
  while IFS= read -r line; do
    [ -z "$line" ] || printf '%s: %s\n' "$1" "$line" >&2
  done <<<"$2"
}

report "link to a page the site does not have" "$absent"
report "anchor without a target on its page" "$missing"
[ -z "$absent$missing" ]
