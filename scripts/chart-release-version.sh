#!/usr/bin/env bash
#
# Give the chart a release packages the version of its tag. A release
# candidate is tagged on the commit its release will be tagged on
# (X.Y.P-rc.1, then X.Y.P on the same commit once the candidate has passed,
# so the release is the source the candidate tested), and that commit's
# chart/Chart.yaml carries the release's version. The candidate's chart gets
# the tag's version, which is also the tag of the two images the run built,
# and those images in artifacthub.io/images. appVersion stays: it is the
# WordPress version. For a release the file already says so and stays as it
# is. The chart job of release.yml runs it after check-release-tag.sh.
#
#   scripts/chart-release-version.sh 7.1.409-rc.1 [chart/Chart.yaml]
set -euo pipefail

version="${1:-}"
[ -n "$version" ] || { echo "usage: chart-release-version.sh VERSION [CHART_YAML]" >&2; exit 2; }
chart="${2:-$(dirname "${BASH_SOURCE[0]}")/../chart/Chart.yaml}"

# A tag equal to the chart's version: the file already says what it should.
if grep -qxF "version: $version" "$chart"; then
  echo "$chart: already at $version"
  exit 0
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
# Each of the three once, or the file is not the one this was written for.
if ! awk -v v="$version" '
  /^version: / { print "version: " v; a++; next }
  /^      image: ghcr\.io\/ioanalytica\/wordpress-nginx:/ { sub(/:[^:]*$/, ":" v); print; b++; next }
  /^      image: ghcr\.io\/ioanalytica\/wordpress-idx:/   { sub(/:[^:]*$/, ":" v); print; c++; next }
  { print }
  END { exit !(a == 1 && b == 1 && c == 1) }' "$chart" >"$tmp"; then
  echo "chart-release-version: expected version: and the two images of this project in artifacthub.io/images once each in $chart" >&2
  exit 1
fi
cat "$tmp" >"$chart"

echo "$chart: version $version"
