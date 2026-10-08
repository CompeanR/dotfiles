-- =============================================================
-- Retitle candidates — usually a BIGGER search-quality win than
-- any deletion. Rows with real content under a blank or generic
-- title are reachable only by full-text luck.
--
-- NEVER delete these. Retitle them.
-- Replace {PROJECT} with the target project (lowercase).
-- =============================================================

-- 1. Blank titles carrying substantive content
SELECT id, type, created_at, length(content) AS len,
       substr(REPLACE(content, char(10), ' '), 1, 200) AS content_preview
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}'
  AND TRIM(IFNULL(title, '')) = ''
  AND length(content) >= 120
ORDER BY created_at;

-- 2. Generic template titles that carry no retrieval signal
SELECT id, type, created_at, title,
       substr(REPLACE(content, char(10), ' '), 1, 160) AS content_preview
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}'
  AND (
        title LIKE 'Session summary%'
     OR title = 'Session summary'
     OR title LIKE 'sdd/%'
  )
  AND length(content) >= 200
ORDER BY created_at
LIMIT 60;

-- 3. Counters
SELECT 'blank_titles' AS metric, COUNT(*) AS cnt
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND TRIM(IFNULL(title, '')) = ''
UNION ALL
SELECT 'generic_titles', COUNT(*)
FROM observations
WHERE deleted_at IS NULL AND project = '{PROJECT}' AND title LIKE 'Session summary%';
