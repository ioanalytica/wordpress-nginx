#!/bin/bash
# Which chart a run of .github/workflows/try-locally.yml installs, and where
# its two images come from. Prints the step's outputs:
#
#   dir=        the chart directory for run.sh; empty for the latest release,
#               which run.sh installs as the page does
#   image=      the WordPress image the checkout's chart names; empty
#               otherwise
#   build=      why that image is built from the checkout's docker/ and
#               loaded into the cluster; empty when the registry's image is
#               used
#   idx_image=  the search sidecar's image the checkout's chart names; empty
#               otherwise
#   idx_build=  why that image is built from the wordpress-idx submodule of
#               the checkout and loaded into the cluster; empty when the
#               registry's image is used
#
# Read from the environment:
#
#   VERSION  a published chart version; wins over CHOICE
#   CHOICE   "checkout" for the chart of the checkout, anything else for the
#            latest release
#   EVENT    the event that started the run (github.event_name)
#
# A published version is pulled from the registry and runs with the images
# it names. The checkout's chart runs with the registry's images as long as
# the checkout would build the same ones: the images the chart names are
# published, and their sources, docker/ and the wordpress-idx submodule, are
# as the release's tag has them. In every other case an image is built from
# the checkout, the WordPress image from docker/ and the sidecar's from the
# submodule, each decided for itself, so a pull request is tested with the
# images the next release would publish:
#
#   - the chart names an image the registry does not have, as on a pull
#     request that raises the chart version, which is the tag of both
#     images;
#   - the image's source has changed since the release the chart names, in
#     this pull request or in one merged since: the page is tested as the
#     checkout has it, and may rely on a change to the image that no
#     release has published yet;
#   - the run was started by hand.

set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$TRY_ROOT"
CHART_REF="$PAGE_CHART"
IMAGE_REPO="ghcr.io/ioanalytica/wordpress-nginx"
IDX_REPO="ghcr.io/ioanalytica/wordpress-idx"

dir=""
image=""
build=""
idx_image=""
idx_build=""

# why_build IMAGE SOURCE VERSION - why IMAGE is built from SOURCE of the
# checkout (docker/, or the submodule wordpress-idx); nothing when the
# registry's image, of the release VERSION, is the one to test.
why_build() {
  local missing depth tag="refs/tags/$3"
  if [ "${EVENT:-}" != pull_request ]; then
    echo "a run by hand takes the image from the checkout as well"
    return
  fi
  # Only an image the registry says it does not have counts as missing. Any
  # other answer fails the step (unpublished, in lib.sh): a registry that
  # cannot be reached must not turn a run with the published image into one
  # with a rebuilt image.
  missing="$(unpublished "$1")" || return
  if [ -n "$missing" ]; then
    echo "$1 is not in the registry"
    return
  fi
  # The registry's image was built from the commit the release's tag names.
  # A runner's checkout holds no tags, so that one is fetched, one commit
  # deep where the checkout is shallow itself (a complete clone must not
  # become a shallow one). A tag that cannot be fetched fails the step, for
  # the same reason as above.
  if ! git -C "$ROOT" rev-parse -q --verify "$tag^{commit}" >/dev/null; then
    depth=""
    [ "$(git -C "$ROOT" rev-parse --is-shallow-repository)" != true ] || depth="--depth 1"
    # shellcheck disable=SC2086 # one option and its value, or nothing
    git -C "$ROOT" fetch --quiet $depth origin "$tag:$tag" \
      || { echo "ERROR: cannot fetch the tag $3, which $1 was built from" >&2; return 1; }
  fi
  if ! git -C "$ROOT" diff --quiet "$tag" HEAD -- "$2"; then
    echo "$2 has changed since the release $3"
  fi
}

if [ -n "${VERSION:-}" ]; then
  helm pull "$CHART_REF" --version "$VERSION" --untar --untardir "$RUNNER_TEMP/chart" >&2
  dir="$RUNNER_TEMP/chart/wordpress-nginx"
elif [ "${CHOICE:-}" = checkout ]; then
  # chart/charts/ is not checked in.
  helm dependency update "$ROOT/chart" >&2
  dir="$ROOT/chart"
  version="$(sed -n 's/^version: *//p' "$ROOT/chart/Chart.yaml" | tr -d '"')"
  [ -n "$version" ] || { echo "ERROR: chart/Chart.yaml has no version" >&2; exit 1; }
  # The chart version is the tag of both images. Assignments of their own:
  # inside a test, a failure of why_build would be lost.
  image="$IMAGE_REPO:$version"
  build="$(why_build "$image" docker/ "$version")"
  idx_image="$IDX_REPO:$version"
  idx_build="$(why_build "$idx_image" wordpress-idx "$version")"
fi

echo "dir=$dir"
echo "image=$image"
echo "build=$build"
echo "idx_image=$idx_image"
echo "idx_build=$idx_build"
