#!/usr/bin/env bash
#
# Push Artifact Hub's repository metadata, artifacthub-repo.yml, to the tag
# `artifacthub.io` of the chart's repository, as the layer of an ORAS
# artifact with the media types Artifact Hub reads. The tag job of
# release.yml runs it before it tags the chart: Artifact Hub reads the
# metadata when a new version appears.
#
# The tag is the one of a release that is meant to move, and like `latest`
# it moves forward only: the artifact carries the number of the release run
# that pushed it, and a run with a lower number leaves the tag as it is. A
# late re-run of an older release's failed job would otherwise put that
# release's file back in place of a newer one. Any other answer of the
# registry than "not found" stops the script.
#
#   scripts/release-artifacthub-metadata.sh REPOSITORY RUN [FILE]
#
# Needs oras, logged in to the registry, and jq.
set -euo pipefail

repository="${1:-}" run="${2:-}"
file="${3:-artifacthub-repo.yml}"
[ -n "$repository" ] && [[ "$run" =~ ^[0-9]+$ ]] || {
  echo "usage: release-artifacthub-metadata.sh REPOSITORY RUN [FILE]" >&2
  exit 2
}
[ -r "$file" ] || { echo "release-artifacthub-metadata: cannot read $file" >&2; exit 1; }

ANNOTATION="com.ioanalytica.wordpress-nginx.build-run"
ref="$repository:artifacthub.io"

err="$(mktemp)"
trap 'rm -f "$err"' EXIT
if manifest="$(oras manifest fetch "$ref" 2>"$err")"; then
  theirs="$(jq -r --arg key "$ANNOTATION" '.annotations[$key] // ""' <<<"$manifest")"
  if [[ "$theirs" =~ ^[0-9]+$ ]] && [ "$theirs" -gt "$run" ]; then
    echo "$ref stays as it is, from the later run $theirs"
    exit 0
  fi
elif ! grep -q 'not found' "$err"; then
  cat "$err" >&2
  exit 1
fi

# The layer keeps the file's name: oras takes the path as given.
cd "$(dirname "$file")"
oras push "$ref" \
  --annotation "$ANNOTATION=$run" \
  --config /dev/null:application/vnd.cncf.artifacthub.config.v1+yaml \
  "$(basename "$file"):application/vnd.cncf.artifacthub.repository-metadata.layer.v1.yaml"
