#!/usr/bin/env bash
# Overlay patch must stay in sync with the live local pi-cursor checkout.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH="$ROOT/pi/pi-cursor-overlay/subagent.patch"
APPLY="$ROOT/pi/pi-cursor-overlay/apply.sh"
LIVE="${PI_CURSOR_SRC:-$HOME/.pi/agent/src/pi-cursor}"
PASS=0
FAIL=0

assert_ok() {
  local name="$1"
  shift
  if "$@"; then
    PASS=$((PASS + 1))
    printf 'ok - %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf 'not ok - %s\n' "$name"
  fi
}

assert_contains() {
  local name="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -Fq -- "$needle"; then
    PASS=$((PASS + 1))
    printf 'ok - %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf 'not ok - %s (missing %s)\n' "$name" "$needle"
  fi
}

assert_ok "apply.sh is executable" test -x "$APPLY"
assert_ok "patch exists" test -f "$PATCH"

patch="$(cat "$PATCH")"
assert_contains "patch keeps workflowScript slim exception" "$patch" "Never set model or thinking in the tool arguments"
assert_contains "patch rejects Cursor-native Task" "$patch" "Cursor-native Task is unavailable"
assert_contains "patch adds field 28" "$patch" "SubagentArgs subagent_args = 28"
assert_ok "patch does not vendor generated agent_pb.ts" \
  bash -c '! grep -q "^diff --git a/src/proto/agent_pb.ts" "$0"' "$PATCH"

if [[ -f "$LIVE/src/stream/request-build.ts" ]]; then
  assert_ok "live source has slim exception" \
    grep -Fq "Never set model or thinking in the tool arguments" "$LIVE/src/stream/request-build.ts"
  assert_ok "live source rejects native Task" \
    grep -Fq "Cursor-native Task is unavailable" "$LIVE/src/stream/server-messages.ts"
  assert_ok "live dist has overlay" \
    grep -Fq "Cursor-native Task is unavailable" "$LIVE/dist/index.js"

  out="$("$APPLY" "$LIVE")"
  assert_contains "apply.sh is idempotent on live tree" "$out" "already applied"

  tmp="$(mktemp -d)"
  files=(
    proto/agent.proto
    src/stream/request-build.ts
    src/stream/server-messages.ts
    tests/request-size.test.ts
    tests/native-subagent-rejection.test.ts
  )
  for f in "${files[@]}"; do
    mkdir -p "$tmp/$(dirname "$f")"
    cp "$LIVE/$f" "$tmp/$f"
  done
  (cd "$tmp" && git apply -R -p1 "$PATCH")
  assert_ok "reverse overlay removes slim exception" \
    bash -c '! grep -Fq "Never set model or thinking in the tool arguments" "$0/src/stream/request-build.ts"' "$tmp"
  (cd "$tmp" && git apply -p1 "$PATCH")
  round=0
  for f in "${files[@]}"; do
    if diff -q "$tmp/$f" "$LIVE/$f" >/dev/null; then
      round=$((round + 1))
    else
      FAIL=$((FAIL + 1))
      printf 'not ok - round-trip %s\n' "$f"
    fi
  done
  if (( round == ${#files[@]} )); then
    PASS=$((PASS + 1))
    printf 'ok - reverse+forward round-trips live overlay files\n'
  fi
  rm -rf "$tmp"
else
  printf 'ok - skip live-tree checks (%s absent)\n' "$LIVE"
  PASS=$((PASS + 1))
fi

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  exit 1
fi
