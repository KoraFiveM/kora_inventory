---
title: Database
sidebar_position: 17
---

# Database

## Player items

kora_inventory never creates or writes a player item table. Player items live in kora_core's `PlayerData.items` and its `players.inventory` column, and are only changed through kora_core exports (`setPath`).

## Tables owned by kora_inventory

Created and extended at start by `Kora.sql.ensureTables` from `server/schema.lua`; there is nothing to import. Existing installs only gain missing columns or keys, never altered ones. Collation is `utf8mb4_unicode_ci` where set.

| Table | Primary key | Purpose |
| --- | --- | --- |
| `kora_inventory_inventories` | `inventory_type`, `inventory_id` | Secondary inventories (stashes, trunks, gloveboxes, containers, evidence, shops, optionally drops and temporary stashes): `label`, `slots`, `max_weight`, `revision`, `items` (JSON), `properties` (JSON), `created_at`, `updated_at`. |
| `kora_inventory_shop_stock` | `shop_id`, `slot` | Persisted shop stock rows (`item` JSON, `revision`). |
| `kora_inventory_audit` | `id` | Audit rows: `actor`, `action`, `inventory_type`, `inventory_id`, `details`. Indexed by inventory and by action. The helper that inserts rows (`persistence.audit` in `server/persistence.lua`) has no caller in this repository, so the table stays empty; audit entries only exist in memory and as the `kora_inventory:server:audit` event. |
| `kora_inventory_migration_state` | `source_name` | Legacy import status and counters per source. |
| `kora_inventory_migration_rows` | `source_name`, `source_key` | One row per imported legacy record with `source_checksum`, `status`, `error`. |
| `kora_inventory_quarantine` | `id` | Malformed legacy rows kept for review (`reason`, `raw_payload`). |
| `kora_inventory_recovery_operations` | `provider`, `operation_key` | `ClaimStash` operations (`stash_id`, `citizenid`, `status`, `receipt`). |
| `kora_inventory_player_exchanges` | `provider`, `operation_key` | Permanent receipts for `ExecutePlayerExchange`. |

Secondary inventories are written by a flush every `persistence.flushInterval` milliseconds (default 5000) and when the resource stops. Request handling itself never waits on a database write. Set `persistence.enabled = false` to disable persistence. Drops and temporary stashes are not persisted unless `persistDrops` / `persistTemporary` are set.

## Legacy import

`kora_inventory-migrate` (see [Commands and keybinds](./commands.md)) reads these tables when present: `inventories`, `stashitems`, `trunkitems`, `gloveboxitems` (`persistence.legacyTables`), accepting common identifier, slot and weight column spellings and preserving original item metadata.

- Legacy rows are copied, never deleted or updated.
- A row already imported with the same checksum is skipped; a row whose legacy contents changed is reported, not applied over a possibly live record.
- Malformed JSON or item slots are stored in `kora_inventory_quarantine`.
- Rows are processed in batches of `persistence.migrationBatchSize` (100).
- `kora_inventory:server:migrationProgress` is fired while it runs.
