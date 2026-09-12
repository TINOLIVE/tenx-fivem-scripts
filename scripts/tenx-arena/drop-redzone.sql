-- ============================================================
--  REMOVING THE FREE-FOR-ALL ZONES
-- ============================================================
--
--  Run once, after installing this version.
--
--  The mode is gone from the script. This clears what it left in the
--  database.
--
--  WHAT THIS DELETES
--    · the free-for-all leaderboard — kills, deaths, points, best streaks
--    · the marked zone spawns, which nothing reads any more
--
--  WHAT THIS KEEPS
--    · every arena, boundary and team spawn — matches still use them
--    · everyone's inventory and coin balance
--    · match records, ranked ratings, wall boards, props
--
--  Take a backup first if you are not certain. TRUNCATE and DROP cannot
--  be undone.
-- ============================================================

-- The free-for-all leaderboard.
DROP TABLE IF EXISTS `tenx_arena_rz_stats`;

-- The zone spawns live inside each arena's JSON blob, so they are cleared
-- rather than dropped. Everything else in the blob is left alone.
UPDATE `tenx_arena_zones`
SET `data` = JSON_REMOVE(`data`, '$.rzSpawns')
WHERE JSON_EXTRACT(`data`, '$.rzSpawns') IS NOT NULL;

-- Any wall board still set to the free-for-all leaderboard now points at
-- nothing, so it becomes a PVP board rather than rendering blank.
UPDATE `tenx_arena_boards`
SET `kind` = 'pvp'
WHERE `kind` IN ('redzone', 'rzpvp', 'rotate');


-- ============================================================
--  NOT DELETED ON PURPOSE
-- ============================================================
-- These two are named rz_* but they are the inventory and coin system, which
-- matches, the shop, the cart and wagers all still use. Dropping them would
-- take everyone's belongings and balances with them.
--
--   tenx_arena_rz_inv       what each player is carrying, and their coins
--   tenx_arena_rz_ledger    every coin movement, for answering disputes
