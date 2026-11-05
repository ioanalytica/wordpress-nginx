#!/usr/bin/env bash
#
# Set the default of one entry of chart/values.schema.json.
#
# The schema repeats the default of every value, and
# chart/tests/schema-test.sh fails when one differs from chart/values.yaml.
# A change of a default by hand edits both files. The image trackers
# (.github/workflows/image-version-check.yml, dragonfly-version-check.yml)
# change a pinned tag in values.yaml with sed and call this for the schema.
#
#   scripts/schema-default.sh KEY VALUE [FILE]
#       KEY is the value's path in values.yaml, such as metrics.image.tag.
#       VALUE is set as text. FILE defaults to chart/values.schema.json.
set -euo pipefail

[ $# -ge 2 ] && [ $# -le 3 ] || { echo "usage: scripts/schema-default.sh KEY VALUE [FILE]" >&2; exit 2; }
key="$1"
value="$2"
file="${3:-$(dirname "${BASH_SOURCE[0]}")/../chart/values.schema.json}"

fail() {
  echo "schema-default: $*" >&2
  exit 1
}

[ -f "$file" ] || fail "$file does not exist"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# The entry of a.b.c is .properties.a.properties.b.properties.c. Only an
# entry that holds a text default is changed: anything else is a key this
# script was not written for.
jq --arg key "$key" --arg value "$value" '
  ($key | split(".") | map("properties", .)) as $path
  | if (getpath($path + ["default"]) | type) != "string"
    then error("no entry with a text default at " + $key)
    else setpath($path + ["default"]; $value)
    end
' "$file" > "$tmp" 2>/dev/null || fail "$key is not an entry of $file with a text default"

# Written in place, so the file keeps its mode. jq prints the schema in the
# layout it is kept in, so the line of the default is the only one to change.
cat "$tmp" > "$file"
