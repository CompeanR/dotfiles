-- =============================================================
-- Engram Post-Prune Verification
-- Run this AFTER pruning to confirm health.
-- Replace {PROJECT} with the target project name.
-- =============================================================

-- 1. Final counts
SELECT 'Active:' as status, COUNT(*) as cnt
FROM observations WHERE deleted_at IS NULL AND project = '{PROJECT}'
UNION ALL
SELECT 'Deleted:', COUNT(*)
FROM observations WHERE deleted_at IS NOT NULL AND project = '{PROJECT}';

-- 2. Type distribution (should be balanced, no single type > 40%)
SELECT type,
  COUNT(*) as cnt,
  ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM observations WHERE deleted_at IS NULL AND project = '{PROJECT}'), 1) || '%' as pct
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}'
GROUP BY type ORDER BY cnt DESC;

-- 3. Follow-ups preserved (MUST be > 0 if they existed before)
SELECT COUNT(*) || ' follow-up items preserved'
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND topic_key LIKE 'follow-up/%';

-- 4. No session summaries remain (target: 0)
SELECT COUNT(*) || ' session summaries remain (target: 0)'
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'session_summary';

-- 5. No stale project keys remain
SELECT project, COUNT(*) as cnt
FROM observations
WHERE deleted_at IS NULL AND project != '{PROJECT}'
AND project LIKE '%{PROJECT_PARTIAL}%'
GROUP BY project;

-- 6. Active SDD artifacts belong to non-shipped changes only
SELECT topic_key, substr(title, 1, 60)
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND topic_key LIKE 'sdd/%'
ORDER BY topic_key;

-- 7. Sample kept entries (spot check)
SELECT id, type, substr(title, 1, 60), created_at
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}'
ORDER BY RANDOM() LIMIT 10;
