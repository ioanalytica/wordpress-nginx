#!/usr/bin/env bash
#
# Fail a release whose version is in the registry already. A published
# version is never published again: deployments that pin it would not see
# the new content, and a tag that moved names something nobody verified. The
# prep job of release.yml runs it before anything is built, so a tag pushed
# a second time stops there, not after the images are built and signed. The
# next build number is the way to publish a change.
#
# A re-run of a release's failed jobs does not come through here again, so
# it can finish a release that has set some of its tags.
#
#   scripts/release-unpublished.sh VERSION REPOSITORY...
#
# Needs oras; a public repository needs no login.
set -euo pipefail

version="${1:-}"
[ -n "$version" ] && [ $# -ge 2 ] || { echo "usage: release-unpublished.sh VERSION REPOSITORY..." >&2; exit 2; }
shift

err="$(mktemp)"
trap 'rm -f "$err"' EXIT
status=0
for repository in "$@"; do
  if now="$(oras resolve "$repository:$version" 2>"$err")"; then
    echo "release-unpublished: $repository:$version is published already, as $now" >&2
    status=1
  elif grep -q 'not found' "$err"; then
    echo "$repository:$version is not published yet"
  else
    cat "$err" >&2
    exit 1
  fi
done
if [ "$status" -ne 0 ]; then
  echo "release-unpublished: a version is never published again; set the next build number in chart/Chart.yaml" >&2
fi
exit "$status"
