-- =============================================================
-- Engram Project Key Migration
-- Merge observations from old key into canonical key.
-- Replace {OLD_KEY} and {NEW_KEY} with actual project names.
--
-- IMPORTANT: {NEW_KEY} must be LOWERCASE.
-- `engram sync` normalizes to lowercase before exporting.
-- If your canonical key is PascalCase, sync will export 0 memories.
-- =============================================================

-- 1. Preview what will be migrated
SELECT COUNT(*) || ' observations to migrate from ' || '{OLD_KEY}' || ' to ' || '{NEW_KEY}'
FROM observations WHERE project = '{OLD_KEY}' AND deleted_at IS NULL;

SELECT COUNT(*) || ' sessions to migrate'
FROM sessions WHERE project = '{OLD_KEY}';

-- 2. Migrate observations
UPDATE observations
SET project = '{NEW_KEY}', updated_at = datetime('now')
WHERE project = '{OLD_KEY}' AND deleted_at IS NULL;

-- 3. Migrate sessions
UPDATE sessions
SET project = '{NEW_KEY}'
WHERE project = '{OLD_KEY}';

-- 4. Migrate user prompts
UPDATE user_prompts
SET project = '{NEW_KEY}'
WHERE project = '{OLD_KEY}';

-- 5. Verify no orphans remain
SELECT 'Remaining under old key:',
  (SELECT COUNT(*) FROM observations WHERE project = '{OLD_KEY}' AND deleted_at IS NULL) || ' observations, ' ||
  (SELECT COUNT(*) FROM sessions WHERE project = '{OLD_KEY}') || ' sessions';
