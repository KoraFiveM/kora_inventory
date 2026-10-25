-- Atomic domain rewards use qbcore's fenced player columns. This is a receipt,
-- never a second player inventory or money authority.
CREATE TABLE IF NOT EXISTS `qbinventory_player_exchanges` (
  `provider` VARCHAR(64) NOT NULL,
  `operation_key` VARCHAR(128) NOT NULL,
  `citizenid` VARCHAR(50) NOT NULL,
  `request` LONGTEXT NOT NULL,
  `player_values` LONGTEXT NOT NULL,
  `receipt` LONGTEXT NOT NULL,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`provider`,`operation_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
