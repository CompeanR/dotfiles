---
name: engram-prune
description: >
  Audit, prune, migrate, and consolidate Engram persistent memory observations directly via SQLite.
  Trigger: When the user asks to clean up memories, prune engram, merge project keys, audit observations, or when search results return too much noise.
license: Apache-2.0
metadata:
  author: gentleman-programming
  version: "1.0"
---

## When to Use

- User says "prune engram", "clean up memories", "too much noise", "memory cleanup"
- `mem_search` returns irrelevant results consistently
- Multiple project keys exist for the same codebase
- After a major milestone when shipped SDD artifacts should be archived
- Observation count exceeds ~200 for a single project

---

## Database Location

The active Engram SQLite database lives at `~/.engram/engram.db`.

Verify before operating:

```bash
ls -la ~/.engram/engram.db
```

---

## Step 0: ALWAYS Backup First

```bash
cp ~/.engram/engram.db ~/.engram/engram.db.backup-$(date +%Y%m%d-%H%M%S)
```

Non-negotiable. Every prune session starts with a backup.

---

## Step 1: Diagnosis — Run the Audit Query

Run the audit query from [assets/audit.sql](assets/audit.sql) to understand what you're working with.

This gives you:
- Total active observations per project
- Breakdown by type
- Split of SDD artifacts vs real architecture
- Age distribution (how many are older than 30/60/90 days)
- Duplicate title detection

**Read the numbers before deleting anything.** If a project has < 100 observations, it probably doesn't need pruning.

---

## Step 2: Classification — What's Noise vs Signal

### Noise (safe to delete)

| Type | Pattern | Why it's noise |
|------|---------|---------------|
| `session_summary` | **Older than 30 days** | Describes state that likely changed. Code is the source of truth. |
| `session_summary` | SDD sub-agent phase sessions | Process logs — the actual artifacts contain the real content. Identifiable by goals like "Create the SDD task breakdown", "Write the sdd-spec artifact", "Execute the SDD design phase". |
| `session_summary` | Micro Q&A sessions | Goals like "Explain X", "Clarify Y", "Answer whether Z" — conceptual Q&A with no code changes. |
| SDD planning artifacts | `topic_key LIKE 'sdd/%/{explore,proposal,spec,design,tasks}'` for SHIPPED changes | Intermediate planning for work that's done. Only the `completed` marker has lasting value, and even that is optional. |
| `decision` | Early UI micro-decisions ("starting X screen", "refined Y layout") | Screens get rewritten. These describe states that no longer exist. |
| `bugfix` | Fixes for code rewritten 2+ times since | The lesson is stale because the code doesn't exist anymore. |
| `discovery` | One-shot verifications ("verified X is Y") where Y was then fixed | The finding was addressed — keeping it pollutes searches. |
| `discovery` | Meta observations about engram itself | Tooling knowledge, not project knowledge. |
| Any | Titles starting with `[DELETED]` or `[INVALIDATED]` | Already marked as dead. |

### Signal (keep)

| Type | Pattern | Why it's signal |
|------|---------|----------------|
| `decision` | `topic_key LIKE 'follow-up/%'` | Active work items — THE source of truth for pending work |
| `session_summary` | **Last 30 days** with real implementation work | Contains commit SHAs, unique discoveries not saved elsewhere, relevant file lists. Review before deleting. |
| `architecture` | Describes CURRENT codebase structure | Still true today |
| `bugfix` | Lessons that apply to current code | Prevents re-introducing the same bug |
| `discovery` | Lasting technical learnings (API behavior, library gotchas) | Saves future debugging time |
| `pattern` | Established conventions | Must be preserved for consistency |
| `preference` | User/project preferences | Must be preserved across sessions |
| `config` | SDD init context, skill registry | Infrastructure knowledge |
| SDD artifacts | For ACTIVE (not shipped) changes | Still needed for `/sdd-continue` |

### Decision tree

```
Is it a follow-up topic key?               → KEEP (always)
Is it a session_summary older than 30 days? → DELETE
Is it a session_summary for SDD sub-agent?  → DELETE
Is it a session_summary for Q&A?            → DELETE
Is it a recent session_summary with real work? → REVIEW (may contain unique commit SHAs, discoveries)
Is it an SDD artifact for a shipped change? → DELETE
Is it about code that was rewritten 2+ times? → DELETE
Is it a one-shot finding that was addressed?  → DELETE
Is it meta (about engram/tooling itself)?     → DELETE
Is it about current code/conventions?         → KEEP
Is it a lasting lesson?                       → KEEP
```

### Session Summary Triage (for recent ones you keep)

Recent session summaries may contain information not captured elsewhere. Before deleting, check:

1. **Commit SHAs** — are they recorded in any other observation? If not, the session summary is the only link between code and context.
2. **Discoveries section** — were these saved as separate `discovery` observations? Often they weren't.
3. **Next Steps** — did these become `follow-up/*` topic keys? If not, the intent may be lost.

If a recent session summary has unique information, **extract it first** — save the valuable bits as proper typed observations (decision, discovery, bugfix), THEN delete the session summary.

---

## Step 3: Execute — Use Bulk SQL

**NEVER use `mem_update` for bulk operations.** It's one-at-a-time and burns context. Go directly to SQLite.

Engram uses **soft delete** via the `deleted_at` column. Set it to `datetime('now')` to remove an observation from search results without destroying it.

### Delete session summaries (age-based + pattern-based)

```sql
-- Old session summaries (> 30 days) — safe to bulk delete
UPDATE observations SET deleted_at = datetime('now')
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'session_summary'
AND created_at < datetime('now', '-30 days');

-- SDD sub-agent session summaries (any age) — process logs, not knowledge
UPDATE observations SET deleted_at = datetime('now')
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'session_summary'
AND (
  content LIKE '%SDD task breakdown%' OR
  content LIKE '%sdd-spec artifact%' OR
  content LIKE '%sdd-design%artifact%' OR
  content LIKE '%sdd-explore%artifact%' OR
  content LIKE '%SDD proposal%artifact%' OR
  content LIKE '%sdd-verify%' OR
  content LIKE '%sdd-init%'
);

-- Micro Q&A session summaries (any age) — no code changes, just explanations
UPDATE observations SET deleted_at = datetime('now')
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'session_summary'
AND (
  content LIKE '%Explain %' OR
  content LIKE '%Clarify %' OR
  content LIKE '%Answer whether%'
)
AND content NOT LIKE '%Implement%'
AND content NOT LIKE '%commit%';
```

**Recent session summaries (< 30 days) with real implementation work**: review manually before deleting. Check for commit SHAs, unique discoveries, and Next Steps not captured elsewhere.

### Delete shipped SDD artifacts

```sql
UPDATE observations SET deleted_at = datetime('now')
WHERE deleted_at IS NULL AND project = '{PROJECT}'
AND topic_key LIKE 'sdd/%'
AND topic_key NOT LIKE 'sdd/%/completed'  -- keep completed markers if desired
AND topic_key IN (
  -- List specific shipped change topic keys
  'sdd/{change-name}/explore',
  'sdd/{change-name}/proposal',
  'sdd/{change-name}/spec',
  'sdd/{change-name}/design',
  'sdd/{change-name}/tasks',
  'sdd/{change-name}/apply-progress',
  'sdd/{change-name}/verify-report'
);
```

### Delete by ID list (after manual review)

```sql
UPDATE observations SET deleted_at = datetime('now')
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND id IN (
  -- IDs identified during audit
  123, 456, 789
);
```

### Migrate project keys

```sql
-- Migrate observations
UPDATE observations SET project = '{NEW_KEY}', updated_at = datetime('now')
WHERE project = '{OLD_KEY}' AND deleted_at IS NULL;

-- Migrate sessions
UPDATE sessions SET project = '{NEW_KEY}'
WHERE project = '{OLD_KEY}';
```

---

## Step 4: Verify — Run Post-Prune Check

After pruning, verify:

1. **Count is reasonable** (target: < 200 per project)
2. **Follow-ups are searchable**: `mem_search(query: "follow-up", project: "{PROJECT}")`
3. **No accidental deletions**: spot-check a few kept observations

Run the verify query from [assets/verify.sql](assets/verify.sql).

---

## Step 5: Hard Delete + Vacuum (optional, recommended)

Soft-deleted rows don't pollute searches but they DO pollute sync exports and waste disk space. After confirming the prune is correct (backups exist), hard-delete:

```sql
DELETE FROM observations WHERE deleted_at IS NOT NULL AND project = '{PROJECT}';
```

Then reclaim disk space:

```bash
sqlite3 ~/.engram/engram.db "VACUUM;"
```

If syncing across machines, re-export after hard delete:

```bash
rm -rf .engram/chunks/ .engram/manifest.json
engram sync --project {PROJECT}
git add .engram/ && git commit -m "sync: clean export after prune"
```

---

## Step 6: Record — Save What You Did

```
mem_save(
  title: "Engram prune: {before} → {after} observations",
  type: "config",
  project: "{PROJECT}",
  topic_key: "engram/prune-log",
  content: "**What**: Pruned from {before} to {after}. Deleted: {summary}. **Why**: {reason}. **Learned**: {any new noise patterns found}"
)
```

---

## Reusable Queries Reference

All queries are in [assets/](assets/):

| File | Purpose |
|------|---------|
| `audit.sql` | Full diagnostic — run FIRST |
| `noise-candidates.sql` | Find likely noise by heuristic |
| `verify.sql` | Post-prune health check |
| `migrate.sql` | Project key migration template |

---

## Critical: Project Key Casing

`engram sync` normalizes project names to **lowercase** before exporting. If your DB stores `MyProject` but sync searches for `myproject`, the export will be empty.

**Rule**: Always use lowercase project keys in Engram. If you find PascalCase or mixed-case keys, migrate them:

```sql
UPDATE observations SET project = 'myproject', updated_at = datetime('now') WHERE project = 'MyProject';
UPDATE sessions SET project = 'myproject' WHERE project = 'MyProject';
UPDATE user_prompts SET project = 'myproject' WHERE project = 'MyProject';
```

Then **nuke old chunks and do a full re-export** — delta exports don't re-export renamed observations:

```bash
rm -rf .engram/chunks/ .engram/manifest.json
engram sync --project myproject
git add .engram/ && git commit -m "sync: full re-export under myproject"
git push
```

On the receiving machine:
```bash
git pull
engram sync --import
```

The `migrate.sql` asset handles the DB rename — but you MUST also re-export.

---

## Anti-Patterns

| Don't | Do instead |
|-------|-----------|
| Use `mem_update` for bulk ops | Direct SQLite queries |
| Delete without backup | `cp` the DB first |
| Delete follow-up topic keys | These are sacred — always KEEP |
| Hard-delete rows WITHOUT backup | Always backup first, soft-delete to review, THEN hard-delete after confirming |
| Prune without diagnosis | Run `audit.sql` first |
| Prune projects with < 100 obs | Probably not worth it |
| Delete active SDD artifacts | Only prune SHIPPED changes |
| Blindly delete ALL session summaries | Recent ones (< 30 days) may contain unique commit SHAs and discoveries — review first |
| Delete without extracting unique info | If a session summary has commit SHAs or discoveries not saved elsewhere, extract them into proper observations BEFORE deleting |
