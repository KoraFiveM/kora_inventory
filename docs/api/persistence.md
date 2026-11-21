---
title: "Persistence and migration"
sidebar_position: 16
---


# Persistence and migration

Secondary inventories (stashes, shops, trunks, gloveboxes, containers, evidence and optionally drops and temporary stashes) are saved to MySQL as JSON with a revision. Player items are never stored here: kora_core owns `PlayerData.items` and the `players.inventory` column. This page lists the tables, how saving and restoring work, and the migration tools for older qb-inventory data.

Namespace: `exports.kora_inventory` · Source: `server/schema.lua, server/persistence.lua, server/recovery.lua`

## How it works

At startup `server/schema.lua` declares the tables and `server/persistence.lua` calls `Kora.sql.ensureTables` (after `Kora.sql.ready`). When it succeeds the resource restores every stored inventory (`restoreAll`), merges each with any registration that already happened in memory (a registered access callback always wins over stored descriptive state), and fires `kora_inventory:server:ready`. Each committed change marks the inventory dirty; every `flushInterval` ms the dirty snapshots are written with an upsert. Shops save one row per stock slot in a batched upsert. On resource stop a final flush runs. Records whose stored JSON is malformed are skipped, reported with `kora_inventory:server:persistenceRejected` and left untouched. Functions (access callbacks) are never serialised.

## Migrating old inventory data

1. **Dry run** — Run `kora_inventory-migrate dry-run` from the server console to see how many rows would be imported, skipped or quarantined.
2. **Import** — Run `kora_inventory-migrate run`. Legacy tables are only read, never changed or deleted. Rows already imported with the same checksum are skipped; a legacy row that changed after import is reported as `changed` and left alone.
3. **Verify** — Run `kora_inventory-migrate verify` to check every stored item JSON and print the migration state. Use `retry` to revisit failed or quarantined rows after fixing them.

## Terms used on this page

| Term | Meaning |
| --- | --- |
| Dirty snapshot | A copy of an inventory queued for the next flush. |
| Quarantine | Legacy rows that could not be parsed, copied to `kora_inventory_quarantine` for review. |
| Tombstone | A `deleted` row in `kora_inventory_migration_rows` that stops a deleted legacy stash being re-imported. |

## Database tables

Created by `Kora.sql.ensureTables`. Existing installs only gain missing columns or keys. All use `utf8mb4_unicode_ci` unless noted.

| Option | Type | Description |
| --- | --- | --- |
| `kora_inventory_inventories` | table | One row per secondary inventory. Primary key `(inventory_type, inventory_id)`. Columns: `label`, `slots` (default 50), `max_weight` (default 100000), `revision`, `items` (JSON, slot-keyed), `properties` (JSON: coords, bucket, distance, groups, owner, temporary, stock, prices, currency, accessRequired, policyOwner, blocked), `created_at`, `updated_at`. |
| `kora_inventory_shop_stock` | table | Per-slot shop stock. Primary key `(shop_id, slot)`; columns `item` (JSON), `revision`, `updated_at`. |
| `kora_inventory_audit` | table | Declared audit table (`actor`, `action`, `inventory_type`, `inventory_id`, `details`). Nothing in kora_inventory currently writes to it; the audit ring is in memory. |
| `kora_inventory_migration_state` | table | Per legacy source: status, start/finish times, imported, skipped and quarantined counts, last error. |
| `kora_inventory_migration_rows` | table | Per legacy row `(source_name, source_key)`: checksum, target type and id, status (`imported`, `changed`, `quarantined`, `deleted`), error. |
| `kora_inventory_quarantine` | table | Raw payloads of rows that failed validation, with the reason. |
| `kora_inventory_recovery_operations` | table | `ClaimStash` receipts: `provider`, `operation_key`, `stash_id`, `citizenid`, `status` (`pending`/`complete`), `destination_items`, `source_revision`, `receipt`. |
| `kora_inventory_player_exchanges` | table | `ExecutePlayerExchange` receipts: `provider`, `operation_key`, `citizenid`, `request`, `player_values`, `receipt`. |

## Item-creation audit log

`kora_inventory_audit` records every item that is *created* in an inventory (not moved between inventories), so admins can find duplication and badly written scripts. The recording code is `server/audit_log.lua`; the SQL (`auditInsertBatch`, `auditQuery`, `auditSummary`, `auditPrune`) is in `server/persistence.lua`.

- **Batched writes.** An item add only appends to an in-memory queue. The queue is written with one multi-row `INSERT` every `audit.flushSeconds` (default 10) or as soon as 200 rows are waiting, from a background thread, so an add never waits on SQL. If the database is unavailable the rows stay queued (up to 5000) and are retried.
- **Retention.** Rows older than `audit.retentionDays` (default 14) are deleted at start and then once an hour with `DELETE ... WHERE created_at < FROM_UNIXTIME(cutoff)`.
- **What is recorded.** Time, action (`add`, `purchase`, `craft`, `exchange`, `omnipack`, `set`, and `remove` only when `audit.trackRemovals` is on), the player's citizen id and server id, item name, amount, inventory key, the invoking resource and the reason string if one was given. The invoking resource is captured where the export enters kora_inventory, because deeper in the call `GetInvokingResource()` no longer names the caller.
- **Not recorded.** Moves, swaps, gives, drops and pickups (the items already existed), and physical cash credits made by kora_core.
- **Persistence off.** With `audit.persist = false` only the in-memory ring (`auditLimit` entries) is kept and no rows are written.

Read it in game with `/invaudit` (see [Commands](../commands.md)); there is no other reader.

## What is and is not saved

Saved: stash, trunk, glovebox, container, evidence and shop inventories. Saved only with the config flags: drops (`persistDrops`) and temporary inventories (`persistTemporary`). Never saved: player inventories, access callbacks, per-registration policy such as `weightLimit`.

## Item JSON shape

Stored items are a slot-keyed object. Each row needs a non-empty `name`, a whole `amount` or `count` of at least 1 and a slot from 1 to 10000. The loader keeps `info` and `metadata` in sync and preserves every other field.

## Legacy import columns

The importer reads `inventories` (identifier or id, plus `kind` or `type`), `stashitems` (`stash`, `stashid`, `identifier` or `id`), `trunkitems` and `gloveboxitems` (`plate`, `identifier` or `id`), taking `items`, `slots` and `maxweight`/`max_weight` when present. It tolerates the ox-style `count` field.

## Stash recovery

`ClaimStash` moves a policy-owned stash into a player in one SQL transaction guarded by kora_core's player column fence and a receipt, so a crash or a retry can never duplicate or lose the items.

## Internal persistence API

The Lua table `KoraInventory.persistence` (not exported) provides `save`, `load`, `markDirty`, `flush`, `delete`, `restoreAll`, `normaliseItems`, `shouldPersist`, `getStatus`, `migrateLegacy`, `verifyMigration`, `withLock`, `committed`, `deleteLegacyPoliceTrash`, `audit` (generic row writer), and the item-creation audit helpers `auditInsertBatch`, `auditQuery`, `auditSummary` and `auditPrune`. The generated admin omnipack shop is never persisted.

## Functions

Only one persistence export is meant for another resource, and it is restricted to kora_sql. Use `getPersistenceStatus` (see Opening inventories) to check readiness.

### `exports.kora_inventory:deleteLegacyPoliceTrash(callback)`

Restricted bridge used by kora_sql to carry out the one reviewed legacy statement that stock qb-policejob runs against the `policetrash` stash. It deletes that stash from durable storage and records a tombstone so it is never re-imported. Any resource other than `kora_sql` receives an error through the callback.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `callback` | function | `callback(affectedRows, err)` called when finished. |

**Returns**

- **No return value. The callback receives the number of deleted rows, or nil with an error such as `legacy inventory SQL bridge is restricted to kora_sql`, `inventory persistence is disabled`, `inventory persistence readiness timed out`, `inventory recovery is being reconciled`.**

**Example**

```lua
-- only kora_sql can use this; shown for completeness
exports.kora_inventory:deleteLegacyPoliceTrash(function(rows, err)
    print(rows, err)
end)
```

**Representative console output**

```text
From any resource other than kora_sql: nil, 'legacy inventory SQL bridge is restricted to kora_sql'
```

## Common use cases

- Keeping stashes, trunks and shops across restarts.
- Importing an old qb-inventory database once.
- Waiting for `ready` before registering resource-owned stashes.

## Limits and related APIs

Persistence can be turned off (`persistence.enabled = false`), in which case every secondary inventory lives in memory only and `RegisterStashPolicy` / `ClaimStash` are unavailable. Writes are batched every `flushInterval` ms, so a hard crash can lose up to that window of changes for secondary inventories. Restock config changes do not overwrite persisted shop stock.

## Related guides

- [Stashes](./stashes.md)
- [Shops](./shops.md)
- [Durable player exchanges](./exchange.md)
- [Configuration](./configuration.md)

## Operating notes (from the code)

Facts below were written from the current code of this resource; they add to, and where noted refine, the reference above.

### Player items

kora_inventory never creates or writes a player item table. Player items live in kora_core's `PlayerData.items` and its `players.inventory` column, and are only changed through kora_core exports (`setPath`).

### Tables owned by kora_inventory

Created and extended at start by `Kora.sql.ensureTables` from `server/schema.lua`; there is nothing to import. Existing installs only gain missing columns or keys, never altered ones. Collation is `utf8mb4_unicode_ci` where set.

| Table | Primary key | Purpose |
| --- | --- | --- |
| `kora_inventory_inventories` | `inventory_type`, `inventory_id` | Secondary inventories (stashes, trunks, gloveboxes, containers, evidence, shops, optionally drops and temporary stashes): `label`, `slots`, `max_weight`, `revision`, `items` (JSON), `properties` (JSON), `created_at`, `updated_at`. |
| `kora_inventory_shop_stock` | `shop_id`, `slot` | Persisted shop stock rows (`item` JSON, `revision`). |
| `kora_inventory_audit` | `id` | The item-creation audit log (see [Item-creation audit log](#item-creation-audit-log)). Columns: `created_at`, `actor`, `action`, `inventory_type`, `inventory_id`, `details`, plus `citizenid`, `source`, `item`, `amount`, `resource`, `reason`. The item-creation columns are nullable and are added to existing installs by `Kora.sql.ensureTables`. Indexed by inventory, action, `created_at`, `(item, created_at)`, `(resource, created_at)` and `(citizenid, created_at)`. Rows are written in batches and pruned after `audit.retentionDays`. |
| `kora_inventory_migration_state` | `source_name` | Legacy import status and counters per source. |
| `kora_inventory_migration_rows` | `source_name`, `source_key` | One row per imported legacy record with `source_checksum`, `status`, `error`. |
| `kora_inventory_quarantine` | `id` | Malformed legacy rows kept for review (`reason`, `raw_payload`). |
| `kora_inventory_recovery_operations` | `provider`, `operation_key` | `ClaimStash` operations (`stash_id`, `citizenid`, `status`, `receipt`). |
| `kora_inventory_player_exchanges` | `provider`, `operation_key` | Permanent receipts for `ExecutePlayerExchange`. |

Secondary inventories are written by a flush every `persistence.flushInterval` milliseconds (default 5000) and when the resource stops. Request handling itself never waits on a database write. Set `persistence.enabled = false` to disable persistence. Drops and temporary stashes are not persisted unless `persistDrops` / `persistTemporary` are set.

### Legacy import

`kora_inventory-migrate` (see [Commands and keybinds](../commands.md)) reads these tables when present: `inventories`, `stashitems`, `trunkitems`, `gloveboxitems` (`persistence.legacyTables`), accepting common identifier, slot and weight column spellings and preserving original item metadata.

- Legacy rows are copied, never deleted or updated.
- A row already imported with the same checksum is skipped; a row whose legacy contents changed is reported, not applied over a possibly live record.
- Malformed JSON or item slots are stored in `kora_inventory_quarantine`.
- Rows are processed in batches of `persistence.migrationBatchSize` (100).
- `kora_inventory:server:migrationProgress` is fired while it runs.
