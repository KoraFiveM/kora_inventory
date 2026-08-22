-- qbinventory owns this schema only. `players.inventory` remains qbcore's
-- canonical player storage and is intentionally absent from this migration.

CREATE TABLE IF NOT EXISTS `qbinventory_inventories` (
  `inventory_type` VARCHAR(32) NOT NULL,
  `inventory_id` VARCHAR(128) NOT NULL,
  `label` VARCHAR(128) NOT NULL,
  `slots` SMALLINT UNSIGNED NOT NULL DEFAULT 50,
  `max_weight` INT UNSIGNED NOT NULL DEFAULT 100000,
  `revision` BIGINT UNSIGNED NOT NULL DEFAULT 0,
  `items` LONGTEXT NOT NULL,
  `properties` LONGTEXT NOT NULL,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`inventory_type`, `inventory_id`),
  KEY `idx_qbinventory_updated` (`updated_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `qbinventory_shop_stock` (
  `shop_id` VARCHAR(128) NOT NULL,
  `slot` SMALLINT UNSIGNED NOT NULL,
  `item` LONGTEXT NOT NULL,
  `revision` BIGINT UNSIGNED NOT NULL DEFAULT 0,
  `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`shop_id`, `slot`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `qbinventory_audit` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `actor` VARCHAR(96) DEFAULT NULL,
  `action` VARCHAR(64) NOT NULL,
  `inventory_type` VARCHAR(32) DEFAULT NULL,
  `inventory_id` VARCHAR(128) DEFAULT NULL,
  `details` LONGTEXT NOT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_qbinventory_audit_inventory` (`inventory_type`, `inventory_id`, `created_at`),
  KEY `idx_qbinventory_audit_action` (`action`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `qbinventory_migration_state` (
  `source_name` VARCHAR(64) NOT NULL,
  `status` VARCHAR(24) NOT NULL,
  `last_started_at` TIMESTAMP NULL DEFAULT NULL,
  `last_finished_at` TIMESTAMP NULL DEFAULT NULL,
  `imported_count` INT UNSIGNED NOT NULL DEFAULT 0,
  `skipped_count` INT UNSIGNED NOT NULL DEFAULT 0,
  `quarantined_count` INT UNSIGNED NOT NULL DEFAULT 0,
  `last_error` TEXT DEFAULT NULL,
  PRIMARY KEY (`source_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `qbinventory_migration_rows` (
  `source_name` VARCHAR(64) NOT NULL,
  `source_key` VARCHAR(191) NOT NULL,
  `source_checksum` CHAR(64) NOT NULL,
  `inventory_type` VARCHAR(32) DEFAULT NULL,
  `inventory_id` VARCHAR(128) DEFAULT NULL,
  `status` VARCHAR(24) NOT NULL,
  `error` TEXT DEFAULT NULL,
  `imported_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`source_name`, `source_key`),
  KEY `idx_qbinventory_migration_status` (`status`, `imported_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `qbinventory_quarantine` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `source_name` VARCHAR(64) NOT NULL,
  `source_key` VARCHAR(191) NOT NULL,
  `reason` VARCHAR(255) NOT NULL,
  `raw_payload` LONGTEXT NOT NULL,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_qbinventory_quarantine_source` (`source_name`, `source_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
