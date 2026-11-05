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
# nothing says that the checkout's would differ: on a pull request that
# leaves docker/ alone and does not move the wordpress-idx submodule, with
# the images the chart names published. In every other case an image is
# built from the checkout, the WordPress image from docker/ and the
# sidecar's from the submodule, each decided for itself, so a pull request
# is tested with the images it would release:
#
#   - the pull request changes docker/, or moves the submodule;
#   - the chart names an image the registry does not have, as on a pull
#     request that raises the chart version, which is the tag of both
#     images;
#   - the run was started by hand, where there is no base to compare with.

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

# why_build IMAGE SOURCE - why IMAGE is built from SOURCE of the checkout
# (docker/, or the submodule wordpress-idx); nothing when the registry's
# image is the one to test.
why_build() {
  local missing
  if [ "${EVENT:-}" != pull_request ]; then
    echo "a run by hand takes the image from the checkout as well"
  # A pull request is checked out as its merge into the base branch: the
  # first parent is the base, the second the pull request's head.
  elif ! git -C "$ROOT" rev-parse -q --verify 'HEAD^2' >/dev/null; then
    echo "the checkout is no merge commit, so $2 cannot be compared with the base"
  elif ! git -C "$ROOT" diff --quiet 'HEAD^1' HEAD -- "$2"; then
    echo "the pull request changes $2"
  else
    # Only an image the registry says it does not have is built here. Any
    # other answer fails the step (unpublished, in lib.sh): a registry that
    # cannot be reached must not turn a run with the published image into
    # one with a rebuilt image.
    missing="$(unpublished "$1")" || return
    [ -z "$missing" ] || echo "$1 is not in the registry"
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
  build="$(why_build "$image" docker/)"
  idx_image="$IDX_REPO:$version"
  idx_build="$(why_build "$idx_image" wordpress-idx)"
fi

echo "dir=$dir"
echo "image=$image"
echo "build=$build"
echo "idx_image=$idx_image"
echo "idx_build=$idx_build"
