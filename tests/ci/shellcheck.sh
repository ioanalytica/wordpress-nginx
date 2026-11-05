#!/usr/bin/env bash
#
# Run shellcheck over every shell script of the repository. CI and a local
# run find the same files and use the same flags.
#
# The image's hooks and helpers have no .sh extension, so scripts are found
# by their shebang, among the tracked files and the new ones git does not
# ignore: a script is checked before its first commit.
#
# -S warning keeps the check to real problems. The notes below it are mostly
# SC2016, single quotes around a $ that sed, awk or a remote shell is meant
# to see, which the tests do on purpose throughout.
#
#   tests/ci/shellcheck.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

# Findings that stay, each for one file: the script is part of the image, and
# a pull request that changes no image must not edit it for a comment. Listed
# here with the reason; every other finding in these files still fails.
#   20-clean-wp-cache   SC3020: `&>` works in the image's shell, BusyBox ash.
#                       SC2115: the directory variables are set by the image
#                       (setup-wp-cli.sh), so the path is never just "/*".
#   rewrite-mail-from   SC2089, SC2090: NEWFROM is a mail header handed to
#                       awk through the environment, never run as a command;
#                       the quotes in it are meant literally.
exceptions() {
  case "$1" in
    docker/rootfs/etc/hooks/cleanup/20-clean-wp-cache) echo "SC2115,SC3020" ;;
    docker/rootfs/usr/local/utils/rewrite-mail-from) echo "SC2089,SC2090" ;;
  esac
}

# No mapfile: this also runs on the bash 3.2 of macOS.
files=()
while IFS= read -r f; do
  [ -f "$f" ] || continue
  if head -n 1 "$f" | grep -qE '^#!.*[/ ](ba|da|a)?sh([[:space:]]|$)'; then
    files+=("$f")
  fi
done < <(git ls-files -co --exclude-standard)

[ "${#files[@]}" -gt 0 ] || { echo "shellcheck: no scripts found, the discovery is broken" >&2; exit 1; }

echo "shellcheck: ${#files[@]} scripts"
status=0
plain=()
for f in "${files[@]}"; do
  codes="$(exceptions "$f")"
  if [ -n "$codes" ]; then
    shellcheck -x -S warning -e "$codes" "$f" || status=1
  else
    plain+=("$f")
  fi
done
shellcheck -x -S warning "${plain[@]}" || status=1
[ "$status" -eq 0 ] || exit 1
echo "shellcheck: OK"
