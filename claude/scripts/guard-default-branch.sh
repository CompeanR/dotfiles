#!/usr/bin/env bash
# PreToolUse/Bash guard: force a confirmation before a commit or push lands on
# the repository's default branch. Detects the default branch from
# origin/HEAD so it works regardless of master/main naming.
set -uo pipefail

payload=$(cat)
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null) || exit 0

case "$cmd" in
    *"git commit"* | *"git push"*) ;;
    *) exit 0 ;;
esac

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0
[ -n "$branch" ] && [ "$branch" != "HEAD" ] || exit 0

default=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
if [ -z "$default" ]; then
    for candidate in main master; do
        if git show-ref --verify --quiet "refs/heads/$candidate"; then
            default="$candidate"
            break
        fi
    done
fi
[ -n "$default" ] || exit 0

if [ "$branch" = "$default" ]; then
    jq -nc --arg b "$branch" '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "ask",
            permissionDecisionReason: ("Currently on the default branch (" + $b + "). Create a feature branch before committing or pushing, unless you intend this to land on " + $b + " directly.")
        }
    }'
fi

exit 0
