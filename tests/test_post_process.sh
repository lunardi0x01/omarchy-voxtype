#!/usr/bin/env bash
# Tests for post_process.sh: joining, tag stripping, history on/off.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf -- "$tmp"' EXIT
export HOME="$tmp" XDG_CONFIG_HOME="$tmp/config" VOXTYPE_HISTORY_FILE="$tmp/history.tsv"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

out=$(printf '*BEEP*\n This is a test.\n\n [BLANK_AUDIO] Second (MUSIC) line\n' | "$root/post_process.sh")
[[ $out == "This is a test. Second line" ]] || fail "join/strip: '$out'"
[[ $(wc -l < "$tmp/history.tsv") -eq 1 ]] || fail "history line not written"
line=$(cat "$tmp/history.tsv")
[[ $line == *$'\t'"This is a test. Second line" ]] || fail "history format: '$line'"
[[ $(stat -c %a "$tmp/history.tsv") == 600 ]] || fail "history permissions"

out=$(printf 'Keep NASA and (parentheses) and a*b*c\n' | "$root/post_process.sh")
[[ $out == "Keep NASA and (parentheses) and a*b*c" ]] || fail "over-stripping: '$out'"

mkdir -p "$tmp/config/voxtype"; touch "$tmp/config/voxtype/history-off"
printf 'Not logged\n' | "$root/post_process.sh" >/dev/null
[[ $(wc -l < "$tmp/history.tsv") -eq 2 ]] || fail "history-off was ignored"

out=$(printf '*BEEP*\n' | "$root/post_process.sh")
[[ -z $out ]] || fail "tag-only input should print nothing"
echo "post_process: ok"
