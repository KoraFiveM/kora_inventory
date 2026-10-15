CREATE TABLE IF NOT EXISTS `qbinventory_recovery_operations` (
  `provider` VARCHAR(64) NOT NULL,
  `operation_key` VARCHAR(128) NOT NULL,
  `stash_id` VARCHAR(128) NOT NULL,
  `citizenid` VARCHAR(50) NOT NULL,
  `status` VARCHAR(16) NOT NULL DEFAULT 'pending',
  `destination_items` LONGTEXT NULL,
  `source_revision` BIGINT UNSIGNED NULL,
  `receipt` LONGTEXT NULL,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`provider`,`operation_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
