-- Naija Elevator Creator - run once in HeidiSQL
CREATE TABLE IF NOT EXISTS `tenx_elevators` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `name` VARCHAR(64) NOT NULL,
  `floors` LONGTEXT NOT NULL,      -- JSON: [{label,x,y,z,h}]
  `access` LONGTEXT NOT NULL,      -- JSON: {public,jobs[],items[],passcode,allowVehicles}
  `created_by` VARCHAR(64) DEFAULT NULL,
  `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
