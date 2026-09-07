-- =============================================================
-- Engram Post-Prune Verification
-- Retention policy, not a wipe. Replace {PROJECT} (lowercase).
-- =============================================================

-- 1. Final counts
SELECT 'Active:' as status, COUNT(*) as cnt
FROM observations WHERE deleted_at IS NULL AND project = '{PROJECT}'
UNION ALL
SELECT 'Soft-deleted:', COUNT(*)
FROM observations WHERE deleted_at IS NOT NULL AND project = '{PROJECT}';

-- 2. Type distribution (session_summary may remain; that is OK)
SELECT type,
  COUNT(*) as cnt,
  ROUND(COUNT(*) * 100.0 / MAX((SELECT COUNT(*) FROM observations WHERE deleted_at IS NULL AND project = '{PROJECT}'), 1), 1) || '%' as pct
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}'
GROUP BY type ORDER BY cnt DESC;

-- 3. Follow-ups preserved (must match pre-prune count)
SELECT COUNT(*) as follow_ups_preserved
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND topic_key LIKE 'follow-up/%';

-- 4. Session-summary retention (target: keep last-30d and any with unique Discoveries)
SELECT
  SUM(CASE WHEN created_at >= datetime('now', '-30 days') THEN 1 ELSE 0 END) as last_30d,
  SUM(CASE WHEN created_at < datetime('now', '-30 days') THEN 1 ELSE 0 END) as older_30d,
  SUM(CASE WHEN content LIKE '%Discover%' THEN 1 ELSE 0 END) as with_discoveries,
  COUNT(*) as total_summaries
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND type = 'session_summary';

-- 5. Lifecycle fields still intact
SELECT
  SUM(CASE WHEN pinned = 1 THEN 1 ELSE 0 END) as pinned,
  SUM(CASE WHEN review_after IS NOT NULL THEN 1 ELSE 0 END) as review_after,
  SUM(CASE WHEN type = 'passive' THEN 1 ELSE 0 END) as passive
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}';

-- 6. Sibling project keys that may still need merging
SELECT project, COUNT(*) as cnt
FROM observations
WHERE deleted_at IS NULL AND project != '{PROJECT}'
AND project LIKE '%{PROJECT_PARTIAL}%'
GROUP BY project;

-- 7. Remaining SDD artifacts (should only be active or user-kept)
SELECT topic_key, type, substr(title, 1, 60)
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND topic_key LIKE 'sdd/%'
ORDER BY topic_key;

-- 8. Sample kept entries (spot-check signal, not leftovers)
SELECT id, type, substr(title, 1, 60), created_at
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}'
ORDER BY RANDOM() LIMIT 10;
