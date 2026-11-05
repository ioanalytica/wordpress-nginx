#!/usr/bin/env bash
#
# Print the version of the search sidecar the wordpress-idx submodule is
# pinned to, from its app/package.json. A release labels the sidecar's image
# with it: the image is tagged with the chart version, and the label says
# which wordpress-idx is inside.
#
#   scripts/idx-version.sh [SUBMODULE_DIR]    (default wordpress-idx)
set -euo pipefail

dir="${1:-$(dirname "${BASH_SOURCE[0]}")/../wordpress-idx}"
package="$dir/app/package.json"
[ -r "$package" ] || {
  echo "idx-version: cannot read $package; is the submodule checked out (git submodule update --init)?" >&2
  exit 1
}

version="$(jq -r '.version // ""' "$package")"
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
  echo "idx-version: '$version' in $package is not a version x.y.z" >&2
  exit 1
}
echo "$version"
