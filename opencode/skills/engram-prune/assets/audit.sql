-- =============================================================
-- Engram Audit Query
-- Run FIRST. Read the numbers before proposing any deletes.
-- Replace {PROJECT} with the target project name (lowercase).
-- =============================================================

-- 1. Active observations per project (find split keys)
SELECT project, COUNT(*) as total
FROM observations WHERE deleted_at IS NULL
GROUP BY project ORDER BY total DESC;

-- 2. Type breakdown for target project
SELECT type, COUNT(*) as cnt
FROM observations WHERE deleted_at IS NULL AND project = '{PROJECT}'
GROUP BY type ORDER BY cnt DESC;

-- 3. Topic categories
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

-- 4. Age distribution (age is diagnostic, not a delete signal)
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

-- 5. Session summaries: age vs unique content
SELECT
  CASE
    WHEN created_at >= datetime('now', '-30 days') THEN 'last-30'
    ELSE 'older-30'
  END as age,
  SUM(CASE WHEN content LIKE '%Discover%' THEN 1 ELSE 0 END) as with_discoveries,
  SUM(CASE WHEN content LIKE '%Discover%' THEN 0 ELSE 1 END) as without_discoveries,
  COUNT(*) as total
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'session_summary'
GROUP BY age;

-- 6. Retention / lifecycle fields
SELECT
  SUM(CASE WHEN pinned = 1 THEN 1 ELSE 0 END) as pinned,
  SUM(CASE WHEN review_after IS NOT NULL THEN 1 ELSE 0 END) as review_after,
  SUM(CASE WHEN expires_at IS NOT NULL THEN 1 ELSE 0 END) as has_expires,
  SUM(CASE WHEN expires_at IS NOT NULL AND expires_at < datetime('now') THEN 1 ELSE 0 END) as expired,
  SUM(CASE WHEN type = 'passive' THEN 1 ELSE 0 END) as passive
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}';

-- 7. Already soft-deleted (recoverable until hard-delete)
SELECT COUNT(*) as already_soft_deleted
FROM observations
WHERE deleted_at IS NOT NULL AND project = '{PROJECT}';

-- 8. Shipped-SDD hints (completed OR archive-report). Not sufficient to delete.
SELECT source, change_name
FROM (
  SELECT 'completed' as source,
    SUBSTR(topic_key, 5, INSTR(SUBSTR(topic_key, 5), '/') - 1) as change_name
  FROM observations
  WHERE deleted_at IS NULL AND project = '{PROJECT}' AND topic_key LIKE 'sdd/%/completed'
  UNION
  SELECT 'archive-report',
    SUBSTR(topic_key, 5, INSTR(SUBSTR(topic_key, 5), '/') - 1)
  FROM observations
  WHERE deleted_at IS NULL AND project = '{PROJECT}' AND topic_key LIKE 'sdd/%/archive-report'
  UNION
  SELECT 'archive',
    SUBSTR(topic_key, 5, INSTR(SUBSTR(topic_key, 5), '/') - 1)
  FROM observations
  WHERE deleted_at IS NULL AND project = '{PROJECT}'
  AND topic_key LIKE 'sdd/%/archive' AND topic_key NOT LIKE 'sdd/%/archive-%'
)
ORDER BY change_name, source;

-- 9. All SDD change names present (user must mark which shipped)
SELECT DISTINCT
  SUBSTR(topic_key, 5, INSTR(SUBSTR(topic_key, 5) || '/', '/') - 1) as change_name,
  COUNT(*) as cnt
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND topic_key LIKE 'sdd/%'
GROUP BY change_name
ORDER BY change_name;

-- 10. Duplicate titles
SELECT title, COUNT(*) as dupes
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}'
GROUP BY title HAVING dupes > 1
ORDER BY dupes DESC LIMIT 20;

-- 11. Follow-up items (NEVER delete)
SELECT id, type, topic_key, substr(title, 1, 70)
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND topic_key LIKE 'follow-up/%'
ORDER BY created_at;

-- 12. Sibling project keys that might need merging
SELECT project, COUNT(*) as cnt
FROM observations
WHERE deleted_at IS NULL
AND project LIKE '%{PROJECT_PARTIAL}%'
GROUP BY project ORDER BY cnt DESC;
