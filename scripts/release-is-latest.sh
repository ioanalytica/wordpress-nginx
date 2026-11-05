#!/usr/bin/env bash
#
# Say whether a release is the repository's newest: "true" when no published
# release has a higher version, "false" otherwise, and always "false" for a
# release candidate. The release job of release.yml marks the GitHub Release
# as Latest only then, so a late re-run of an older release's failed job
# does not take Latest back from a newer release.
#
# The versions of the published releases come on standard input, one a
# line; the version itself may be among them.
#
#   gh api --paginate repos/OWNER/REPO/releases --jq '.[] | select(.draft or .prerelease | not) | .tag_name' \
#     | scripts/release-is-latest.sh 7.1.409
set -euo pipefail

version="${1:-}"
[ -n "$version" ] || { echo "usage: release-is-latest.sh VERSION < VERSIONS" >&2; exit 2; }

# A version with a -suffix is a release candidate.
if [[ "$version" == *-rc.* ]]; then
  echo false
  exit 0
fi

# Version order, in which 7.1.408 follows 7.1.4-7 of the earlier scheme.
newest="$({ cat; echo "$version"; } | grep -v '^$' | sort -V | tail -n 1)"
if [ "$newest" = "$version" ]; then echo true; else echo false; fi
