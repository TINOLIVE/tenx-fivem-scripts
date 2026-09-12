-- tenx-arena schema
-- Run this ONCE against your server database before starting the resource.

-- One row per arena. The flexible parts (bounds, spawns, loadout, settings)
-- live in a JSON blob so the shape can grow without a migration every time.
CREATE TABLE IF NOT EXISTS `tenx_arena_zones` (
    `id`         INT(11)     NOT NULL AUTO_INCREMENT,
    `name`       VARCHAR(64) NOT NULL,
    `data`       LONGTEXT    NOT NULL,
    `enabled`    TINYINT(1)  NOT NULL DEFAULT 1,
    `created_by` VARCHAR(64) DEFAULT NULL,
    `created_at` TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at` TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_enabled` (`enabled`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Meeting zones: where players gather to queue. Marked in the admin panel.
CREATE TABLE IF NOT EXISTS `tenx_arena_meeting` (
    `id`         INT(11)     NOT NULL AUTO_INCREMENT,
    `name`       VARCHAR(64) NOT NULL,
    `x`          FLOAT       NOT NULL,
    `y`          FLOAT       NOT NULL,
    `z`          FLOAT       NOT NULL,
    `heading`    FLOAT       NOT NULL DEFAULT 0,
    `enabled`    TINYINT(1)  NOT NULL DEFAULT 1,
    `created_by` VARCHAR(64) DEFAULT NULL,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Per-player record. One row per player, updated as matches finish.
CREATE TABLE IF NOT EXISTS `tenx_arena_stats` (
    `identifier` VARCHAR(60) NOT NULL,
    `name`       VARCHAR(64) DEFAULT NULL,
    `wins`       INT(11)     NOT NULL DEFAULT 0,
    `losses`     INT(11)     NOT NULL DEFAULT 0,
    `kills`      INT(11)     NOT NULL DEFAULT 0,
    `deaths`     INT(11)     NOT NULL DEFAULT 0,
    `matches`    INT(11)     NOT NULL DEFAULT 0,
    `points`     INT(11)     NOT NULL DEFAULT 0,
    `updated_at` TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`identifier`),
    KEY `idx_wins` (`wins`),
    KEY `idx_kills` (`kills`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Finished matches, for history and dispute-settling.
CREATE TABLE IF NOT EXISTS `tenx_arena_matches` (
    `id`         INT(11)     NOT NULL AUTO_INCREMENT,
    `arena_id`   INT(11)     DEFAULT NULL,
    `arena_name` VARCHAR(64) DEFAULT NULL,
    `mode`       VARCHAR(16) DEFAULT NULL,
    `score_a`    INT(11)     NOT NULL DEFAULT 0,
    `score_b`    INT(11)     NOT NULL DEFAULT 0,
    `winner`     CHAR(1)     DEFAULT NULL,
    `players`    LONGTEXT    DEFAULT NULL,
    `duration`   INT(11)     NOT NULL DEFAULT 0,
    `ended_at`   TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_ended` (`ended_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Leaderboard boards: the four corner points you mark with /rzboard.
-- In the database rather than a file in the resource folder, because that
-- folder is replaced every time the script is re-uploaded.
CREATE TABLE IF NOT EXISTS `tenx_arena_boards` (
    `id`         VARCHAR(32) NOT NULL,
    `name`       VARCHAR(64) DEFAULT NULL,
    -- What this board shows: pvp, ranked, or list.
    `kind`       VARCHAR(16) NOT NULL DEFAULT 'rotate',
    `corners`    LONGTEXT    NOT NULL,
    `created_by` VARCHAR(64) DEFAULT NULL,
    `created_at` TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Props placed with /rzprop, including their rotation.
CREATE TABLE IF NOT EXISTS `tenx_arena_props` (
    `id`         VARCHAR(32) NOT NULL,
    `model`      VARCHAR(64) NOT NULL,
    `x`          FLOAT       NOT NULL,
    `y`          FLOAT       NOT NULL,
    `z`          FLOAT       NOT NULL,
    `rx`         FLOAT       NOT NULL DEFAULT 0,
    `ry`         FLOAT       NOT NULL DEFAULT 0,
    `rz`         FLOAT       NOT NULL DEFAULT 0,
    `created_by` VARCHAR(64) DEFAULT NULL,
    `created_at` TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `tenx_arena_rz_inv` (
    `identifier` VARCHAR(60) NOT NULL,
    `slots`      LONGTEXT    NOT NULL,
    `coins`      INT(11)     NOT NULL DEFAULT 0,
    `updated_at` TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`identifier`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Every coin in and out, so a balance can be explained rather than argued
-- about.
CREATE TABLE IF NOT EXISTS `tenx_arena_rz_ledger` (
    `id`         INT(11)     NOT NULL AUTO_INCREMENT,
    `identifier` VARCHAR(60) NOT NULL,
    `amount`     INT(11)     NOT NULL,
    `reason`     VARCHAR(64) NOT NULL,
    `balance`    INT(11)     NOT NULL DEFAULT 0,
    `created_at` TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_ledger_player` (`identifier`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Ranked. Kept apart from the casual record: an Elo rating and a win count
-- answer different questions, and mixing them would let casual play move a
-- competitive rank.
CREATE TABLE IF NOT EXISTS `tenx_arena_ranked` (
    `identifier` VARCHAR(60) NOT NULL,
    `name`       VARCHAR(64) DEFAULT NULL,
    `elo`        INT(11)     NOT NULL DEFAULT 1000,
    `peak_elo`   INT(11)     NOT NULL DEFAULT 1000,
    `wins`       INT(11)     NOT NULL DEFAULT 0,
    `losses`     INT(11)     NOT NULL DEFAULT 0,
    `placed`     INT(11)     NOT NULL DEFAULT 0,
    `streak`     INT(11)     NOT NULL DEFAULT 0,
    `best_streak` INT(11)    NOT NULL DEFAULT 0,
    `updated_at` TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`identifier`),
    KEY `idx_elo` (`elo`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Every ranked result, so a rating can be explained rather than argued about.
CREATE TABLE IF NOT EXISTS `tenx_arena_ranked_history` (
    `id`         INT(11)     NOT NULL AUTO_INCREMENT,
    `identifier` VARCHAR(60) NOT NULL,
    `mode`       VARCHAR(16) DEFAULT NULL,
    `opponent`   VARCHAR(64) DEFAULT NULL,
    `won`        TINYINT(1)  NOT NULL DEFAULT 0,
    `elo_before` INT(11)     NOT NULL DEFAULT 0,
    `elo_after`  INT(11)     NOT NULL DEFAULT 0,
    `score`      VARCHAR(16) DEFAULT NULL,
    `played_at`  TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_hist_player` (`identifier`, `played_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- ── upgrades ──
--
-- CREATE TABLE IF NOT EXISTS above does nothing when a table already exists,
-- so a column added in a later version never appears from re-running this
-- file. The script adds these itself on boot; they are here as well so the
-- schema in this file is the truth.
--
-- Safe to ignore an "column already exists" error on these -- it means the
-- script got there first.

-- ALTER TABLE `tenx_arena_boards` ADD COLUMN `kind` VARCHAR(16) NOT NULL DEFAULT 'rotate';

-- The podium shows the real top three -- their face and their clothes -- so a
-- copy of each player's look is kept here. Captured when a ranked result is
-- written, because every clothing script answers only for a CONNECTED player
-- and a leaderboard is mostly people who are offline.
--
-- Null is normal: no clothing script, or a player who has not placed a ranked
-- match since this column existed. They get a stand-in model until they do.
-- ALTER TABLE `tenx_arena_ranked` ADD COLUMN `appearance` LONGTEXT NULL;
