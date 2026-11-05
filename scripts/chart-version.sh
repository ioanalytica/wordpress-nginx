#!/usr/bin/env bash
#
# The chart version scheme, in one place.
#
# A chart version is x.y.P with P = z * 100 + N, where x.y.z is the WordPress
# release the chart ships (its appVersion) and N is the build number on that
# release, 0 to 99:
#
#   WordPress 7.1.4, build 8   7.1.408
#   WordPress 7.1.5, build 0   7.1.500
#   WordPress 7.2.0, build 1   7.2.1      (SemVer allows no leading zeros)
#   WordPress 7.2.1, build 0   7.2.100
#
# The chart version is also the image tag. It is a plain SemVer version: a
# suffix such as the -N of the earlier scheme (7.1.4-7) would make every
# release a pre-release, which Helm skips without --devel and a version range
# matches only if it names a pre-release itself.
#
#   scripts/chart-version.sh first WORDPRESS_VERSION
#       print the first chart version for a WordPress release (x.y or x.y.z)
#   scripts/chart-version.sh next CHART_VERSION
#       print the version of the next build on the same WordPress release
#   scripts/chart-version.sh check CHART_VERSION APP_VERSION
#       fail unless the chart version follows the scheme for that appVersion
#
# chart/tests/template-test.sh runs `check` against chart/Chart.yaml, and
# .github/workflows/wp-version-check.yml uses `first` for its bump.
set -euo pipefail

NUM='(0|[1-9][0-9]*)'

usage() {
  sed -n 's/^#   \(scripts\/chart-version\.sh .*\)$/\1/p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

fail() {
  echo "chart-version: $*" >&2
  exit 1
}

# WordPress names a .0 release with two components (7.2), every other one
# with three. Sets wp_major, wp_minor and wp_patch.
parse_wordpress() {
  [[ "$1" =~ ^$NUM\.$NUM(\.$NUM)?$ ]] \
    || fail "'$1' is not a WordPress version (x.y or x.y.z)"
  wp_major="${BASH_REMATCH[1]}"
  wp_minor="${BASH_REMATCH[2]}"
  wp_patch="${BASH_REMATCH[4]:-0}"
}

# Sets chart_major, chart_minor and chart_patch.
parse_chart() {
  if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]]; then
    fail "'$1' has the -N suffix of the earlier scheme; a chart version is x.y.P with P = z * 100 + N"
  fi
  [[ "$1" =~ ^$NUM\.$NUM\.$NUM$ ]] \
    || fail "'$1' is not a chart version (x.y.P, three numbers without leading zeros and without a suffix)"
  chart_major="${BASH_REMATCH[1]}"
  chart_minor="${BASH_REMATCH[2]}"
  chart_patch="${BASH_REMATCH[3]}"
}

case "${1:-}" in
  first)
    [ $# -eq 2 ] || usage
    parse_wordpress "$2"
    echo "${wp_major}.${wp_minor}.$((wp_patch * 100))"
    ;;

  next)
    [ $# -eq 2 ] || usage
    parse_chart "$2"
    if [ $((chart_patch % 100)) -eq 99 ]; then
      fail "'$2' is build 99, the last one the scheme has for a WordPress release"
    fi
    echo "${chart_major}.${chart_minor}.$((chart_patch + 1))"
    ;;

  check)
    [ $# -eq 3 ] || usage
    parse_chart "$2"
    parse_wordpress "$3"
    if [ "$chart_major" != "$wp_major" ] || [ "$chart_minor" != "$wp_minor" ]; then
      fail "chart version $2 and appVersion $3 differ in major or minor"
    fi
    # A build number past 99 would land in the next WordPress release's range.
    if [ $((chart_patch / 100)) -ne "$wp_patch" ]; then
      fail "chart version $2 does not belong to appVersion $3: its patch component must be from $((wp_patch * 100)) to $((wp_patch * 100 + 99))"
    fi
    echo "chart version $2: WordPress ${wp_major}.${wp_minor}.${wp_patch}, build $((chart_patch % 100))"
    ;;

  *)
    usage
    ;;
esac
