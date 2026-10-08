---
name: engram-prune
description: >
  Audit and prune Engram SQLite observations with backup-first, review-first
  soft-deletes. Candidate queries are review lists, never auto-delete lists.
  Use when the user asks to prune engram, clean up memories, merge project
  keys, audit observations, or when mem_search is too noisy.
license: Apache-2.0
metadata:
  author: gentleman-programming
  version: "1.3.0"
---

# Engram prune

Direct SQLite against `~/.engram/engram.db`. Do not use `mem_update` for bulk work.

**v1.3.0:** Adds the measured findings from a real 1,230-row run (see "What a real run looks like"). Expected yield is ~4%, not ~40%. Whole-document similarity is near-useless here; the real duplicate class is *containment* (`containment.py`). Retitling blank-titled rows beats deleting. Adds `validate-ids.py` (pre-write reconciliation check), `retitle.py`, and `briefs/` for delegating the two analysis passes.

**v1.2.1:** Candidate SQL is a review list. Age-based `session_summary` bulk UPDATE is gone. `verify.sql` does not target 0 summaries. TIER A keep-guards include `follow-up/*` on every candidate query. `run.py` refuses migrate without both `--old-key` and `--new-key`. Ignore any v1.0 copy that says "safe to delete" for those heuristics.

## What a real run looks like

Measured on 1,230 rows, 6 months of one project (2026-08-31):

| | |
|---|---|
| Rows cut | **49 (4%)** — 1230 → 1181 |
| Rows retitled | 30 blank titles → 0 |
| Duplicate clusters found by full pairwise TF-IDF over 644,680 pairs | **0** above 0.85 cosine; 52% false-positive rate at 0.50 |
| Dominant noise | workflow narration, *not* re-saved facts |

Three calibration lessons, each of which cost a wasted analysis pass:

1. **Do not estimate yield from row counts.** "1230 rows, must be bloated, cut to
   700" was wrong by an order of magnitude. Only content reading gives a number.
2. **Similarity clustering finds almost nothing.** Run it once to prove the
   negative, then move on. Budget it as a check, not as the main event.
3. **The real duplicate is containment, not similarity.** A short typed row
   (`**What** / **Why** / **Learned**`) beside a long `session_summary` from the
   same session, stating the same fact. Cosine scores that pair LOW because
   lengths and vocabulary differ. Find them structurally with adjacent ids and
   close timestamps — run `containment.py --project {PROJECT}`. Keep the typed row.

Cut composition from that run, as a prior for the next one:

| Bucket | Share |
|---|---|
| Workflow narration (commit / rebase / stash / handoff recaps) | 17 |
| Session summary duplicating an adjacent typed row | 10 |
| Assistant-tooling bookkeeping (skill registry, agent ops, editor config) | 7 |
| One-run verification results | 6 |
| Superseded rows (each with a quoted contradiction) | 5 |
| Code-explanation Q&A describing code still in the repo | 4 |

## Retitle before you delete

Blank and generic titles hurt retrieval more than surplus rows do. In the run
above, 30 rows held real content — tax-regime research, an export-risk
analysis, an app-review rejection — under an empty title, reachable only by
full-text luck. That was the single biggest search-quality win of the session.

```bash
python3 run.py assets/retitle-candidates.sql --project {PROJECT}
# write id<TAB>title lines into titles.tsv, then:
python3 retitle.py --project {PROJECT} --map titles.tsv            # dry run
python3 retitle.py --project {PROJECT} --map titles.tsv --write --backup {BACKUP}

# blank titles are the default target; add --allow-generic to also replace
# signal-free titles like "Session summary" and "sdd/<change>/<phase>"
python3 retitle.py --project {PROJECT} --map titles.tsv --allow-generic \
  --write --backup {BACKUP}
```

`retitle.py` only fires on rows that are still retitleable (blank by default,
plus generic titles under `--allow-generic`), active and in-project, so it is
idempotent and never clobbers a hand-written title.

## When to Use

- User says "prune engram", "clean up memories", "too much noise", "memory cleanup"
- `mem_search` returns irrelevant results consistently
- Multiple project keys exist for the same codebase
- After a major milestone when the user names shipped SDD changes to archive
- Observation count exceeds ~200 for a single project (audit; do not hit 200 by wiping signal)

Skip projects with < 100 active observations unless the user asks anyway.

## Hard rules

1. Backup before every write.
2. Audit before proposing deletes.
3. **Candidate query ≠ delete list.** Show IDs, wait for approval.
4. Never bulk-delete `session_summary` by age. Extract unique Discoveries / SHAs / Next Steps first.
5. Keep `follow-up/*`, `pinned = 1`, and `review_after IS NOT NULL`.
6. Soft-delete only (`deleted_at`). Hard-delete only if the user asks after verify.
7. `sqlite3` CLI is often missing. Use `run.py` (Python stdlib).
8. Run `validate-ids.py` on the final list before any write. It catches the
   real-world failure: a reconciliation naming one id as both a keeper and a
   drop (an analysis pass proposed deleting row 482 while also citing 482 as
   the row that supersedes 481).
9. Delegate the two analysis passes to read-only sub-agents pointed at the
   **backup copy**, never the live DB. That makes them mechanically unable to
   write. Briefs are in `briefs/`.
10. Sub-agents disagree. Reconcile rather than trusting either: one pass found
    14 "duplicates" that were all adjacent-id artifacts; the other found zero
    duplicates but was blind to containment. Both were partly right.

Keep-guards baked into `run.py --soft-delete-ids` and TIER A queries:

```sql
AND pinned = 0
AND IFNULL(topic_key, '') NOT LIKE 'follow-up/%'
AND review_after IS NULL
```

## Tool

Skill dir: parent of this file.

```bash
python3 run.py assets/audit.sql --project {PROJECT}
python3 run.py assets/noise-candidates.sql --project {PROJECT}
python3 run.py assets/verify.sql --project {PROJECT}
```

Writes:

```bash
cp ~/.engram/engram.db ~/.engram/engram.db.backup-$(date +%Y%m%d-%H%M%S)
python3 run.py --soft-delete-ids 12,34,56 --project {PROJECT} \
  --write --backup ~/.engram/engram.db.backup-YYYYMMDD-HHMMSS
```

`--write` without an existing `--backup` file is refused. FTS triggers on `observations` keep the search index in sync on UPDATE/DELETE.

## Step 0: Backup

```bash
cp ~/.engram/engram.db ~/.engram/engram.db.backup-$(date +%Y%m%d-%H%M%S)
ls -la ~/.engram/engram.db ~/.engram/engram.db.backup-*
```

Non-negotiable before `--write`.

## Step 1: Audit

Run `assets/audit.sql`. Record: active count, type mix, session_summary with vs without Discoveries, follow-up count, pinned/review_after/passive, SDD change names, sibling project keys.

If `< 100` active, stop unless the user still wants a pass.

## Step 2: Classify

### Default KEEP (do not "clean" these)

| Pattern | Why |
|---------|-----|
| `topic_key LIKE 'follow-up/%'` | Pending work source of truth |
| `pinned = 1` or `review_after` set | User/lifecycle hold |
| `preference`, `pattern`, current `architecture` | Conventions still in force |
| `config` for project key, sync, skill registry, this prune skill | Tooling that must survive cleanup |
| `discovery` titles `Found` / `Verified` / `Audited` / … | Lasting findings, not one-shot logs |
| `bugfix` whose lesson still applies (crashes, root cause) | Age does not stale a live bug class |
| `session_summary` with Discoveries not saved as typed rows | Only copy of the finding |
| `passive` unique rows (e.g. UI prefs) | Dedupe extras only |
| Early `decision`s (first 14 days) | Often product boundary / PRD, not "Starting X screen" |
| SDD artifacts for changes the user did **not** name as shipped | `sdd/%/completed` is often **0** even after apply |

### TIER A candidates (review IDs, then soft-delete)

| Pattern | Notes |
|---------|-------|
| Title `[DELETED]` / `[INVALIDATED]` | Already marked dead |
| `expires_at < now` | Row was meant to expire |
| Empty title **and** `length(content) < 40` | Accidental saves. Empty title with real content → retitle, don't delete |
| Duplicate `session_summary` with identical content | Keep newest id |
| Extra `passive` rows sharing a title | Keep newest id |
| SDD **process-only** summaries with **narrow** Goal phrases | `Create the SDD task breakdown`, `Write the sdd-spec artifact`, … — **not** `%sdd-verify%` |
| `decision` titles `Starting` / `Committed` / `Implementing` | Confirm they are not real decisions |
| SDD topic keys the **user listed** as shipped | Explicit list only |
| Workflow narration: "committed X", "opened PR #N", "rebased", "stash", handoff recaps | Highest-volume bucket in practice; git already records it |
| `session_summary` beside an adjacent typed row stating the same fact | Run `containment.py --project {PROJECT}`; keep the typed row |
| One-run verification results ("TypeScript and targeted tests passed") | No finding about *why* → nothing to retrieve later |
| Assistant-tooling bookkeeping (skill registry, sub-agent ops, editor config) | About the tooling, not the project |
| Q&A summaries ("Explain X") describing code still in the repo | Re-readable on demand; a non-obvious *rationale* is a KEEP |

### Known false positives (v1.0 called these "safe")

- `session_summary` older than 30 days — most still contain Discoveries (release hardening, Screen Time, production-readiness).
- `Explain` / `Clarify` / `Answer whether` LIKE — matches "Clarify and **fix**…".
- `%sdd-verify%` — matches product verify/review sessions.
- Discovery title prefixes — those **are** the signal.
- Bugfix older than 60 days — includes current crash lessons.
- Title contains `Engram` — hits canonical project key, sync model, retrieval preference.

### Decision tree

```
pinned or review_after set?                         → KEEP
follow-up/* ?                                       → KEEP
preference / pattern / current architecture?        → KEEP
discovery/bugfix lesson still applies?              → KEEP
session_summary with unextracted Discoveries/SHAs?  → EXTRACT, then maybe delete
user-named shipped SDD topic_key?                   → candidate
SDD process-only Goal (narrow phrases)?             → candidate
tombstone / expired / thin-empty-title / exact dup? → candidate
empty title with real content?                      → RETITLE, keep
Starting/Committed/Implementing decision?           → review, default KEEP if unsure
else                                                → KEEP
```

### Extract before deleting a session summary

1. Commit SHAs not stored elsewhere → `mem_save` typed row first.
2. Discoveries section not already a `discovery` → save it.
3. Next Steps not already `follow-up/*` → save it.

Then delete by **id**, not by age.

### Shipped SDD

A change is shipped only if the user names it, or it has `sdd/{change}/completed`, `sdd/{change}/archive-report`, or `sdd/{change}/archive` **and** the user confirms. `apply-progress` is not enough. Do not DELETE all `sdd/%` except `completed`.

## Step 3: Execute

Never run v1.0 bulk UPDATEs (`type = 'session_summary' AND created_at < datetime('now', '-30 days')`, Q&A LIKE, `%sdd-verify%`).

Validate the reconciled list first — it exits non-zero on any failure:

```bash
python3 validate-ids.py --project {PROJECT} --ids {ids} --keepers {ids-that-must-survive}
```

Pass `--keepers` every id that some pair cites as the surviving side. That is
what catches an id listed as both keeper and drop.

After the user approves IDs:

```bash
python3 run.py --soft-delete-ids {comma,separated,ids} --project {PROJECT} \
  --write --backup {backup-path}
```

`run.py` previews allowed vs keep-guard-blocked IDs, then soft-deletes only the allowed set.

Shipped SDD by explicit topic_key list (still `--write` + backup). Put the SQL in a temp file or pass via a one-off `.sql` — keep-guards are **not** automatic unless you add them:

```sql
UPDATE observations SET deleted_at = datetime('now'), updated_at = datetime('now')
WHERE deleted_at IS NULL AND project = '{PROJECT}'
AND pinned = 0
AND IFNULL(topic_key, '') NOT LIKE 'follow-up/%'
AND review_after IS NULL
AND topic_key IN (
  'sdd/{change}/explore',
  'sdd/{change}/proposal',
  'sdd/{change}/spec',
  'sdd/{change}/design',
  'sdd/{change}/tasks',
  'sdd/{change}/apply-progress',
  'sdd/{change}/verify-report'
);
```

Project-key merge: `assets/migrate.sql` with `--old-key` `--new-key` (new key **lowercase**) and `--write`. There is no `mem_merge_projects` tool — this SQL is the merge.

## Step 4: Verify

Run `assets/verify.sql`. Check:

1. Follow-up count matches pre-prune.
2. Session summaries remain if they still hold unique Discoveries (target is **not** 0).
3. pinned / review_after / passive not wiped.
4. Spot-check a few kept rows.
5. `< 200` is an aspiration for search quality, not a quota.

Then `mem_search` for `follow-up` and one known discovery title.

## Step 5: Hard delete (optional, user-asked)

Soft-deleted rows stay out of FTS but still occupy disk and sync exports. Only after verify + user confirm:

```sql
DELETE FROM observations WHERE deleted_at IS NOT NULL AND project = '{PROJECT}';
VACUUM;
```

Run via `python3 run.py {file} --project {PROJECT} --write --backup {backup-path}`. Irreversible except the backup. A past prune hard-deleted 728→480; do not repeat that by default.

If syncing across machines, re-export after hard delete:

```bash
rm -rf .engram/chunks/ .engram/manifest.json
engram sync --project {PROJECT}
```

## Step 6: Record

```
mem_save(
  title: "Engram prune: {before} → {after} observations",
  type: "config",
  project: "{PROJECT}",
  topic_key: "engram/prune-log",
  content: "**What**: Soft-deleted {n} ids ({summary}). **Why**: {reason}. **Learned**: {false positives avoided}"
)
```

## Assets

| File | Purpose |
|------|---------|
| `run.py` | Read-only runner; `--write` + `--backup` for mutations |
| `validate-ids.py` | Pre-write check on a candidate list; non-zero exit on failure |
| `retitle.py` | Guarded, idempotent blank-title fixes from an `id<TAB>title` TSV |
| `briefs/summary-triage.md` | Delegation brief: row-by-row session-summary triage |
| `briefs/clustering.md` | Delegation brief: full-corpus similarity (low yield, run once) |
| `containment.py` | The high-yield duplicate class — a typed row plus the session summary that restates it |
| `assets/retitle-candidates.sql` | Blank and generic titles worth naming |
| `assets/audit.sql` | Diagnosis |
| `assets/noise-candidates.sql` | COUNT buckets + TIER A/B/C review lists |
| `assets/verify.sql` | Retention health check |
| `assets/migrate.sql` | Project key merge (preview SELECT, then UPDATE) |

## Project key casing

`engram sync` lowercases project names. Store lowercase keys. After migrate, nuke chunks and full re-export — delta export will not pick up renamed rows.

## Anti-patterns

| Don't | Do |
|-------|----|
| Bulk UPDATE from a candidate WHERE | Delete approved IDs via `run.py --soft-delete-ids` |
| Trust v1.0 "safe to delete" | Treat those heuristics as TIER B/C |
| `mem_update` in a loop | Direct SQLite |
| Delete without backup | Step 0 |
| Delete follow-ups / pinned / review_after | Keep-guards |
| Hard-delete as the first write | Soft-delete, verify, then maybe hard-delete |
| `%sdd-verify%` or `Clarify %` LIKE | Narrow Goal phrases; read the Goal |
| Wipe all session summaries to hit 0 | Extract, then id-delete leftovers |
| Assume `sdd/%/completed` marks shipped work | Ask the user; completed is often 0 |
| Delete Engram-titled keep-class rows | Project key, sync, retrieval prefs stay |
| Use `sqlite3` CLI blindly | `python3 run.py` (CLI often absent) |
| Estimate the cut from row counts | Read content; expect ~4%, not ~40% |
| Expect similarity clustering to carry the run | Run it once to prove the negative; use containment for real dupes |
| Delete a blank-titled row | Retitle it — bigger retrieval win than the delete |
| Point a sub-agent at the live DB | Point it at the backup copy; it then cannot write |
| Trust one analysis pass | Reconcile two, then `validate-ids.py` |
