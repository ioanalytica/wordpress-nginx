#!/usr/bin/env bash
#
# Fail a release build whose git tag is not the version in chart/Chart.yaml.
#
# The two reach the published artifacts by different routes: the image is
# tagged with the git tag, the chart is packaged at the version in
# chart/Chart.yaml. A tag that differs would publish an image no chart names,
# and package the chart at the version in the file once more, over the chart
# already published under it.
#
#   scripts/check-release-tag.sh 7.1.408 [chart/Chart.yaml]
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

{
  echo "check-release-tag: release tag '$tag' is not the version in $chart, '$want'"
  echo
  echo "  Tag $want on the commit whose chart/Chart.yaml says $want. For another"
  echo "  version, a release pull request sets chart/Chart.yaml first. Publishing"
  echo "  as it is would package $want again and overwrite the chart already"
  echo "  published under that version."
} >&2
exit 1
