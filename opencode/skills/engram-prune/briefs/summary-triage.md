# Brief — session-summary triage (role: explore, read-only)

Substitute {PROJECT}, {COUNT}, {BACKUP}, {REPO}. The worker inherits no
context, so every fact it needs must be in the brief.

---

GOAL
Triage all {COUNT} session-summary rows into KEEP / DROP / EXTRACT-THEN-DROP.
Analysis only — produce a report, modify nothing.

DATABASE (read-only, disposable backup copy)
{BACKUP}
Open via python3 stdlib sqlite3 with a read-only URI:
  sqlite3.connect('file:{BACKUP}?mode=ro', uri=True)
The `sqlite3` CLI is NOT installed — python3 only.
NEVER open ~/.engram/engram.db (the live DB, no .backup suffix).

SCOPE
Table `observations`, WHERE project='{PROJECT}' AND deleted_at IS NULL
AND type='session_summary'. Exactly {COUNT} rows.
Inspect the schema first: SELECT sql FROM sqlite_master WHERE type='table';

CONTEXT
An AI assistant auto-saved a summary at the end of nearly every session.
Most follow a template: Goal / Instructions / Discoveries / Accomplished /
Next Steps / Relevant Files. The source lives in a git repo at {REPO} with a
detailed commit history; read it read-only to check whether a summary's
content is already recorded by the code or by `git log`.
The memory's job is future retrieval of DURABLE facts. Narration of work that
git already records is noise.

DROP when the whole substance is one of:
  - Process narration: "committed X", "opened PR #N", "rebased", "tests
    passed", "fixed lint", "updated fixtures", "pushed to remote".
  - A one-run verification result with no finding about WHY.
  - A Q&A session ("Explain X", "Clarify X", "Answer whether X") whose answer
    merely describes code that still exists and can be re-read on demand.
    Verify the code still exists first; a NON-OBVIOUS rationale is a KEEP.
  - An audit whose findings were all subsequently fixed.
  - Session bookkeeping about the assistant's own tooling, sub-agents, or
    memory operations.
KEEP when it contains any of:
  - A user preference or a correction about how the developer wants to work.
  - A bug ROOT CAUSE, gotcha, or edge case that could recur.
  - Architectural rationale — why a design was chosen or rejected.
  - External-world knowledge not in the repo: app-store status and rejections,
    platform entitlements, third-party licensing, marketing and distribution,
    device/network/simulator setup, tax or business research.
  - A finding that exists ONLY here (see EXTRACT).
EXTRACT-THEN-DROP when the row is mostly narration but its Discoveries hold one
durable fact saved nowhere else. Give the EXACT replacement row to save first:
a title (<=60 chars) and content written as a standalone durable fact with
**What** / **Why** lines — not as session narration. Before calling a fact
unique, search the other non-session_summary rows in the project for it.

HARD KEEP-GUARDS — never propose for deletion; report how many you excluded:
  pinned = 1  |  review_after IS NOT NULL  |  topic_key LIKE 'follow-up/%'

CALIBRATION
Both over- and under-cutting are failures. Judge each row on its own content.
Expect roughly 10-15% of summaries to be droppable — a result near 1% means you
judged from titles, and a result near 50% means you ignored real discoveries.

METHOD
Read every row IN FULL — never judge from titles or 300-char previews. Work in
batches, keep a running classification table. Throwaway python under /tmp only.

RETURN SHAPE
1. VERDICT: KEEP / DROP / EXTRACT counts, dominant noise in one paragraph.
2. DROP table: id | created_at | one-line reason | a QUOTED phrase from the row
   proving the reason. Every dropped id appears here — no unexplained ids.
3. EXTRACT table: id | durable fact | replacement title | replacement content.
4. KEEP highlights: 10 rows you nearly dropped, with the sentence that saved each.
5. Paste-ready comma-separated DROP list and EXTRACT list, with remaining counts.
6. Anything you could not determine.

Write the full report to /tmp/engram-summaries-report.md and print 1, 3, 5.
