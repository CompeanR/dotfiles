-- =============================================================
-- Engram Noise Candidate Queries
-- REVIEW LISTS. Never feed these WHERE clauses into a bulk UPDATE.
-- Replace {PROJECT} with the target project name (lowercase).
-- Keep-guards (pinned / follow-up/* / review_after) are applied
-- on TIER A only so TIER C can still show sacred rows.
-- =============================================================

-- 0. Dry-run COUNT buckets (run this even if you skip the detail lists)
SELECT 'ss_over_30d' as bucket, COUNT(*) as cnt FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'session_summary'
AND created_at < datetime('now', '-30 days')
UNION ALL
SELECT 'ss_over_30d_with_discoveries', COUNT(*) FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'session_summary'
AND created_at < datetime('now', '-30 days') AND content LIKE '%Discover%'
UNION ALL
SELECT 'ss_last_30d', COUNT(*) FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'session_summary'
AND created_at >= datetime('now', '-30 days')
UNION ALL
SELECT 'ss_sdd_process_narrow', COUNT(*) FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'session_summary'
AND (
  content LIKE '%Create the SDD task breakdown%' OR
  content LIKE '%Write the sdd-spec artifact%' OR
  content LIKE '%Write the sdd-design artifact%' OR
  content LIKE '%Write the sdd-explore artifact%' OR
  content LIKE '%Execute the SDD design phase%' OR
  content LIKE '%SDD onboarding walkthrough%' OR
  content LIKE '%Initialize Spec-Driven Development%'
)
UNION ALL
SELECT 'ss_qa_narrow', COUNT(*) FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'session_summary'
AND (content LIKE '%## Goal%Explain %' OR content LIKE '%## Goal%Answer whether%')
AND content NOT LIKE '%fix%' AND content NOT LIKE '%Fix%'
AND content NOT LIKE '%Implement%' AND content NOT LIKE '%commit%'
UNION ALL
SELECT 'sdd_completed_marker_artifacts', COUNT(*) FROM observations o
WHERE o.deleted_at IS NULL AND o.project = '{PROJECT}'
AND o.topic_key LIKE 'sdd/%' AND o.topic_key NOT LIKE 'sdd/%/completed'
AND SUBSTR(o.topic_key, 5, INSTR(SUBSTR(o.topic_key, 5), '/') - 1) IN (
  SELECT DISTINCT SUBSTR(topic_key, 5, INSTR(SUBSTR(topic_key, 5), '/') - 1)
  FROM observations
  WHERE deleted_at IS NULL AND project = '{PROJECT}' AND topic_key LIKE 'sdd/%/completed'
)
UNION ALL
SELECT 'sdd_all_artifacts', COUNT(*) FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND topic_key LIKE 'sdd/%'
UNION ALL
SELECT 'discovery_title_prefixes_KEEP', COUNT(*) FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'discovery'
AND (title LIKE 'Verified %' OR title LIKE 'Found %' OR title LIKE 'Audited %'
  OR title LIKE 'Recorded %' OR title LIKE 'Diagnosed %' OR title LIKE 'Detected %')
UNION ALL
SELECT 'bugfix_over_60d_KEEP', COUNT(*) FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'bugfix'
AND created_at < datetime('now', '-60 days')
UNION ALL
SELECT 'title_engram_keepclass', COUNT(*) FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}'
AND (title LIKE '%Engram%' OR title LIKE '%engram%' OR title LIKE '%project key%'
  OR title LIKE '%skill registry%' OR title LIKE '%memory migration%')
AND title NOT LIKE '%[DELETED]%' AND title NOT LIKE '%[INVALIDATED]%'
UNION ALL
SELECT 'tombstones', COUNT(*) FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}'
AND (title LIKE '%[DELETED]%' OR title LIKE '%[INVALIDATED]%')
UNION ALL
SELECT 'expired', COUNT(*) FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}'
AND expires_at IS NOT NULL AND expires_at < datetime('now')
UNION ALL
SELECT 'passive_dup_titles', COUNT(*) FROM (
  SELECT title FROM observations
  WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'passive'
  GROUP BY title HAVING COUNT(*) > 1
)
UNION ALL
SELECT 'empty_title_thin_content', COUNT(*) FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}'
AND (title IS NULL OR title = '') AND length(trim(content)) < 40
UNION ALL
SELECT 'empty_title_has_content_KEEP', COUNT(*) FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}'
AND (title IS NULL OR title = '') AND length(trim(content)) >= 40
UNION ALL
SELECT 'follow_up_SACRED', COUNT(*) FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND topic_key LIKE 'follow-up/%';

-- =============================================================
-- TIER A — likely true noise. Still review IDs before delete.
-- =============================================================

-- A1. Tombstones already marked dead
SELECT id, type, topic_key, substr(title, 1, 70), created_at
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}'
AND (title LIKE '%[DELETED]%' OR title LIKE '%[INVALIDATED]%')
AND pinned = 0
AND IFNULL(topic_key, '') NOT LIKE 'follow-up/%'
AND review_after IS NULL
ORDER BY created_at;

-- A2. Expired rows (expires_at was set and is past)
SELECT id, type, topic_key, substr(title, 1, 70), expires_at
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}'
AND expires_at IS NOT NULL AND expires_at < datetime('now')
AND pinned = 0
AND IFNULL(topic_key, '') NOT LIKE 'follow-up/%'
AND review_after IS NULL
ORDER BY expires_at;

-- A3. Empty title AND thin content (accidental saves). Real content → retitle, don't delete.
SELECT id, type, topic_key, created_at, substr(content, 1, 80)
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}'
AND (title IS NULL OR title = '')
AND length(trim(content)) < 40
AND pinned = 0
AND IFNULL(topic_key, '') NOT LIKE 'follow-up/%'
AND review_after IS NULL
ORDER BY created_at;

-- A4. Duplicate session_summary titles with identical content (keep newest)
SELECT a.id as drop_id, b.id as keep_id, substr(a.title, 1, 50), a.created_at
FROM observations a
JOIN observations b
  ON a.project = b.project AND a.type = b.type AND a.title = b.title
 AND a.content = b.content AND a.id < b.id
WHERE a.deleted_at IS NULL AND b.deleted_at IS NULL
AND a.project = '{PROJECT}' AND a.type = 'session_summary'
AND a.pinned = 0 AND b.pinned = 0
AND IFNULL(a.topic_key, '') NOT LIKE 'follow-up/%'
AND a.review_after IS NULL
ORDER BY a.title, a.id;

-- A5. Extra passive rows sharing a title (keep newest id)
SELECT a.id as drop_id, b.id as keep_id, substr(a.title, 1, 70)
FROM observations a
JOIN observations b
  ON a.project = b.project AND a.type = b.type AND a.title = b.title AND a.id < b.id
WHERE a.deleted_at IS NULL AND b.deleted_at IS NULL
AND a.project = '{PROJECT}' AND a.type = 'passive'
AND a.pinned = 0 AND a.review_after IS NULL
AND IFNULL(a.topic_key, '') NOT LIKE 'follow-up/%'
AND IFNULL(b.topic_key, '') NOT LIKE 'follow-up/%'
ORDER BY a.title, a.id;

-- A6. SDD process-only session summaries (narrow Goal phrases, not '%sdd-verify%')
SELECT id, created_at, substr(content, 1, 120)
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'session_summary'
AND (
  content LIKE '%Create the SDD task breakdown%' OR
  content LIKE '%Write the sdd-spec artifact%' OR
  content LIKE '%Write the sdd-design artifact%' OR
  content LIKE '%Write the sdd-explore artifact%' OR
  content LIKE '%Execute the SDD design phase%' OR
  content LIKE '%SDD onboarding walkthrough%' OR
  content LIKE '%Initialize Spec-Driven Development%'
)
AND pinned = 0
AND IFNULL(topic_key, '') NOT LIKE 'follow-up/%'
AND review_after IS NULL
ORDER BY created_at;

-- A7. Commit-confirmation "decisions" (Starting/Committed/Implementing)
SELECT id, substr(title, 1, 70), created_at
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'decision'
AND (title LIKE 'Committed %' OR title LIKE 'Starting %' OR title LIKE 'Implementing %')
AND pinned = 0
AND IFNULL(topic_key, '') NOT LIKE 'follow-up/%'
AND review_after IS NULL
ORDER BY created_at;

-- =============================================================
-- TIER B — high false-positive. Default KEEP. Extract, don't wipe.
-- =============================================================

-- B1. Old session summaries sample (age ≠ noise; COUNT bucket has the size)
SELECT id, created_at, substr(content, 1, 140)
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'session_summary'
AND created_at < datetime('now', '-30 days')
ORDER BY created_at DESC
LIMIT 12;

-- B2. Recent session summaries sample (extract unique SHAs / Discoveries / Next Steps)
SELECT id, created_at, substr(content, 1, 140)
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'session_summary'
AND created_at >= datetime('now', '-30 days')
ORDER BY created_at DESC
LIMIT 12;

-- B3. Explanation-only Q&A sample (still false-positives if Goal is "Clarify and fix")
SELECT id, created_at, substr(content, 1, 140)
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'session_summary'
AND (content LIKE '%## Goal%Explain %' OR content LIKE '%## Goal%Answer whether%')
AND content NOT LIKE '%fix%' AND content NOT LIKE '%Fix%'
AND content NOT LIKE '%Implement%' AND content NOT LIKE '%commit%'
ORDER BY created_at
LIMIT 12;

-- B4. SDD artifacts with a completed marker (marker is often missing — do not generalize)
SELECT o.id, o.topic_key, substr(o.title, 1, 70)
FROM observations o
WHERE o.deleted_at IS NULL AND o.project = '{PROJECT}'
AND o.topic_key LIKE 'sdd/%' AND o.topic_key NOT LIKE 'sdd/%/completed'
AND SUBSTR(o.topic_key, 5, INSTR(SUBSTR(o.topic_key, 5), '/') - 1) IN (
  SELECT DISTINCT SUBSTR(topic_key, 5, INSTR(SUBSTR(topic_key, 5), '/') - 1)
  FROM observations
  WHERE deleted_at IS NULL AND project = '{PROJECT}' AND topic_key LIKE 'sdd/%/completed'
)
ORDER BY o.topic_key;

-- B5. All sdd/* topic keys (delete only names the user lists as shipped)
SELECT id, topic_key, type, substr(title, 1, 70)
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND topic_key LIKE 'sdd/%'
ORDER BY topic_key;

-- B6. First-14-day decisions (often foundational, not UI tweaks)
SELECT id, substr(title, 1, 70), created_at
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'decision'
AND created_at < datetime((SELECT MIN(created_at) FROM observations WHERE project = '{PROJECT}'), '+14 days')
ORDER BY created_at;

-- B7. Empty title with real content (retitle candidates, default KEEP)
SELECT id, type, created_at, substr(content, 1, 100)
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}'
AND (title IS NULL OR title = '')
AND length(trim(content)) >= 40
ORDER BY created_at DESC
LIMIT 12;

-- =============================================================
-- TIER C — default KEEP. Shown so you do not "clean" them.
-- =============================================================

-- C1. Follow-ups (sacred)
SELECT id, type, topic_key, substr(title, 1, 70)
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND topic_key LIKE 'follow-up/%'
ORDER BY created_at;

-- C2. Discovery title-prefix sample (these ARE the findings — COUNT bucket has size)
SELECT id, substr(title, 1, 80), created_at
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'discovery'
AND (title LIKE 'Verified %' OR title LIKE 'Found %' OR title LIKE 'Audited %'
  OR title LIKE 'Recorded %' OR title LIKE 'Diagnosed %' OR title LIKE 'Detected %')
ORDER BY created_at DESC
LIMIT 12;

-- C3. Bugfix >60d sample (crash lessons often still apply — COUNT bucket has size)
SELECT id, substr(title, 1, 80), created_at
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'bugfix'
AND created_at < datetime('now', '-60 days')
ORDER BY created_at DESC
LIMIT 12;

-- C4. Engram/tooling keep-class (project key, sync, retrieval, this skill)
SELECT id, type, topic_key, substr(title, 1, 80)
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}'
AND (title LIKE '%Engram%' OR title LIKE '%engram%' OR title LIKE '%project key%'
  OR title LIKE '%skill registry%' OR title LIKE '%memory migration%')
AND title NOT LIKE '%[DELETED]%' AND title NOT LIKE '%[INVALIDATED]%'
ORDER BY created_at DESC
LIMIT 20;

-- C5. review_after / pinned sample (do not auto-delete; audit.sql has counts)
SELECT id, type, pinned, review_after, substr(title, 1, 70)
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}'
AND (pinned = 1 OR review_after IS NOT NULL)
ORDER BY review_after
LIMIT 15;

-- C6. Untyped / uncommon types (passive, feature, implementation, …)
SELECT type, COUNT(*) as cnt
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}'
AND type NOT IN (
  'session_summary','decision','discovery','architecture','bugfix',
  'config','preference','pattern'
)
GROUP BY type ORDER BY cnt DESC;

-- C7. No topic_key (unstructured ≠ noise)
SELECT type, COUNT(*) as cnt
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND topic_key IS NULL
GROUP BY type ORDER BY cnt DESC;
