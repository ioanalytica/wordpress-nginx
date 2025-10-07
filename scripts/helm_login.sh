#!/usr/bin/env bash
set -euo pipefail

: "${HARBOR_HOST:?missing}"
: "${REGISTRY_USER:?missing}"
: "${REGISTRY_PASSWORD:?missing}"

echo "$REGISTRY_PASSWORD" | helm registry login "$HARBOR_HOST" \
  --username "$REGISTRY_USER" \
  --password-stdin

