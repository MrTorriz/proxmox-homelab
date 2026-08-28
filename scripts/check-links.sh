#!/usr/bin/env bash
# check-links.sh — relative links must resolve, images must be used.
#
# For every tracked Markdown file, outside fenced code blocks:
#   * each ](relative/target) and <img src="relative/target"> must point at
#     an existing file (fragments are stripped before the check)
#   * http(s)://, mailto: and pure #fragment links are skipped
# Afterwards every file under docs/img must be referenced by at least one
# Markdown file — an unreferenced image is an orphan.
#
# Exit 1 with a list of findings, 0 when everything resolves.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

fail=0
declare -A referenced

while IFS= read -r md; do
    dir=$(dirname "$md")
    targets=$(awk '/^[[:space:]]*```/ { fence = !fence; next } !fence' "$md" \
        | grep -oE '\]\([^)]+\)|<img[^>]+src="[^"]+"' \
        | sed -E 's/^\]\(//; s/\)$//; s/^<img[^>]+src="//; s/"$//' \
        | sed -E 's/ "[^"]*"$//; s/#.*$//' \
        | grep -vE '^(https?:|mailto:|$)' || true)
    while IFS= read -r target; do
        [ -z "$target" ] && continue
        path="$dir/$target"
        if [ -e "$path" ]; then
            referenced["$(realpath --relative-to=. "$path")"]=1
        else
            printf 'broken link: %s -> %s\n' "$md" "$target"
            fail=1
        fi
    done <<< "$targets"
done < <(git ls-files '*.md')

for img in docs/img/*; do
    [ -f "$img" ] || continue
    if [ -z "${referenced[$img]:-}" ]; then
        printf 'orphan image: %s\n' "$img"
        fail=1
    fi
done

exit "$fail"
