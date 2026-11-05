#!/usr/bin/env bash
#
# Give a release its entry in chart/CHANGELOG.md.
#
# A pull request that changes the chart or the image leaves the version alone
# and adds its lines under "## Unreleased", the first section of the
# changelog. The release pull request then sets the version in
# chart/Chart.yaml and runs this script: "## Unreleased" becomes the
# version's heading, and the lines below it are the release's entry. Without
# an Unreleased section the version gets a new section at the top.
#
#   scripts/changelog-release.sh VERSION [LINE] [FILE]
#       LINE, when given, becomes the first line of the entry, ahead of the
#       lines taken over from Unreleased. A release without an Unreleased
#       section needs it: an entry has to say something.
#       FILE defaults to chart/CHANGELOG.md.
#
# .github/workflows/wp-version-check.yml uses it for the pull request of a
# new WordPress release, and chart/tests/template-test.sh checks that the
# version of chart/Chart.yaml has its heading.
set -euo pipefail

usage() {
  echo "usage: scripts/changelog-release.sh VERSION [LINE] [FILE]" >&2
  exit 2
}

fail() {
  echo "changelog-release: $*" >&2
  exit 1
}

[ $# -ge 1 ] && [ $# -le 3 ] || usage
version="$1"
line="${2:-}"
file="${3:-$(dirname "${BASH_SOURCE[0]}")/../chart/CHANGELOG.md}"

[ -n "$version" ] || usage
[ -f "$file" ] || fail "$file does not exist"
[ "$(head -n 1 "$file")" = "# Changelog" ] \
  || fail "$file does not start with '# Changelog'"
if grep -qxF "## $version" "$file"; then
  fail "$file already has a section for $version"
fi
unreleased="$(grep -cxF '## Unreleased' "$file" || true)"
case "$unreleased" in
  0)
    [ -n "$line" ] || fail "$file has no Unreleased section, so the entry for $version needs a LINE"
    ;;
  1)
    first_section="$(grep -m 1 '^## ' "$file")"
    [ "$first_section" = "## Unreleased" ] \
      || fail "'## Unreleased' must be the first section of $file, which is '$first_section'"
    entries="$(awk '$0 == "## Unreleased" { inside = 1; next } inside && /^## / { exit }
                    inside && NF { n++ } END { print n + 0 }' "$file")"
    [ "$entries" -gt 0 ] || [ -n "$line" ] \
      || fail "the Unreleased section of $file is empty, so the entry for $version needs a LINE"
    ;;
  *)
    fail "$file has more than one Unreleased section"
    ;;
esac

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# LINE reaches awk through the environment: -v would read backslashes in it
# as escape sequences.
LINE="$line" awk -v ver="$version" -v unreleased="$unreleased" '
  BEGIN { line = ENVIRON["LINE"] }
  # No Unreleased section: a new one for the version, right below the title.
  NR == 1 && unreleased == 0 {
    print; print ""; print "## " ver; print ""; print line
    next
  }
  # The Unreleased section becomes the section of the version; LINE leads
  # its entries.
  $0 == "## Unreleased" {
    print "## " ver
    if (line != "") { print ""; print line; after_heading = 1 }
    next
  }
  # The blank line between the heading and the first entry is already there.
  after_heading && $0 == "" { after_heading = 0; held = 1; next }
  {
    # An entry right below the heading follows LINE without a gap; anything
    # else (a subheading, the next section) keeps its blank line.
    if (held && $0 !~ /^[*-] /) print ""
    held = 0; after_heading = 0
    print
  }
' "$file" > "$tmp"

# Written in place, so the changelog keeps its mode and owner.
cat "$tmp" > "$file"
