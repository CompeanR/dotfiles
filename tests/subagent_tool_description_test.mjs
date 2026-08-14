import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import test from "node:test"

const description = readFileSync(
  new URL("../pi/subagent-tool-description.md", import.meta.url),
  "utf8",
)

test("describes the installed workflowScript execution contract", () => {
  assert.match(description, /workflowScript/)
  assert.match(description, /return runs\.run/)
  assert.doesNotMatch(description, /Use `\{ agent, task \}` for one child/)
  assert.match(description, /Do not put task text in `action`/)
})

test("keeps Cursor parents from overriding child models", () => {
  assert.match(description, /async: false/)
  assert.match(description, /never set `model` or `thinking`/)
  assert.match(description, /let the configured agent resolve them/)
})
