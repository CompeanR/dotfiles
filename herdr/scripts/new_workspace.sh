#!/usr/bin/env bash
# New Space in the calling pane's cwd, prompting for its first tab name in the
# style of the native new-tab prompt. Enter creates it (empty keeps Herdr's
# generated name); Esc closes without creating.
set -euo pipefail

herdr_bin="${HERDR_BIN_PATH:-herdr}"

accent=$'\033[38;2;250;189;47m'
dim=$'\033[2m'
reset=$'\033[0m'

name=""
draw() { printf '\033[2;1H\033[K %s' "$name"; }

printf '\033[2J\033[H %snew tab%s\n\n\n %senter create  esc cancel%s' "$accent" "$reset" "$dim" "$reset"
draw

while IFS= read -rsn1 key; do
  case "$key" in
    "") break ;;
    $'\e')
      read -rsn1 -t 0.01 rest || exit 0
      while read -rsn1 -t 0.01 rest && [[ "$rest" != [A-Za-z~] ]]; do :; done
      ;;
    $'\177' | $'\b') name="${name%?}" ;;
    [[:print:]]) name+="$key" ;;
  esac
  draw
done

tab_id="$("$herdr_bin" workspace create --cwd "$PWD" --focus | jq -r '.result.tab.tab_id')"
[[ -n "$name" ]] && "$herdr_bin" tab rename "$tab_id" "$name" >/dev/null
exit 0
