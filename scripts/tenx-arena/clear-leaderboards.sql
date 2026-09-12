-- ============================================================
--  NAIJA 2046 ARENA — CLEAR THE RECORD
-- ============================================================
--
--  Wipes every leaderboard and every history table. Use it to start a
--  season clean, or to throw away test data before you open to players.
--
--  WHAT THIS DELETES
--    · PVP match records — wins, losses, kills, points
--    · Ranked — ratings, peaks, placements, match history
--    · The finished-match log
--
--  WHAT THIS KEEPS
--    · Your arenas, their boundaries and spawns
--    · Marked wall boards and placed props
--    · Everyone's inventory and coin balance
--
--  If you want the coins gone too, uncomment the last section. Think about
--  it first: people bought things with those, and taking them back without
--  warning is the kind of thing players remember.
--
--  TRUNCATE cannot be undone and does not fire triggers. Take a backup
--  first if you are not certain.
-- ============================================================

-- ── PVP ──
TRUNCATE TABLE `tenx_arena_stats`;

-- ── ranked: ratings and every rated match ──
TRUNCATE TABLE `tenx_arena_ranked`;
TRUNCATE TABLE `tenx_arena_ranked_history`;

-- ── the match log ──
TRUNCATE TABLE `tenx_arena_matches`;


-- ============================================================
--  OPTIONAL — the economy
-- ============================================================
-- Uncomment to wipe coin balances and the coin ledger as well. Inventories
-- are separate; clearing balances leaves whatever people are carrying.

-- TRUNCATE TABLE `tenx_arena_rz_ledger`;
-- UPDATE `tenx_arena_rz_inv` SET `coins` = 0;

-- And to empty everyone's inventory too:
-- UPDATE `tenx_arena_rz_inv` SET `slots` = '{}', `coins` = 0;


-- ============================================================
--  ONE PLAYER ONLY
-- ============================================================
-- Put their license in place of the example. Useful for clearing a tester
-- without resetting the server.
--
-- SET @who = 'license:PUT_YOUR_LICENSE_IDENTIFIER_HERE';
--
-- DELETE FROM `tenx_arena_stats`          WHERE `identifier` = @who;
-- DELETE FROM `tenx_arena_rz_stats`       WHERE `identifier` = @who;
-- DELETE FROM `tenx_arena_ranked`         WHERE `identifier` = @who;
-- DELETE FROM `tenx_arena_ranked_history` WHERE `identifier` = @who;
-- DELETE FROM `tenx_arena_rz_ledger`      WHERE `identifier` = @who;
-- UPDATE `tenx_arena_rz_inv` SET `slots` = '{}', `coins` = 0 WHERE `identifier` = @who;


-- After running this, restart the resource so the wall boards stop showing
-- what they had cached.
