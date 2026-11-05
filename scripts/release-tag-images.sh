#!/usr/bin/env bash
#
# Set the tags of a release's images, once their digests are signed: the tag
# job of release.yml runs it with each image as image@digest and the tags
# build-image.yml computed for it (docker/metadata-action's list, one
# image:tag a line).
#
# Every list is checked before the first tag is set: a tag of another image,
# an empty list, and `latest` for a release candidate stop the script, and so
# does a version tag the registry already has on another digest. A published
# version is never published again: only `latest` moves, and only to an image
# of this run or a later one. Each image index carries the number of the
# release run that built it, so a late re-run of an older release's failed
# jobs leaves `latest` on the newer release's images. Any other answer of the
# registry than "not found" stops the script. A re-run of the tag job finds
# its tags on its own digests and sets them again.
#
#   scripts/release-tag-images.sh VERSION IMAGE@DIGEST TAGS [IMAGE@DIGEST TAGS]...
#
# Needs oras, logged in to the registry, and jq.
set -euo pipefail

version="${1:-}"
[ -n "$version" ] && [ $(($# % 2)) -eq 1 ] && [ $# -ge 3 ] || {
  echo "usage: release-tag-images.sh VERSION IMAGE@DIGEST TAGS [IMAGE@DIGEST TAGS]..." >&2
  exit 2
}
shift

ANNOTATION="com.ioanalytica.wordpress-nginx.build-run"

# tags REF LIST: the tags of LIST for REF, one a line.
tags() {
  local image="${1%@*}" t n=0
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    [[ "$t" == "$image:"* ]] || { echo "release-tag-images: $t is not a tag of $image" >&2; return 1; }
    t="${t#"$image:"}"
    # A version with a -suffix is a release candidate.
    if [ "$t" = latest ] && [[ "$version" == *-* ]]; then
      echo "release-tag-images: $version is a release candidate, $image:latest stays where it is" >&2
      return 1
    fi
    echo "$t"
    n=$((n + 1))
  done <<<"$2"
  [ "$n" -gt 0 ] || { echo "release-tag-images: no tags for $image" >&2; return 1; }
}

# run_of REF: the release run that built the index REF names, or nothing for
# an index from before.
run_of() {
  local manifest
  manifest="$(oras manifest fetch "$1")" || return
  jq -r --arg key "$ANNOTATION" '.annotations[$key] // ""' <<<"$manifest"
}

# current REF: the digest a tag names now, or nothing for a tag the registry
# does not have. Any other failure than "not found" is one of the script.
current() {
  local now err
  err="$(mktemp)"
  if now="$(oras resolve "$1" 2>"$err")"; then
    rm -f "$err"
    echo "$now"
  elif grep -q 'not found' "$err"; then
    rm -f "$err"
  else
    cat "$err" >&2
    rm -f "$err"
    return 1
  fi
}

# free REF TAG...: fail on a version tag that names another digest already.
free() {
  local ref="$1" image="${1%@*}" digest="${1#*@}" t now
  shift
  for t in "$@"; do
    [ "$t" != latest ] || continue
    now="$(current "$image:$t")" || return
    if [ -n "$now" ] && [ "$now" != "$digest" ]; then
      echo "release-tag-images: $image:$t is published already, as $now; a version is never published again" >&2
      return 1
    fi
  done
}

# move_tags REF TAG...: set each TAG on REF; `latest` stays where it is when
# it names an index of a later run.
move_tags() {
  local ref="$1" image="${1%@*}" ours t now theirs
  local -a move=()
  shift
  ours="$(run_of "$ref")"
  for t in "$@"; do
    if [ "$t" = latest ]; then
      now="$(current "$image:$t")" || return
      if [ -n "$now" ]; then
        theirs="$(run_of "$image@$now")"
        if [ -n "$theirs" ] && [ "$theirs" -gt "$ours" ]; then
          echo "$image:$t stays on $now, from the later run $theirs"
          continue
        fi
      fi
    fi
    move+=("$t")
  done
  [ "${#move[@]}" -eq 0 ] || oras tag "$ref" "${move[@]}"
}

# First every list and every index, then the tags.
refs=()
lists=()
while [ $# -gt 0 ]; do
  ref="$1"
  list="$(tags "$ref" "$2")"
  [[ "$(run_of "$ref")" =~ ^[0-9]+$ ]] || { echo "release-tag-images: $ref names no release run" >&2; exit 1; }
  # A tag has no blanks: the list splits on its newlines.
  # shellcheck disable=SC2086
  free "$ref" $list
  refs+=("$ref")
  lists+=("$list")
  shift 2
done

for i in "${!refs[@]}"; do
  # shellcheck disable=SC2086
  move_tags "${refs[$i]}" ${lists[$i]}
done
