#!/usr/bin/env bash
#
# Fail a release build whose git tag is not the version in chart/Chart.yaml.
#
# The two reach the published artifacts by different routes: the images are
# tagged with the git tag, the chart is packaged at the version in
# chart/Chart.yaml. A tag that differs would publish images no chart names,
# and package the chart at the version in the file once more.
#
# A release candidate of the chart's version passes too: X.Y.P-rc.N goes on
# the commit whose chart/Chart.yaml says X.Y.P, the one X.Y.P is tagged on
# once the candidate has passed, and the build packages the chart at the
# tag's version (scripts/chart-release-version.sh). No other suffix does: the
# version scheme has none (scripts/chart-version.sh).
#
#   scripts/check-release-tag.sh 7.1.409 [chart/Chart.yaml]
#   scripts/check-release-tag.sh 7.1.409-rc.1
set -euo pipefail

tag="${1:-}"
[ -n "$tag" ] || { echo "usage: check-release-tag.sh TAG [CHART_YAML]" >&2; exit 2; }
chart="${2:-$(dirname "${BASH_SOURCE[0]}")/../chart/Chart.yaml}"

want="$(sed -n 's/^version: *//p' "$chart" | tr -d '"')"
[ -n "$want" ] || { echo "check-release-tag: no version: in $chart" >&2; exit 1; }

if [ "$tag" = "$want" ]; then
  echo "release tag '$tag' is the version in $chart"
  exit 0
fi
if [[ "$tag" == "$want"-rc.* && "${tag#"$want"-rc.}" =~ ^[1-9][0-9]*$ ]]; then
  echo "release tag '$tag' is a release candidate of the version in $chart, $want"
  exit 0
fi

{
  echo "check-release-tag: release tag '$tag' is not the version in $chart, '$want'"
  echo
  echo "  Tag $want, or a release candidate of it ($want-rc.1), on the commit"
  echo "  whose chart/Chart.yaml says $want. For another version, a release"
  echo "  pull request sets chart/Chart.yaml first. Publishing as it is would"
  echo "  package $want again under a tag that does not name it."
} >&2
exit 1
