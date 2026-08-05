#!/usr/bin/env bash
set -euo pipefail

cat >/dev/null

context=$(cat <<'EOF'
PI ROUTING CHECK: Before substantial work, identify independently scoped phases that should use mcp__pi__subagent. Route investigation to explore, implementation-ready architecture or planning to design, scoped implementation to apply, and independent validation of non-trivial work to verify. Use only the roles the task benefits from—not mechanically all four. Handle conversation, quick factual answers, obvious local edits, and tightly coupled work directly. Remain responsible for scoping, integration, and reviewing every result. Workers inherit no context, so provide a self-contained brief, correct cwd, explicit constraints, and timeout_ms >= 600000; omit watch unless visible execution is needed. Follow the tool description's safety warnings for nominally read-only roles.
EOF
)

jq -nc --arg context "$context" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $context
  }
}'
