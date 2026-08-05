#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/claude/scripts/pi-routing-reminder.sh"
SETTINGS="$ROOT/claude/settings.json"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

output=$(printf '{"hook_event_name":"UserPromptSubmit","prompt":"change auth"}' | timeout 1 "$HOOK") || fail "hook execution"
printf '%s' "$output" | jq -e '
  .hookSpecificOutput.hookEventName == "UserPromptSubmit" and
  (.hookSpecificOutput.additionalContext | contains("mcp__pi__subagent")) and
  (.hookSpecificOutput.additionalContext | contains("explore")) and
  (.hookSpecificOutput.additionalContext | contains("design")) and
  (.hookSpecificOutput.additionalContext | contains("apply")) and
  (.hookSpecificOutput.additionalContext | contains("verify")) and
  (.hookSpecificOutput.additionalContext | contains("trivial")) and
  (.hookSpecificOutput.additionalContext | contains("self-contained brief")) and
  (.hookSpecificOutput.additionalContext | contains("600000"))
' >/dev/null || fail "hook output contract"

printf 'malformed input' | timeout 1 "$HOOK" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null || fail "malformed input handling"

jq -e '
  .hooks.UserPromptSubmit as $groups |
  ($groups | length) == 1 and
  ($groups[0] | has("matcher") | not)
' "$SETTINGS" >/dev/null || fail "matcher-less settings entry"

printf 'ok - pi routing reminder\n'
