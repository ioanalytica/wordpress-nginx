#!/usr/bin/env bash
#
# Set one tag on a signed artifact of a release, unless the registry has that
# tag already: a published tag never moves to other content. The tag job of
# release.yml runs it
#
#   for the chart, with the release's version: a tag on another digest stops
#   the release, a tag on this digest (a re-run of the job) is left as it is;
#
#   with --keep for the search sidecar's own version (1.x.y): the first
#   release that builds a new wordpress-idx version gives its image that tag
#   as well, and every later build of the same version leaves it there. The
#   tags the wordpress-idx repository published itself stay untouched.
#
# Any other answer of the registry than "not found" stops the script.
#
#   scripts/release-tag-once.sh [--keep] IMAGE@DIGEST TAG
#
# Needs oras, logged in to the registry.
set -euo pipefail

keep=""
if [ "${1:-}" = "--keep" ]; then
  keep=1
  shift
fi
[ $# -eq 2 ] && [[ "$1" == *@sha256:* ]] && [ -n "$2" ] || {
  echo "usage: release-tag-once.sh [--keep] IMAGE@DIGEST TAG" >&2
  exit 2
}
ref="$1" image="${1%@*}" digest="${1#*@}" tag="$2"

err="$(mktemp)"
trap 'rm -f "$err"' EXIT
if now="$(oras resolve "$image:$tag" 2>"$err")"; then
  if [ "$now" = "$digest" ]; then
    echo "$image:$tag names $digest already"
  elif [ -n "$keep" ]; then
    echo "$image:$tag stays on $now, where it was published first"
  else
    echo "release-tag-once: $image:$tag is published already, as $now; a version is never published again" >&2
    exit 1
  fi
  exit 0
fi
grep -q 'not found' "$err" || { cat "$err" >&2; exit 1; }
oras tag "$ref" "$tag"
