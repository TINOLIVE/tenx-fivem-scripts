-- tenx-plates | run this once on your database
CREATE TABLE IF NOT EXISTS `tenx_plates_blocked` (
  `word` VARCHAR(32) NOT NULL,
  PRIMARY KEY (`word`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
