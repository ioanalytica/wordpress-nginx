#!/bin/bash
# Which chart a run of .github/workflows/try-locally.yml installs, and where
# its WordPress image comes from. Prints the step's outputs:
#
#   dir=    the chart directory for run.sh; empty for the latest release,
#           which run.sh installs as the page does
#   image=  the WordPress image the checkout's chart names; empty otherwise
#   build=  why that image is built from the checkout's docker/ and loaded
#           into the cluster; empty when the registry's image is used
#
# Read from the environment:
#
#   VERSION  a published chart version; wins over CHOICE
#   CHOICE   "checkout" for the chart of the checkout, anything else for the
#            latest release
#   EVENT    the event that started the run (github.event_name)
#
# A published version is pulled from the registry and runs with the images
# it names. The checkout's chart runs with the registry's image as long as
# nothing says that the checkout's image would differ: on a pull request
# that leaves docker/ alone, with the image the chart names published. In
# every other case the image is built from the checkout, so a pull request
# is tested with the image it would release:
#
#   - the pull request changes docker/;
#   - the chart names an image the registry does not have, as on a pull
#     request that raises the chart version, which is the image tag;
#   - the run was started by hand, where there is no base to compare
#     docker/ with.

set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$TRY_ROOT"
CHART_REF="$PAGE_CHART"
IMAGE_REPO="ghcr.io/ioanalytica/wordpress-nginx"

dir=""
image=""
build=""

if [ -n "${VERSION:-}" ]; then
  helm pull "$CHART_REF" --version "$VERSION" --untar --untardir "$RUNNER_TEMP/chart" >&2
  dir="$RUNNER_TEMP/chart/wordpress-nginx"
elif [ "${CHOICE:-}" = checkout ]; then
  # chart/charts/ is not checked in.
  helm dependency update "$ROOT/chart" >&2
  dir="$ROOT/chart"
  version="$(sed -n 's/^version: *//p' "$ROOT/chart/Chart.yaml" | tr -d '"')"
  [ -n "$version" ] || { echo "ERROR: chart/Chart.yaml has no version" >&2; exit 1; }
  image="$IMAGE_REPO:$version"
  if [ "${EVENT:-}" != pull_request ]; then
    build="a run by hand takes the image from the checkout as well"
  # A pull request is checked out as its merge into the base branch: the
  # first parent is the base, the second the pull request's head.
  elif ! git -C "$ROOT" rev-parse -q --verify 'HEAD^2' >/dev/null; then
    build="the checkout is no merge commit, so docker/ cannot be compared with the base"
  elif ! git -C "$ROOT" diff --quiet 'HEAD^1' HEAD -- docker/; then
    build="the pull request changes docker/"
  else
    # Only an image the registry says it does not have is built here. Any
    # other answer fails the step (unpublished, in lib.sh): a registry that
    # cannot be reached must not turn a run with the published image into
    # one with a rebuilt image. An assignment of its own: inside a test,
    # the failure would be lost.
    missing="$(unpublished "$image")"
    [ -z "$missing" ] || build="$image is not in the registry"
  fi
fi

echo "dir=$dir"
echo "image=$image"
echo "build=$build"
