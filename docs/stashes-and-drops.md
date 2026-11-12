---
title: Stashes and drops
sidebar_position: 9
---

# Stashes, temporary stashes and drops

## Stashes

```lua
-- server
exports.kora_inventory:registerStash('police_locker', 'Police locker', 50, 100000, false,
    { police = 0 }, vector3(450.0, -985.0, 30.7), 2.0)

-- client
exports.kora_inventory:openInventory('stash', 'police_locker')
```

`registerStash(id, label, slots, maxWeight, owner, groups, coords, distance)`:

- `owner = true` registers a **template**. On open, the server derives the caller's citizen id and uses a separate durable `stash:<template>:<citizenid>` record. A client cannot choose another owner's identifier.
- `groups` maps a job or gang name to the minimum grade level, for example `{ police = 0 }`; the player's job or gang must match one entry.
- `coords` is one point or a list of points. The server checks the distance when a session opens and before every mutation; any one point is enough. A list entry may carry its own `distance`. Re-registering an id moves the boundary and keeps the contents.
- `stashGet(id)`, `stashSet(id, items)` read or replace contents; `stashOpen(src, id, opts?)` opens it for a player from the server.

### Resource-owned policy stashes

`registerStashPolicy(id, options, callback)` returns `true, inventoryKey` or `false, error`. Options: `label`, `slots`, `maxWeight`, `owner`, `groups`, `coords`, `distance`. The callback receives `(source, inventory, options)` and must return `true`; every transfer checks it again. The registering resource owns the policy; a stopped or missing provider denies access. Registration persists a required-policy marker before opening access and closes existing sessions. A fourth callback argument is trusted context; only `ClaimStash` sets `{ recovery = true }`.

- `rebindStashPolicy(id, callback)` replaces the callback of an already persisted policy for its owner without saving contents or capacity.
- `unregisterStashPolicy(id)` closes access and keeps the required marker.
- `setStashBlocked(id, blocked)` returns `true` only after the stash lock is held and the block is durably saved; a busy stash returns `false, error`, so retry before checking emptiness. It closes sessions and survives restarts.
- `ClaimStash(source, id, operationKey)` moves all items to the player and returns `true, receipt` or `false, error`. The stash, `players.inventory` and an operation receipt are committed in one checked SQL transaction, coordinated with kora_core's persistence fence. Reuse the same key after an uncertain result: a completed key returns its original receipt, and a clean capacity rejection may be retried after making room. Receipts are stored in `kora_inventory_recovery_operations`.

## Temporary stashes

`createTemporaryStash(properties)` returns an inventory key; use it with `openInventory`. Temporary stashes are only persisted when `persistence.persistTemporary` is true.

## Ground drops

Dropping an item creates a temporary `drop` inventory at the player's position and a bag prop (`Config.kora_inventory.drops`). The prop is presentation only: a local, non-networked object created independently on each client. Interacting with it calls the normal open path with the drop id; the server re-checks existence, distance and routing bucket, so removing or faking the prop gains nothing. A drop within `mergeRadius` of an existing drop in the same bucket joins it.

Player-created drops belong to the player's routing bucket (`requireSameBucket`). `kora_inventory:server:drops` and the legacy drop list return ids and coordinates only. After a bucket change the five-second session cleanup closes old drop sessions and refreshes local bags.

```lua
-- server
local dropId = exports.kora_inventory:dropCreate(GetEntityCoords(ped), {
    [1] = { name = 'water_bottle', amount = 1, slot = 1 },
})
```

`dropCreate(coords, items, bucket?)` created by trusted code is global unless a `bucket` is passed. `dropTake(src, dropId, slot, amount?)` moves items out. Client events `kora_inventory:client:dropCreated`, `dropRemoved` and `dropsUpdated` let other client scripts track bags. Drops are persisted only when `persistence.persistDrops` is true.
