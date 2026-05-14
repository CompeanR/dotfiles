-- =============================================================
-- Engram Noise Candidate Queries
-- These identify LIKELY noise. Review output before deleting.
-- Replace {PROJECT} with the target project name.
-- =============================================================

-- 1a. Session summaries OLDER than 30 days (safe to delete)
SELECT id, substr(title, 1, 70), created_at
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'session_summary'
AND created_at < datetime('now', '-30 days')
ORDER BY created_at;

-- 1b. Session summaries from LAST 30 days (REVIEW before deleting)
--     Check for: commit SHAs, unique discoveries, Next Steps not captured as follow-ups
SELECT id, substr(title, 1, 70), created_at
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'session_summary'
AND created_at >= datetime('now', '-30 days')
ORDER BY created_at;

-- 1c. SDD sub-agent session summaries (safe to delete regardless of age)
--     These are process logs — the actual SDD artifacts hold the real content
SELECT id, substr(content, 8, 90), created_at
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'session_summary'
AND (
  content LIKE '%SDD task breakdown%' OR
  content LIKE '%sdd-spec artifact%' OR
  content LIKE '%sdd-design%artifact%' OR
  content LIKE '%sdd-explore%artifact%' OR
  content LIKE '%SDD proposal%artifact%' OR
  content LIKE '%sdd-verify%' OR
  content LIKE '%sdd-init%' OR
  content LIKE '%SDD onboarding%walkthrough%'
)
ORDER BY created_at;

-- 1d. Micro Q&A session summaries (safe to delete regardless of age)
SELECT id, substr(content, 8, 90), created_at
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'session_summary'
AND (
  content LIKE '%Explain %' OR
  content LIKE '%Clarify %' OR
  content LIKE '%Answer whether%' OR
  content LIKE '%Answer if%'
)
AND content NOT LIKE '%Implement%'
AND content NOT LIKE '%commit%'
ORDER BY created_at;

-- 2. SDD planning artifacts for shipped changes
--    (explore, proposal, spec, design, tasks for changes with 'completed' markers)
SELECT o.id, o.topic_key, substr(o.title, 1, 70)
FROM observations o
WHERE o.deleted_at IS NULL AND o.project = '{PROJECT}'
AND o.topic_key LIKE 'sdd/%'
AND o.topic_key NOT LIKE 'sdd/%/completed'
AND SUBSTR(o.topic_key, 5, INSTR(SUBSTR(o.topic_key, 5), '/') - 1) IN (
  SELECT DISTINCT SUBSTR(topic_key, 5, INSTR(SUBSTR(topic_key, 5), '/') - 1)
  FROM observations
  WHERE deleted_at IS NULL AND topic_key LIKE 'sdd/%/completed'
)
ORDER BY o.topic_key;

-- 3. Early micro-decisions (UI tweaks from the first 2 weeks of the project)
--    Review before deleting — some early decisions may still be relevant
SELECT id, substr(title, 1, 70), created_at
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'decision'
AND created_at < datetime((SELECT MIN(created_at) FROM observations WHERE project = '{PROJECT}'), '+14 days')
ORDER BY created_at;

-- 4. One-shot discoveries that sound like verifications
SELECT id, substr(title, 1, 70), created_at
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'discovery'
AND (
  title LIKE 'Verified %' OR
  title LIKE 'Found %' OR
  title LIKE 'Audited %' OR
  title LIKE 'Recorded %' OR
  title LIKE 'Diagnosed %' OR
  title LIKE 'Detected %'
)
ORDER BY created_at;

-- 5. Bugfixes older than 60 days (likely for rewritten code)
SELECT id, substr(title, 1, 70), created_at
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'bugfix'
AND created_at < datetime('now', '-60 days')
ORDER BY created_at;

-- 6. Meta/tooling observations (about engram itself, not the project)
SELECT id, substr(title, 1, 70), created_at
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}'
AND (
  title LIKE '%[DELETED]%' OR
  title LIKE '%[INVALIDATED]%' OR
  title LIKE '%Engram%' OR
  title LIKE '%engram%' OR
  title LIKE '%memory migration%' OR
  title LIKE '%project key%' OR
  title LIKE '%skill registry%'
)
ORDER BY created_at;

-- 7. Entries with no topic_key (less structured, more likely noise)
SELECT type, COUNT(*) as cnt
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND topic_key IS NULL
GROUP BY type ORDER BY cnt DESC;

-- 8. Commit confirmation patterns (not decisions, just "I committed X")
SELECT id, substr(title, 1, 70), created_at
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'decision'
AND (
  title LIKE 'Committed %' OR
  title LIKE 'Starting %' OR
  title LIKE 'Implementing %'
)
ORDER BY created_at;
