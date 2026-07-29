#!/usr/bin/env bash
# Dispatch a Pi-backed sub-agent through herdr, using the same
# role -> model/thinking mapping as dotfiles/pi/settings.json
# (subagents.agentOverrides) and the same role contract files
# as dotfiles/pi/agents/work-<role>.md. Pi's own setup stays the
# single source of truth; this script only reads it.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: dispatch.sh <role> <brief> [options]

Roles: explore | apply | design | verify
  (maps to pi/agents/work-<role>.md and the work-<role> entry in
  pi/settings.json's subagents.agentOverrides)

Options:
  --cwd <path>       Working directory for the spawned pi session (default: $PWD)
  --pane <id>        Split from this exact pane instead of using/creating the
                     shared "subagents" tab
  --tab-label <text> Label of the shared tab to find-or-create (default: subagents)
  --timeout <ms>     Max time to wait for the agent to settle (default: 300000)
  --name <name>      Explicit agent name (default: work-<role>-<pid>)
  --keep             Leave the pane open after reading output (for inspection)
EOF
}

[[ $# -ge 2 ]] || { usage; exit 1; }
role="$1"; brief="$2"; shift 2

cwd="$PWD"
timeout_ms=300000
name="work-${role}-$$"
base_pane=""
tab_label="subagents"
keep=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd) cwd="$2"; shift 2 ;;
    --pane) base_pane="$2"; shift 2 ;;
    --tab-label) tab_label="$2"; shift 2 ;;
    --timeout) timeout_ms="$2"; shift 2 ;;
    --name) name="$2"; shift 2 ;;
    --keep) keep=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DOTFILES_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PI_SETTINGS="$DOTFILES_ROOT/pi/settings.json"
ROLE_FILE="$DOTFILES_ROOT/pi/agents/work-${role}.md"

[[ -f "$PI_SETTINGS" ]] || { echo "missing $PI_SETTINGS" >&2; exit 1; }
[[ -f "$ROLE_FILE" ]] || { echo "unknown role '$role': no $ROLE_FILE" >&2; exit 1; }

override_key="work-${role}"
model=$(jq -r --arg k "$override_key" '.subagents.agentOverrides[$k].model // empty' "$PI_SETTINGS")
thinking=$(jq -r --arg k "$override_key" '.subagents.agentOverrides[$k].thinking // "medium"' "$PI_SETTINGS")
[[ -n "$model" ]] || { echo "no subagents.agentOverrides.$override_key.model in $PI_SETTINGS" >&2; exit 1; }

tools=$(python3 - "$ROLE_FILE" <<'PY'
import sys, yaml
path = sys.argv[1]
text = open(path).read()
frontmatter = text.split('---')[1]
data = yaml.safe_load(frontmatter)
print(','.join(data.get('tools', [])))
PY
)

echo "role=$role model=$model thinking=$thinking tools=$tools" >&2

# Sub-agent panes live in a shared tab (default label "subagents"), not split
# into the orchestrator's own tab — keeps the orchestrator's window clean.
# --pane overrides this entirely and splits from that exact pane instead.
if [[ -z "$base_pane" ]]; then
  workspace_id=$(herdr pane current | jq -r '.result.pane.workspace_id')

  # Guard find-or-create against a race: two dispatch.sh instances launched
  # at once could otherwise each see no matching tab and both create one.
  lock_dir="${TMPDIR:-/tmp}/herdr-subagent-tab-lock"
  mkdir -p "$lock_dir"
  lock_file="$lock_dir/${workspace_id}.lock"
  exec {lock_fd}>"$lock_file"
  flock "$lock_fd"

  subagent_tab_id=$(herdr tab list --workspace "$workspace_id" \
    | jq -r --arg l "$tab_label" '.result.tabs[] | select(.label==$l) | .tab_id' | head -n1)

  if [[ -z "$subagent_tab_id" ]]; then
    create_out=$(herdr tab create --workspace "$workspace_id" --cwd "$cwd" --label "$tab_label" --no-focus)
    base_pane=$(echo "$create_out" | jq -r '.result.root_pane.pane_id')
  else
    base_pane=$(herdr pane list --workspace "$workspace_id" \
      | jq -r --arg t "$subagent_tab_id" '.result.panes[] | select(.tab_id==$t) | .pane_id' | head -n1)
  fi

  flock -u "$lock_fd"
  exec {lock_fd}>&-
fi
[[ -n "$base_pane" ]] || { echo "could not determine a base pane to split from" >&2; exit 1; }

split_out=$(herdr pane split --pane "$base_pane" --direction down --ratio 0.35 --no-focus --cwd "$cwd")
pane_id=$(echo "$split_out" | jq -r '.result.pane.pane_id')
echo "spawned pane $pane_id" >&2

cleanup() {
  if [[ "$keep" -eq 0 ]]; then
    herdr pane close "$pane_id" >/dev/null 2>&1 || true
  else
    echo "pane kept: $pane_id (agent: $name)" >&2
  fi
}
trap cleanup EXIT

# A just-split pane can still be reaching its interactive shell prompt when
# agent start fires, which fails fast with agent_pane_busy rather than
# waiting. Retry briefly instead of treating that as a real failure.
start_ok=0
for _ in 1 2 3 4 5; do
  if herdr agent start "$name" --kind pi --pane "$pane_id" \
    -- --model "$model" --thinking "$thinking" --tools "$tools" \
       --append-system-prompt "$ROLE_FILE" >/dev/null 2>/tmp/herdr-subagent-start-err.$$; then
    start_ok=1
    break
  fi
  if ! grep -q agent_pane_busy /tmp/herdr-subagent-start-err.$$ 2>/dev/null; then
    cat /tmp/herdr-subagent-start-err.$$ >&2
    rm -f /tmp/herdr-subagent-start-err.$$
    exit 1
  fi
  rm -f /tmp/herdr-subagent-start-err.$$
  sleep 2
done
[[ "$start_ok" -eq 1 ]] || { echo "agent start: pane never became available" >&2; exit 1; }

seq_of() {
  herdr agent get "$name" 2>/dev/null | jq -r '.result.agent.state_change_seq // "unknown"'
}

# Fire-and-forget, then wait separately: `prompt --wait` has a fixed 5s
# "did the state change yet" grace window that false-negatives under
# concurrent dispatch. Decoupling avoids that race entirely.
#
# But `agent start`'s interactive_ready can fire before pi finishes loading
# skills/extensions (slower here because of --tools/--append-system-prompt),
# so a prompt sent right after start can land in the input line without the
# Enter registering. If we just resend, the second send's text appends to
# the still-unsent first copy and both get submitted together as ONE
# concatenated message once Enter finally lands. Clear the input line
# first (ctrl+c, per pi's own "clear/exit" binding) so a resend is a clean
# retry, not a concatenation.
before_seq="$(seq_of)"
herdr agent prompt "$name" "$brief" >/dev/null
sleep 8
if [[ "$(seq_of)" == "$before_seq" ]]; then
  echo "no state change 8s after prompt; clearing input and resending once" >&2
  herdr agent send-keys "$name" ctrl+c >/dev/null 2>&1 || true
  herdr agent prompt "$name" "$brief" >/dev/null
  sleep 8
  if [[ "$(seq_of)" == "$before_seq" ]]; then
    echo "still no state change after resend; proceeding to wait anyway (may just be a slow start)" >&2
  fi
fi

wait_out=$(herdr agent wait "$name" --until idle --until done --until blocked --timeout "$timeout_ms")
status=$(echo "$wait_out" | jq -r '.result.agent.agent_status // "unknown"')

# `herdr agent read` defaults to a ~80-line cap, so long reports (design /
# verify especially) get silently truncated -- no error, just a partial
# answer. `--lines N --source recent-unwrapped` lifts that, but still
# returns raw TUI chrome (startup banner, skill list, tool-call rendering,
# box-drawing). pi's own session transcript on disk gives the clean final
# assistant text instead, so prefer it and keep the pane read as fallback.
# Per herdr's docs, full-screen agents can render to the alternate screen
# where scrollback does not persist at all -- another reason the transcript
# is the more reliable source. (The docs' own workaround -- have the agent
# write its answer to a Markdown file -- can't work for read-only roles
# like explore/design/verify, which have no write tool.)
session_file=$(herdr agent get "$name" 2>/dev/null | jq -r '.result.agent.agent_session.value // empty')

if [[ -n "$session_file" && -f "$session_file" ]]; then
  python3 - "$session_file" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    records = [json.loads(l) for l in f if l.strip()]
last_assistant = None
for rec in records:
    if rec.get("type") == "message" and rec.get("message", {}).get("role") == "assistant":
        last_assistant = rec["message"]
if last_assistant is None:
    sys.exit(1)
texts = [b["text"] for b in last_assistant.get("content", []) if b.get("type") == "text"]
print("\n\n".join(texts))
PY
  if [[ $? -ne 0 ]]; then
    echo "no assistant message found in session transcript; falling back to pane read" >&2
    herdr agent read "$name" --source recent-unwrapped --lines 2000
  fi
else
  echo "no session transcript found; falling back to pane read (may be truncated)" >&2
  herdr agent read "$name" --source recent-unwrapped --lines 2000
fi

echo "--- final status: $status ---" >&2
