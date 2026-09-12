-- tenx-zones
--
-- You do NOT have to run this. server/main.lua creates the table on
-- first start. It is here so you can import it by hand, or check the
-- shape of it, or drop and rebuild without restarting the server.

CREATE TABLE IF NOT EXISTS `tenx_zones` (
    `id`         INT AUTO_INCREMENT PRIMARY KEY,
    `name`       VARCHAR(48) NOT NULL,
    `kind`       VARCHAR(8)  NOT NULL,
    `data`       LONGTEXT    NOT NULL,
    `solid`      TINYINT(1)  NOT NULL DEFAULT 1,
    `visible`    TINYINT(1)  NOT NULL DEFAULT 1,
    `created_by` VARCHAR(64) DEFAULT NULL,
    `created_at` TIMESTAMP   DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- `kind` is 'sphere' or 'poly'.
--
-- `data` is JSON and its shape depends on `kind`:
--
--   sphere: {"center":{"x":0,"y":0,"z":0},"radius":40.0,
--            "color":{"r":255,"g":77,"b":61}}
--
--   poly:   {"points":[{"x":0,"y":0}, ...],"minZ":0.0,"maxZ":50.0,
--            "color":{"r":255,"g":77,"b":61}}
--
-- Bindings (which bucket or which players a zone applies to) are
-- deliberately NOT stored here. They are runtime state owned by
-- arena and redzone, and a stale binding surviving a restart would
-- wall players into a match that no longer exists.
