# Brief — full-corpus duplicate clustering (role: explore, read-only)

Substitute {PROJECT}, {COUNT}, {BACKUP}.

NOTE ON EXPECTED YIELD: on a real 1,230-row corpus this pass returned ZERO
approved drops. Its value is proving the negative — it stops you cutting on a
"the memory must be full of duplicates" hunch. Run it, but do not pad the
result. The containment pass (assets/containment-pairs.sql) is where the real
duplicate class lives.

---

GOAL
Full-corpus near-duplicate clustering. Analysis only — modify nothing.

DATABASE (read-only, disposable backup copy)
{BACKUP}
  sqlite3.connect('file:{BACKUP}?mode=ro', uri=True)
The `sqlite3` CLI is NOT installed — python3 only.
NEVER open ~/.engram/engram.db (the live DB, no .backup suffix).

SCOPE
Table `observations`, WHERE project='{PROJECT}' AND deleted_at IS NULL.
Exactly {COUNT} rows. Inspect the schema first.

CONTEXT
Months of an AI assistant's auto-saved memories, written across many sessions
with no dedup, so the SAME fact may be re-saved in different words weeks apart.
N copies of one fact is noise; the memory exists for retrieval of durable facts.

METHOD
1. Normalize per row: lowercase, strip markdown, strip boilerplate headers
   ("## Goal", "## Instructions", "## Discoveries", "## Accomplished",
   "## Next Steps", "**What**", "**Why**", "Relevant Files", "Session:",
   "Project:", "Scope:"), collapse whitespace, drop stopwords.
2. Compute pairwise similarity across ALL rows — ~750k pairs is tractable.
   TF-IDF cosine over unigrams+bigrams (scikit-learn may not be installed —
   check, hand-roll with collections.Counter and math if absent). Add a
   Jaccard over 5-word shingles as a second signal.
3. Report clusters at cosine >= 0.85, >= 0.75, >= 0.65 so the precision/size
   tradeoff is visible.
4. Report SEPARATELY the clusters whose members are >14 days apart AND >50 ids
   apart. Adjacent-id pairs are same-session artifacts and belong to the
   containment pass, not here.
5. For every cluster you recommend acting on, READ ALL MEMBERS IN FULL, pick the
   single KEEP (most complete / most recent), quote the shared fact.
6. Calibrate: read >=25 random high-similarity pairs in full, report the
   false-positive rate — pairs where the later row adds a material decision, a
   corrected preference, or a distinct finding. Those are KEEPS.

HARD KEEP-GUARDS — never propose; report how many excluded:
  pinned = 1  |  review_after IS NOT NULL  |  topic_key LIKE 'follow-up/%'
Never propose deleting the LAST copy of a fact — every cluster retains a member.

RETURN SHAPE
1. Cluster count and droppable rows at each threshold.
2. Table: cluster | keep id | drop ids | days spanned | shared fact.
3. Dedicated table for the far-apart clusters from step 4.
4. Calibration: pairs read, false-positive rate, 3 quoted REJECTED pairs.
5. Paste-ready drop list at your recommended threshold + remaining count.
6. Anything you could not determine.

Write the full report to /tmp/engram-dupes-report.md and print 1-5.
