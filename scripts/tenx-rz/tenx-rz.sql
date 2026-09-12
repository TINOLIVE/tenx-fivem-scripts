-- tenx-rz schema
-- Run this ONCE against your server database before starting the resource.

-- Outstanding snapshots. A row here means "this player is owed their inventory back".
-- The PRIMARY KEY on identifier is the safety guard: it makes it physically
-- impossible to confiscate the same player twice and overwrite their real
-- inventory with an arena-only one.
CREATE TABLE IF NOT EXISTS `tenx_rz_snapshots` (
    `identifier`  VARCHAR(60)  NOT NULL,
    `citizenid`   VARCHAR(50)  DEFAULT NULL,
    `player_name` VARCHAR(64)  DEFAULT NULL,
    `event_id`    VARCHAR(40)  NOT NULL,
    `inventory`   LONGTEXT     NOT NULL,
    `status`      ENUM('active','pending') NOT NULL DEFAULT 'active',
    `taken_at`    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`identifier`),
    KEY `idx_status` (`status`),
    KEY `idx_event` (`event_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Permanent audit trail. Nothing is ever deleted from here.
-- If someone claims they lost items, this is where you look.
CREATE TABLE IF NOT EXISTS `tenx_rz_log` (
    `id`          INT(11)      NOT NULL AUTO_INCREMENT,
    `identifier`  VARCHAR(60)  NOT NULL,
    `citizenid`   VARCHAR(50)  DEFAULT NULL,
    `player_name` VARCHAR(64)  DEFAULT NULL,
    `event_id`    VARCHAR(40)  NOT NULL,
    `inventory`   LONGTEXT     NOT NULL,
    `failed`      LONGTEXT     DEFAULT NULL,
    `taken_at`    TIMESTAMP    NULL DEFAULT NULL,
    `restored_at` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_identifier` (`identifier`),
    KEY `idx_event` (`event_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Round history. One row per round, written when it ends.
-- This is what the Winners tab in the admin panel reads.
CREATE TABLE IF NOT EXISTS `tenx_rz_rounds` (
    `id`            INT(11)     NOT NULL AUTO_INCREMENT,
    `event_id`      VARCHAR(40) NOT NULL,
    `winner_name`   VARCHAR(64) DEFAULT NULL,
    `winner_id`     VARCHAR(60) DEFAULT NULL,
    `winner_kills`  INT(11)     NOT NULL DEFAULT 0,
    `players`       INT(11)     NOT NULL DEFAULT 0,
    `duration`      INT(11)     NOT NULL DEFAULT 0,
    `radius`        INT(11)     NOT NULL DEFAULT 0,
    `end_reason`    VARCHAR(32) DEFAULT NULL,
    `started_by`    VARCHAR(64) DEFAULT NULL,
    `ended_at`      TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_winner` (`winner_id`),
    KEY `idx_ended` (`ended_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
