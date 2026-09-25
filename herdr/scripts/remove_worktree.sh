#!/usr/bin/env bash
# Delete the focused worktree checkout without confirmation; Herdr closes its
# workspace and tabs, then deletes its branch. Never forces: a dirty checkout is
# kept and reported.
set -uo pipefail

herdr_bin="${HERDR_BIN_PATH:-herdr}"
ws="${HERDR_ACTIVE_WORKSPACE_ID:-}"

notify() { "$herdr_bin" notification show "$1" --body "$2" >/dev/null 2>&1; }

[[ -n "$ws" ]] || exit 1

info="$("$herdr_bin" workspace get "$ws" 2>/dev/null | python3 -c '
import json, sys
t = json.load(sys.stdin)["result"]["workspace"].get("worktree") or {}
print("1" if t.get("is_linked_worktree") else "0")
print(t.get("repo_root", ""))
print(t.get("checkout_path", ""))
')"
{ read -r linked; read -r repo; read -r checkout; } <<<"$info"

if [[ "$linked" != "1" ]]; then
  notify "Not a worktree" "The focused workspace is not a linked worktree."
  exit 1
fi

branch="$(git -C "$checkout" branch --show-current 2>/dev/null)"

if ! out="$("$herdr_bin" worktree remove --workspace "$ws" 2>&1)"; then
  notify "Worktree not removed" "$(echo "$out" | sed '/Are you an AI/,$d' | head -c 300)"
  exit 1
fi

if [[ -n "$branch" ]] && ! out="$(git -C "$repo" branch -D "$branch" 2>&1)"; then
  notify "Branch not deleted" "$out"
  exit 1
fi
