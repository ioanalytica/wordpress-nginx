#!/bin/bash

set -euo pipefail

# Determine push mode: ENV default (compatible with sub-script calls); a flag overrides ENV.
PUSH="${PUSH:-0}"
# Skip the confirmation prompt when CI=1 or ASSUME_YES=1; -y/--yes overrides ENV.
ASSUME_YES="${ASSUME_YES:-0}"
if [ "${CI:-0}" = "1" ] || [ "${CI:-}" = "true" ]; then ASSUME_YES=1; fi
# Release builds are uncached by default; --cache speeds up local iteration.
NO_CACHE=1
for arg in "$@"; do
  case "$arg" in
    --push)     PUSH=1 ;;
    --no-push)  PUSH=0 ;;
    --cache)    NO_CACHE=0 ;;
    --no-cache) NO_CACHE=1 ;;
    -y|--yes)   ASSUME_YES=1 ;;
    *) echo "WARN: ignoring unknown argument '$arg'" >&2 ;;
  esac
done

# The image tag follows the chart version, so both stay in lockstep.
RAW="$(
  grep -m1 -E '^version:[[:space:]]*' ../../chart/Chart.yaml \
  | sed -E 's/^version:[[:space:]]*"?([^"#\r]+)"?.*/\1/' \
  | tr -d '\r'
)"

if [ -z "${RAW:-}" ]; then
  echo "ERROR: could not read chart version from ../../chart/Chart.yaml"
  exit 1
fi

# Docker tag friendly (no '+')
TAG="${RAW//+/-}"

echo "Using tag: $TAG"

PROD_IMAGE="ghcr.io/ioanalytica/wordpress-nginx-wpscan:${TAG}"

# NOTE: a GHCR package is created private on its first push, independently of the
# source repository's visibility. Until it is switched to public once, in-cluster
# pulls fail with "not found" (GHCR answers anonymous clients with 404, not 403):
#   https://github.com/users/ioanalytica/packages/container/wordpress-nginx-wpscan/settings

# Mode label: push builds multi-arch, local builds host-arch only (--load cannot
# load a multi-arch manifest list into the local Docker daemon).
if [ "$PUSH" = "1" ]; then
  MODE_LABEL="push (multi-arch amd64+arm64)"
else
  MODE_LABEL="local (host arch, --load)"
fi

if [ "$ASSUME_YES" = "1" ]; then
  echo "Build ${MODE_LABEL} for tag ${TAG} (ASSUME_YES — no prompt)."
else
  read -r -p "Build ${MODE_LABEL} for tag ${TAG} (y/N)? " REPLY || REPLY=""
  if [[ ! "$REPLY" =~ ^[yY]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# Seeded with --pull (used by both branches) so the array is never empty —
# bash 3.2 treats an empty array as unbound under `set -u`.
BUILD_ARGS=(--pull)
if [ "$NO_CACHE" = "1" ]; then BUILD_ARGS+=(--no-cache); fi

echo "Linting Dockerfile …"
hadolint Dockerfile

echo "Building ${PROD_IMAGE} …"
if [ "$PUSH" = "1" ]; then
  # docker login ghcr.io
  # Multi-arch only on push — the registry holds the manifest list.
  docker buildx build "${BUILD_ARGS[@]}" --platform linux/amd64,linux/arm64 -t "${PROD_IMAGE}" . --push
else
  # Local: without --platform buildx builds for the host arch and --load loads the
  # single-arch image into the local Docker daemon (multi-arch + --load is unsupported).
  docker buildx build "${BUILD_ARGS[@]}" -t "${PROD_IMAGE}" . --load
fi

# end
