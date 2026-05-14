-- =============================================================
-- Engram Audit Query
-- Run this FIRST to understand what you're working with.
-- Replace {PROJECT} with the target project name.
-- =============================================================

-- 1. Active observations per project (find split keys)
SELECT project, COUNT(*) as total
FROM observations WHERE deleted_at IS NULL
GROUP BY project ORDER BY total DESC;

-- 2. Type breakdown for target project
SELECT type, COUNT(*) as cnt
FROM observations WHERE deleted_at IS NULL AND project = '{PROJECT}'
GROUP BY type ORDER BY cnt DESC;

-- 3. SDD artifacts vs real content
SELECT
  CASE
    WHEN topic_key LIKE 'sdd/%' THEN 'sdd-artifact'
    WHEN topic_key LIKE 'follow-up/%' THEN 'follow-up'
    WHEN topic_key IS NOT NULL THEN 'other-topic'
    ELSE 'no-topic'
  END as category,
  COUNT(*) as cnt
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}'
GROUP BY category ORDER BY cnt DESC;

-- 4. Age distribution
SELECT
  CASE
    WHEN created_at > datetime('now', '-7 days') THEN 'last-7-days'
    WHEN created_at > datetime('now', '-30 days') THEN '8-30-days'
    WHEN created_at > datetime('now', '-60 days') THEN '31-60-days'
    ELSE 'older-than-60-days'
  END as age,
  COUNT(*) as cnt
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}'
GROUP BY age ORDER BY cnt DESC;

-- 5. Session summaries count (biggest noise source)
SELECT COUNT(*) || ' session summaries (candidate for bulk delete)'
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'session_summary';

-- 6. Shipped SDD changes (have completed markers)
SELECT DISTINCT
  SUBSTR(topic_key, 5, INSTR(SUBSTR(topic_key, 5), '/') - 1) as change_name
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}'
AND topic_key LIKE 'sdd/%/completed';

-- 7. Active SDD changes (have artifacts but NO completed marker)
SELECT DISTINCT
  SUBSTR(topic_key, 5, INSTR(SUBSTR(topic_key, 5), '/') - 1) as change_name
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}'
AND topic_key LIKE 'sdd/%'
AND SUBSTR(topic_key, 5, INSTR(SUBSTR(topic_key, 5), '/') - 1) NOT IN (
  SELECT DISTINCT SUBSTR(topic_key, 5, INSTR(SUBSTR(topic_key, 5), '/') - 1)
  FROM observations
  WHERE deleted_at IS NULL AND topic_key LIKE 'sdd/%/completed'
);

-- 8. Duplicate titles (same title saved multiple times)
SELECT title, COUNT(*) as dupes
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}'
GROUP BY title HAVING dupes > 1
ORDER BY dupes DESC LIMIT 20;

-- 9. Follow-up items (NEVER delete these)
SELECT id, topic_key, substr(title, 1, 70)
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND topic_key LIKE 'follow-up/%'
ORDER BY created_at;

-- 10. Project keys that might need merging
SELECT project, COUNT(*) as cnt
FROM observations
WHERE deleted_at IS NULL
AND project LIKE '%{PROJECT_PARTIAL}%'
GROUP BY project ORDER BY cnt DESC;
