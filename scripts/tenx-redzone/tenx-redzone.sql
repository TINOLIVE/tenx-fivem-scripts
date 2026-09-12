-- ============================================================
--  NAIJA 2046 — RED ZONE
-- ============================================================
--  One table. Everything about what a player OWNS lives in
--  tenx-arena; this is only the free-for-all record.
-- ============================================================

CREATE TABLE IF NOT EXISTS `tenx_rz_stats` (
    `identifier`  VARCHAR(64)  NOT NULL,
    `name`        VARCHAR(64)  NOT NULL DEFAULT '',
    `kills`       INT          NOT NULL DEFAULT 0,
    `deaths`      INT          NOT NULL DEFAULT 0,
    `points`      INT          NOT NULL DEFAULT 0,
    `streak`      INT          NOT NULL DEFAULT 0,
    `best_streak` INT          NOT NULL DEFAULT 0,
    `updated`     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
                               ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`identifier`),
    KEY `by_points` (`points` DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Where players are placed when they enter a zone.
--
-- Marked in THIS resource, not the arena. The arena owns the shape; where
-- people stand when they walk into it is this mode's business, and asking it
-- to store settings for a mode it knows nothing about is how two resources
-- end up tangled.
CREATE TABLE IF NOT EXISTS `tenx_rz_spawns` (
    `id`       INT          NOT NULL AUTO_INCREMENT,

    -- Which shape this spawn belongs to.
    --
    -- arena_id was the original: zones used to be the arena's polygons and a
    -- Red Zone borrowed them. zone_id is a tenx-zones sphere.
    --
    -- BOTH exist, and which one is read depends on
    -- Config.RZ.zones.useExternal. That is deliberate -- flipping the flag
    -- back must not lose spawns marked under the other mode, and one column
    -- would mean re-marking every zone to go either way.
    --
    -- Only one is ever set on a given row. The other is null.
    `arena_id` INT          NULL,
    `zone_id`  INT          NULL,
    `x`        FLOAT        NOT NULL,
    `y`        FLOAT        NOT NULL,
    `z`        FLOAT        NOT NULL,
    `heading`  FLOAT        NOT NULL DEFAULT 0,
    `added_by` VARCHAR(64)  NOT NULL DEFAULT '',
    PRIMARY KEY (`id`),
    KEY `by_arena` (`arena_id`),
    KEY `by_zone` (`zone_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- If you ran the old combined version, its records can be carried over.
-- Safe to skip: it does nothing when that table is gone.
--
-- INSERT INTO `tenx_rz_stats`
--     (identifier, name, kills, deaths, points, streak, best_streak)
-- SELECT identifier, name, kills, deaths, points, streak, best_streak
-- FROM `tenx_arena_rz_stats`
-- ON DUPLICATE KEY UPDATE
--     kills = VALUES(kills), deaths = VALUES(deaths), points = VALUES(points),
--     best_streak = GREATEST(`tenx_rz_stats`.best_streak, VALUES(best_streak));


-- ── upgrades ──
--
-- CREATE TABLE IF NOT EXISTS does nothing when the table already exists, so
-- a column added later never appears from re-running this file. The script
-- adds these itself on boot; they are here so the schema in this file is the
-- truth.
--
-- Safe to ignore a "duplicate column" error -- it means the script got there
-- first.
--
-- ALTER TABLE `tenx_rz_spawns` MODIFY `arena_id` INT NULL;
-- ALTER TABLE `tenx_rz_spawns` ADD COLUMN `zone_id` INT NULL;
-- ALTER TABLE `tenx_rz_spawns` ADD KEY `by_zone` (`zone_id`);
