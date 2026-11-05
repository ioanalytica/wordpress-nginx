#!/bin/bash
# Tests what the documentation site (site/) is put together from, where a
# mistake does not fail the VitePress build.
#
# Pages show sections of README.md, chart/README.md and the changelog by
# include. A broken include fails quietly: a missing file renders nothing, a
# missing region the whole file. The links of an included section are written
# for GitHub and are rewritten for the site (site/.vitepress/links.ts); a wrong
# target shows only on the live site. The sidebar is a list in the config that
# the build does not compare with the pages. And the paths filters of the site
# workflow decide which changes reach the site at all.
#
# Needs Node.js 22.18 or later (links.ts is loaded as TypeScript) and no
# installed packages.
#
#   site/tests/site-test.sh

set -euo pipefail
SITE="$(cd "$(dirname "$0")/.." && pwd -P)"
REPO="$(cd "$SITE/.." && pwd -P)"
WF="$REPO/.github/workflows/site.yml"
CHECK="$SITE/scripts/check-links.sh"
REPO_URL=https://github.com/ioanalytica/wordpress-nginx
FAILURES=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; FAILURES=$((FAILURES + 1)); }
# check NAME COMMAND…: passes when the command succeeds.
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else fail "$name"; fi; }
# equal NAME GOT WANT
equal() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1"; diff <(echo "$3") <(echo "$2") | sed 's/^/        /' || true; fi; }

# site_pages: the site's pages, relative to site/.
site_pages() {
    (cd "$SITE" && find . -name node_modules -prune -o -name '*.md' -print) | sed 's|^\./||' | sort
}

# includes PAGE: the target of each include of PAGE, as written (path[#region]).
includes() {
    sed -nE 's/.*<!--[[:space:]]*@include:[[:space:]]*(.*[^[:space:]])[[:space:]]*-->.*/\1/p' "$SITE/$1"
}

# repo_path PAGE PATH: the file an include of PAGE names, relative to the
# repository.
repo_path() {
    local dir file
    dir="$(cd "$(dirname "$SITE/$1")/$(dirname "$2")" 2>/dev/null && pwd -P)" || { echo "$2"; return; }
    file="$dir/$(basename "$2")"
    echo "${file#"$REPO/"}"
}

# region_lines FILE NAME: the line numbers of NAME's start and end markers.
region_lines() {
    awk -v start="<!-- #region $2 -->" -v end="<!-- #endregion $2 -->" '
        $0 == start { print "start", NR } $0 == end { print "end", NR }' "$1"
}

# region FILE NAME: the lines between NAME's markers.
region() {
    awk -v start="<!-- #region $2 -->" -v end="<!-- #endregion $2 -->" '
        $0 == end { exit } on { print } $0 == start { on = 1 }' "$1"
}

# front PAGE KEY: the value of KEY in PAGE's frontmatter.
front() {
    awk -v key="$2:" 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit }
        $1 == key { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }' "$SITE/$1"
}

# included: every include of the site as FILE[#REGION], FILE relative to the
# repository.
included() {
    local page target
    site_pages | while IFS= read -r page; do
        includes "$page" | while IFS= read -r target; do
            case "$target" in
                *'#'*) echo "$(repo_path "$page" "${target%%#*}")#${target#*#}" ;;
                *) repo_path "$page" "$target" ;;
            esac
        done
    done
}

# site_href SOURCE HREF…: what the site makes of each link HREF of a section
# of SOURCE ("" for a page without one), one per line.
site_href() {
    node --input-type=module -e '
        import { pathToFileURL } from "node:url";
        const [file, source, ...hrefs] = process.argv.slice(1);
        const { siteHref } = await import(pathToFileURL(file).href);
        for (const href of hrefs) console.log(siteHref(href, source || undefined));' \
        "$SITE/.vitepress/links.ts" "$@"
}

# targets NAME SOURCE HREF TARGET…: siteHref makes each HREF its TARGET.
targets() {
    local name=$1 source=$2 hrefs=() want=""
    shift 2
    while [ $# -gt 0 ]; do hrefs+=("$1"); want+="$1 -> $2"$'\n'; shift 2; done
    equal "$name" "$(paste -d' ' <(printf '%s ->\n' "${hrefs[@]}") <(site_href "$source" "${hrefs[@]}"))" "${want%$'\n'}"
}

# trigger_paths EVENT: the paths filter of one trigger of site.yml.
trigger_paths() {
    awk -v head="  $1:" '
        $0 == head { ev = 1; next }
        ev && /^  [^ ]/ { exit }
        ev && $1 == "paths:" { on = 1; next }
        on && $1 == "-" { p = $2; gsub(/"/, "", p); print p; next }
        on { on = 0 }' "$WF"
}

# job NAME: the lines of one job of site.yml.
job() {
    awk -v head="  $1:" '$0 == head { on = 1; next } on && /^  [^ ]/ { exit } on' "$WF"
}

echo "=== Includes name a file that exists and a region it marks once"
n=0
while IFS= read -r page; do
    while IFS= read -r target; do
        n=$((n + 1))
        file="$REPO/$(repo_path "$page" "${target%%#*}")"
        if [ ! -f "$file" ]; then fail "$page: $target: no such file"; continue; fi
        [ "$target" != "${target%%#*}" ] || continue
        name=${target#*#}
        lines=$(region_lines "$file" "$name")
        if [ "$(grep -c '^start' <<<"$lines")" != 1 ] || [ "$(grep -c '^end' <<<"$lines")" != 1 ]; then
            fail "$page: $target: the region is not marked exactly once"
        elif [ "$(awk '$1 == "start" { print $2 }' <<<"$lines")" -ge "$(awk '$1 == "end" { print $2 }' <<<"$lines")" ]; then
            fail "$page: $target: the region ends before it starts"
        elif [ -z "$(region "$file" "$name" | tr -d '[:space:]')" ]; then
            fail "$page: $target: the region is empty"
        fi
    done < <(includes "$page")
done < <(site_pages)
if [ "$n" -gt 15 ]; then ok "$n includes checked"; else fail "only $n includes found"; fi

echo "=== Every region of the READMEs is closed and shown on a page"
all=$(included)
check "the includes are found" grep -qx 'chart/README.md#database' <<<"$all"
check "the changelog is included whole" grep -qx 'chart/CHANGELOG.md' <<<"$all"
for file in README.md chart/README.md; do
    n=0
    while IFS= read -r name; do
        n=$((n + 1))
        [ "$(region_lines "$REPO/$file" "$name" | grep -c '^end')" = 1 ] || fail "$file: region $name is not closed"
        grep -qxF "$file#$name" <<<"$all" || fail "$file: region $name is on no page of the site"
    done < <(sed -nE 's/^<!-- #region ([^ ]+) -->$/\1/p' "$REPO/$file")
    if [ "$n" -gt 0 ]; then ok "$file: $n regions"; else fail "$file: no region found"; fi
done

echo "=== A page that includes a file names it as its source"
# The links of an included section are resolved against `source`; a page
# without one would leave them relative to the repository.
n=0
while IFS= read -r page; do
    [ -n "$(includes "$page")" ] || continue
    n=$((n + 1))
    source=$(front "$page" source)
    files=$(includes "$page" | while IFS= read -r t; do repo_path "$page" "${t%%#*}"; done | sort -u)
    [ "$files" = "$source" ] || fail "$page: source is '$source', it includes: $(tr '\n' ' ' <<<"$files")"
done < <(site_pages)
if [ "$n" -gt 15 ]; then ok "$n pages with includes"; else fail "only $n pages with includes found"; fi
check "a page of its own text has no source" [ -z "$(front features/mail.md source)" ]

echo "=== The sidebar and the pages agree"
links=$(sed -nE "s/.*link: '(\/[^']*)'.*/\1/p" "$SITE/.vitepress/config.mts" | sort -u)
pages=$(site_pages | sed -E 's/(^|\/)index\.md$/\1/; s/\.md$//; s/^/\//' | sort -u)
check "the sidebar's links are found" grep -qx '/guide/install' <<<"$links"
equal "every link of the navigation is a page, every page is in the navigation" "$links" "$pages"

echo "=== Links of an included section lead to the site or to GitHub"
targets "a section with a page of its own" chart/README.md \
    '#chart-versions' /reference/versioning \
    '#to-71408' '/operations/upgrading#to-7-1-408' \
    CHANGELOG.md /reference/changelog \
    'CHANGELOG.md#7-1-408' '/reference/changelog#7-1-408'
targets "a path is read from the file it stands in" chart/README.md \
    ../LICENSE "$REPO_URL/blob/main/LICENSE" \
    values.yaml "$REPO_URL/blob/main/chart/values.yaml" \
    'values.yaml#L10' "$REPO_URL/blob/main/chart/values.yaml#L10" \
    tests/ "$REPO_URL/tree/main/chart/tests" \
    ../.github/workflows/site.yml "$REPO_URL/blob/main/.github/workflows/site.yml" \
    ../docker "$REPO_URL/tree/main/docker"
targets "the same link from the top-level README" README.md \
    LICENSE "$REPO_URL/blob/main/LICENSE" \
    chart/ "$REPO_URL/tree/main/chart" \
    chart/README.md#chart-versions /reference/versioning \
    chart/README.md#php-execution-allowlist /security/php-execution-allowlist \
    chart/CHANGELOG.md /reference/changelog
targets "what stays as it is" chart/README.md \
    '#no-such-section' '#no-such-section' \
    no-such-file.md no-such-file.md \
    ../../outside ../../outside \
    /guide/install /guide/install \
    https://example.com/a https://example.com/a \
    mailto:someone@example.com mailto:someone@example.com
targets "an address of the site becomes a path on it" chart/README.md \
    https://wordpress-nginx.ioanalytica.com / \
    'https://wordpress-nginx.ioanalytica.com#quick-start' '/#quick-start' \
    'https://wordpress-nginx.ioanalytica.com/#quick-start' '/#quick-start' \
    https://wordpress-nginx.ioanalytica.com/guide/install /guide/install \
    'https://wordpress-nginx.ioanalytica.com/security/#opt-in' '/security/#opt-in' \
    https://wordpress-nginx.ioanalytica.com.example.org/x https://wordpress-nginx.ioanalytica.com.example.org/x
targets "a page without a source keeps its links" "" \
    chart/values.yaml chart/values.yaml \
    ./install ./install \
    '#anchor' '#anchor' \
    https://wordpress-nginx.ioanalytica.com/guide/ /guide/

echo "=== Each mapped section exists in its file"
# sitePages names README sections by their GitHub anchor; a renamed heading
# would leave the entry without effect.
n=0
while IFS= read -r entry; do
    n=$((n + 1))
    file=${entry%%#*}
    [ -f "$REPO/$file" ] || { fail "sitePages: $file: no such file"; continue; }
    [ "$entry" != "$file" ] || continue
    anchor=${entry#*#}
    awk '/^```/ { code = !code } !code && /^#+ / { h = tolower($0); sub(/^#+ +/, "", h); gsub(/[^a-z0-9 _-]/, "", h); gsub(/ /, "-", h); print h }' \
        "$REPO/$file" | grep -qxF -- "$anchor" || fail "sitePages: $file has no heading #$anchor"
done < <(sed -nE "s/^  '([^']+)': '\/.*/\1/p" "$SITE/.vitepress/links.ts")
if [ "$n" -gt 2 ]; then ok "$n entries"; else fail "only $n entries of sitePages found"; fi

echo "=== Headings below the title start at the second level"
shift_of() {
    node --input-type=module -e '
        import { pathToFileURL } from "node:url";
        const { headingShift } = await import(pathToFileURL(process.argv[1]).href);
        console.log(headingShift(process.argv.slice(2).map(Number)));' "$SITE/.vitepress/links.ts" "$@"
}
equal "a README section's subsections move up two levels" "$(shift_of 1 4 4 4)" 2
equal "the title is not counted"                           "$(shift_of 1 1 3 4)" 1
equal "a page with second-level headings stays"            "$(shift_of 1 2 4)" 0
equal "a page with a title alone stays"                    "$(shift_of 1)" 0

echo "=== The link check finds what the build does not"
mkdir -p "$WORK/good/guide" "$WORK/bad/guide" "$WORK/empty"
cat > "$WORK/good/index.html" <<'HTML'
<link rel="icon" href="/favicon.png"><a href="#top">a</a><h1 id="top">t</h1>
<a href="/guide/install#pin">b</a> <a href="/guide/#intro">c</a> <a href="https://example.com/x#y">d</a>
<a href="/guide/install?tab=1#pin">q</a> <a href="?tab=2#top">r</a> <a href="./guide/install">e</a> <a href='..'>f</a> <a data-href="chart/values.yaml">g</a> <a href="//example.com/no-such-page">h</a>
<link rel="stylesheet" href="/assets/style.css"> <a href="/guide/">i</a> <a href="/guide/install?tab=1">j</a>
HTML
mkdir -p "$WORK/good/assets" && : > "$WORK/good/assets/style.css" && : > "$WORK/good/favicon.png"
echo '<h2 id="pin">p</h2>' > "$WORK/good/guide/install.html"
echo '<h2 id="intro">i</h2>' > "$WORK/good/guide/index.html"
cp -R "$WORK/good/." "$WORK/bad/"
echo '<a href="chart/values.yaml">a</a> <a href=".github/workflows/site.yml">b</a> <a href="/guide/install#gone">c</a> <a href="#nowhere">d</a> <a href="/guide/install?tab=1#lost">e</a> <a href="/no-such-page#x">f</a> <a href="/guide/absent">g</a>
<a href="./missing#section">h</a> <a href="../guide/install#gone">i</a> <a href="../../guide/nowhere">j</a> <a href="./install#pin">ok</a> <a href="..#top">ok</a>' > "$WORK/bad/guide/other.html"
check "a clean site passes" "$CHECK" "$WORK/good"
if out=$("$CHECK" "$WORK/bad" 2>&1); then fail "a site with broken links passes"; else ok "a site with broken links fails"; fi
equal "it names each broken link with its page" "$out" \
'link relative to the repository, leads nowhere on the site: guide/other.html: .github/workflows/site.yml
link relative to the repository, leads nowhere on the site: guide/other.html: chart/values.yaml
link to a page the site does not have: guide/other.html: ../../guide/nowhere
link to a page the site does not have: guide/other.html: ./missing#section
link to a page the site does not have: guide/other.html: /guide/absent
link to a page the site does not have: guide/other.html: /no-such-page#x
anchor without a target on its page: guide/other.html: #nowhere
anchor without a target on its page: guide/other.html: ../guide/install#gone
anchor without a target on its page: guide/other.html: /guide/install#gone
anchor without a target on its page: guide/other.html: /guide/install?tab=1#lost'
"$CHECK" "$WORK/empty" >/dev/null 2>&1 && code=0 || code=$?
equal "a directory without pages is an error, not a pass" "$code" 2

echo "=== The workflow runs on every file the site shows, and only main publishes"
equal "pushes and pull requests run on the same paths" "$(trigger_paths push)" "$(trigger_paths pull_request)"
check "the paths are found" [ -n "$(trigger_paths push)" ]
sources=$({ included | sed 's/#.*//'; sed -nE "s/.*resolve\(repoRoot, '([^']+)'\).*/\1/p" "$SITE/.vitepress/config.mts"; } | sort -u)
check "the site's sources are found" grep -qx 'chart/Chart.yaml' <<<"$sources"
for file in 'site/**' .github/workflows/site.yml $sources; do
    grep -qxF "$file" <<<"$(trigger_paths push)" || fail "$file is in no paths filter of site.yml"
done
ok "$(wc -l <<<"$sources" | tr -d ' ') source files"
steps=$(job build | sed -nE 's/^      - name: //p' | tr '\n' ' ')
equal "the build tests, builds and checks the links before it uploads" "$steps" "Install Test Build Check the links Upload the site "
cond="if: github.event_name != 'pull_request' && github.ref == 'refs/heads/main'"
check "only main is uploaded" grep -qxF "        $cond" <(job build)
check "only main is deployed" grep -qxF "    $cond" <(job deploy)
equal "the workflow's token only reads" "$(sed -n '/^permissions:/,/^[^ p]/p' "$WF" | grep '^  ')" "  contents: read"
equal "pages: write is granted once"    "$(grep -c 'pages: write' "$WF")" 1
check "and to the deploy job"           grep -q 'pages: write' <(job deploy)

echo
if [ "$FAILURES" -gt 0 ]; then echo "=== $FAILURES assertion(s) FAILED"; exit 1; fi
echo "=== All assertions passed"
