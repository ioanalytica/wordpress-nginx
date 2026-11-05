# shellcheck shell=bash
#
# Readers for the page "Try it locally" (examples/k3d/README.md), shared by
# run.sh and test.sh. run.sh runs the page's own shell blocks, so a command
# changed on the page is a command changed in the test.

TRY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXAMPLES="$TRY_ROOT/examples/k3d"
PAGE="$EXAMPLES/README.md"

# Where the page takes its values and its chart from; run.sh puts the
# checkout's values, and a chart directory if it is given one, in their place.
PAGE_URL="https://raw.githubusercontent.com/ioanalytica/wordpress-nginx/main/examples/k3d"
PAGE_CHART="oci://ghcr.io/ioanalytica/charts/wordpress-nginx"

# The release and the namespace of the page's install command.
# shellcheck disable=SC2034  # read by run.sh and test.sh
PAGE_RELEASE="demo"
# shellcheck disable=SC2034  # read by run.sh and test.sh
PAGE_NAMESPACE="wordpress"

# The page's shell blocks the run takes, as "HEADING|N": all of them.
# shellcheck disable=SC2034  # read by run.sh and test.sh
PAGE_BLOCKS=("## 1. |1" "## 2. |1" "## 2. |2" "## 3. |1" "## 3. |2"
             "## 3. |3" "## 4. |1" "## 4. |2" "## 5. |1" "## 6. |1"
             "## 6. |2" "## 6. |3" "## 6. |4" "## Clean up|1")

# The output blocks the run compares word for word with what the commands
# print, as "HEADING|N" of the plain blocks. The others are shortened on the
# page or hold values that differ from run to run; run.sh checks those by
# pattern.
# shellcheck disable=SC2034  # read by run.sh and test.sh
PAGE_OUTPUTS=("## 3. |1" "## 3. |2" "## 5. |1" "## 6. |1" "## 6. |3" "## 6. |4")

# page_block HEADING KIND N - the Nth code block of kind KIND ("sh", or ""
# for a plain one, the output the page shows) in the section whose heading
# starts with HEADING ("## 3. "). The section ends at the next heading; a
# line starting with # inside a block is a comment, not a heading.
page_block() {
  awk -v head="$1" -v kind="$2" -v n="$3" '
    /^```/ && !fence {
      fence = 1
      if (on && substr($0, 4) == kind && ++seen == n) take = 1
      next
    }
    /^```$/ && fence { fence = 0; if (take) exit; next }
    fence { if (take) print; next }
    /^#+ / { if (on) exit; if (index($0, head) == 1) on = 1 }' "$PAGE"
}

# localize CHART EXTRA - stdin with the checkout's examples/k3d in place of
# the page's URL and, when CHART is not empty, CHART in place of the released
# chart, followed by EXTRA (further helm flags).
localize() {
  local chart="${1:-$PAGE_CHART}" extra="${2:-}"
  sed -e "s|^url=$PAGE_URL\$|url=$EXAMPLES|" \
      -e "s|$PAGE_CHART |$chart ${extra:+$extra }|g"
}

# chart_images CHART - the images of ghcr.io/ioanalytica that the chart in
# the directory CHART runs with the page's values, one per line. The reindex
# key is a stand-in: only the image names matter.
chart_images() {
  helm template "$PAGE_RELEASE" "$1" -n "$PAGE_NAMESPACE" \
      -f "$EXAMPLES/values.yaml" --set idx.reindexApiKey=x \
    | sed -n 's/^ *image: *"\{0,1\}\(ghcr\.io\/ioanalytica\/[^"]*\)"\{0,1\} *$/\1/p' | sort -u
}

# unpublished IMAGE... - the images the registry does not have, one per line.
# Any other answer than "manifest unknown" fails: a registry that cannot be
# reached must not read as an image that is not published yet.
unpublished() {
  local image out
  for image in "$@"; do
    if ! out="$(docker manifest inspect "$image" 2>&1 >/dev/null)"; then
      case "$out" in
        *"manifest unknown"*|*"no such manifest"*) echo "$image" ;;
        *) echo "ERROR: $image: $out" >&2; return 1 ;;
      esac
    fi
  done
}
