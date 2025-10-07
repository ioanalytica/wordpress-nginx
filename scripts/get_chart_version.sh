#!/usr/bin/env bash
set -euo pipefail

# Extracts 'version:' from chart/Chart.yaml (Helm chart version)
RAW="$(awk -F':' '/^[[:space:]]*version:/ { gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); gsub(/"/,""); print $2; exit }' ../chart/Chart.yaml)"
if [ -z "${RAW:-}" ]; then
  echo "ERROR: could not read chart version from chart/Chart.yaml" >&2
  exit 1
fi

# Docker tags are flexible but '+' in SemVer build metadata is often undesirable.
# Convert any '+' to '-' for the image tag while keeping RAW available for the chart itself.
SANITIZED="${RAW//+/-}"

# Print both in a simple format for CI
printf "RAW=%s\nSANITIZED=%s\n" "$RAW" "$SANITIZED"

