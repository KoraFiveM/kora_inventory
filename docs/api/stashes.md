---
title: "Stashes"
sidebar_position: 5
---


# Stashes

A stash is persistent storage with a label, slot and weight limit and an optional access boundary: a job or gang grade, an owner, a location and a callback. Register stashes from a server script, open them with `OpenInventory`/`stashOpen` or from the client, and read or replace their contents from the server. Resources that own a stash through a policy callback also get persistence-aware helpers to block it and to recover its contents into a player.

Namespace: `exports.kora_inventory` · Source: `server.lua (registerStash, stashGet/Set/Open, stash policy functions), server/recovery.lua`

## How it works

A stash is stored under `stash:<id>` and saved to `kora_inventory_inventories`. Registration is idempotent: registering again keeps the stored items and refreshes the access boundary (label, size, coords, groups, owner, access). Access callbacks are Lua functions and are never saved, so a resource must register its stash on every start. A stash opened through `stashOpen` that was never registered is created on demand with default size. A per-citizen stash (`owner = true`) is a template: each citizen gets their own record `stash:<id>:<citizenid>` created the first time they open it.

## Creating a protected stash

1. **Register on every start** — Call `RegisterStash(id, label, slots, maxWeight, owner, groups, coords, distance)` from your resource. Always give at least one boundary: `groups`, `owner`, `coords` or open it only from your own validated server code.
2. **Let players open it** — From a client target or key press call `exports.kora_inventory:openInventory('stash', id)`. The server runs the access checks. Or open it for them from the server with `OpenInventory`.
3. **Read or change contents from the server** — `GetStashItems` returns a copy; `SetStashItems` replaces the whole table with validation. Use them for seeding, clearing or syncing.
4. **Use a policy for resource-owned storage** — Housing or business storage that must survive restarts under a resource's own rules uses `RegisterStashPolicy`, `RebindStashPolicy`, `SetStashBlocked` and `ClaimStash`.

## Terms used on this page

| Term | Meaning |
| --- | --- |
| Owner stash | A stash registered with `owner = true`; one private copy per citizen id. |
| Stash policy | A persisted access rule owned by a resource: the options are stored, the callback is bound again on each start. |
| Blocked | A policy-owned stash flag that denies every open until cleared. |
| Group | A job or gang name mapped to the minimum grade level allowed, for example `{ police = 2 }`. |

## Stash options (opts table / RegisterStashPolicy options)

These keys are read from the options table of `stashOpen`, `OpenInventory`, `CreateTemporaryStash` and `RegisterStashPolicy`.

| Option | Type | Description |
| --- | --- | --- |
| `label` | string | Display name. Defaults to the id. |
| `slots` | integer | Slot count. Defaults to `Config.kora_inventory.defaultSlots` (50). For `RegisterStashPolicy` an integer from 1 to 10000. |
| `maxWeight` | number | Capacity in grams. Defaults to `defaultMaxWeight` (100000). `maxweight` is also accepted. For policies it must be a finite number of at least 0. |
| `coords` | vector3 \| table \| table[] | One point `{ x, y, z }` or a list of points (each may carry its own `distance`). Required distance is checked on every open and every request in the session. |
| `distance` | number | Reach in metres. Default `interactionDistance`. For policies it must be greater than 0. |
| `groups` | table&lt;string, integer> | Job or gang name to minimum grade level. Values must be numbers. |
| `owner` | integer \| string \| true | A player source or citizen id restricts access to that player. `true` makes a per-citizen stash. Never take this from a client. |
| `access` | function | `access(source, inventory, opts, ctx)`; return a truthy value to allow. `inventory` is the live record: treat it as read-only. `ctx` is `{ recovery = true }` only during `ClaimStash`. |
| `items` | table | Initial contents when a stash is first created. Copied as given and not validated; use `SetStashItems` for validated seeding. |
| `id` | string | `CreateTemporaryStash` only: id of the temporary stash (default `tmp-<timer>`). |

## Functions

Functions exported by this realm.

### `exports.kora_inventory:RegisterStash(id, label?, slots?, maxWeight?, owner?, groups?, coords?, distance?)`

Registers (or refreshes) a stash. Existing contents are kept. With `owner = true` it registers a per-citizen template instead of a single shared stash. A stash that is controlled by a stash policy is returned unchanged. Alias `registerStash`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | string \| number | Stash id. |
| `label?` | string | Display name. |
| `slots?` | integer | Slot count. |
| `maxWeight?` | number | Capacity in grams. |
| `owner?` | integer \| string \| true | Owner restriction or `true` for per-citizen stashes. |
| `groups?` | table&lt;string, integer> | Job/gang grade requirements. |
| `coords?` | vector3 \| table \| table[] | Location boundary. |
| `distance?` | number | Reach in metres. |

**Returns**

- **inventoryKey** — `stash:<id>` (for a per-citizen template this is still the template key, not the personal one).

**Example**

```lua
-- shared, job-restricted, location-bound
exports.kora_inventory:RegisterStash('pd_armoury', 'PD Armoury', 60, 250000, nil, { police = 2 }, vector3(452.6, -980.0, 30.7), 2.0)

-- private per-citizen apartment stash
exports.kora_inventory:RegisterStash('apartment_5', 'Apartment 5', 30, 120000, true)
```

**Representative console output**

```text
Returns 'stash:pd_armoury'. Nothing changes for players until they open it.
```

### `exports.kora_inventory:GetStashItems(id)`

Returns a copy of a stash's items (slot-keyed). The stash is created empty with default size if it does not exist, so a misspelt id silently creates a new stash. Native alias `stashGet`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | string \| number | Stash id. |

**Returns**

- **items** — slot-keyed table of instance tables.

**Example**

```lua
local items = exports.kora_inventory:GetStashItems('pd_armoury')
local count = 0
for _, item in pairs(items) do count = count + item.amount end
```

**Representative console output**

```text
items = { [1] = { name = 'weapon_pistol', amount = 1, ... } }
```

### `exports.kora_inventory:SetStashItems(id, items)`

Replaces a stash's whole contents. Every row is rebuilt from its definition and validated (slot within range, known item, amount, total weight). Open viewers are patched. Native alias `stashSet`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | string \| number | Stash id (created if missing). |
| `items` | table&lt;integer, table> | Slot-keyed rows `{ name, amount\|count, info\|metadata }`. `nil` clears the stash. |

**Returns**

- **updated** — true on success.
- **reason** — `invalid item table`, `over weight`, `inventory is locked`, `items must be a table`, `inventory recovery is being reconciled`, `inventory busy`.

**Example**

```lua
local ok, reason = exports.kora_inventory:SetStashItems('shared_fridge', {
    [1] = { name = 'water_bottle', amount = 20 },
    [2] = { name = 'sandwich', amount = 10 },
})
```

**Representative console output**

```text
ok = true; the fridge now holds exactly those two stacks.
```

### `exports.kora_inventory:stashOpen(src, identifier, opts?)`

Opens a stash for a player, creating it with `opts` when it does not exist. Registered owner templates (and `opts.owner = true`) open the player's personal copy. Does not apply the downed/cuffed check that `OpenInventory` with a type does.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `identifier` | string \| number | Stash id. |
| `opts?` | table | Stash options (see above). |

**Returns**

- **opened** — boolean.
- **result** — session payload or a reason (`owner identity unavailable`, `access denied`, `not owner`, ...).

**Example**

```lua
local opened, result = exports.kora_inventory:stashOpen(src, 'shared_fridge', { label = 'Fridge', slots = 20, maxWeight = 40000, coords = vector3(1.0, 2.0, 3.0), distance = 2.0 })
```

**Representative console output**

```text
opened = true and the stash appears next to the player's inventory.
```

### `exports.kora_inventory:CreateTemporaryStash(properties?)`

Creates an in-memory temporary stash (kind `temporary`). It is not saved unless `persistence.persistTemporary` is on. Alias `createTemporaryStash`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `properties?` | table | `id`, `label`, `slots`, `maxWeight`, `items`, `coords`, `distance`, `groups`, `owner`, `access`. `temporary` is forced true. |

**Returns**

- **inventoryKey** — `temporary:<id>`.

**Example**

```lua
local key = exports.kora_inventory:CreateTemporaryStash({ id = 'heist-bag-' .. src, label = 'Heist Bag', slots = 10, maxWeight = 25000, owner = src })
exports.kora_inventory:OpenInventory(src, 'heist-bag-' .. src, { type = 'temporary', id = 'heist-bag-' .. src })
```

**Representative console output**

```text
Returns 'temporary:heist-bag-12'. Only player 12 can open it (`owner = src`).
```

### `exports.kora_inventory:RegisterStashPolicy(id, options, callback)`

Registers a persisted, resource-owned stash: its size, location and ownership options are saved with it, while access is decided by your callback. The stash is denied while the owning resource is stopped. Requires persistence to be ready. Alias `registerStashPolicy`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | string | Stash id, 1 to 128 characters. |
| `options` | table | `label`, `slots` (1 to 10000), `maxWeight`, `coords`, `distance`, `groups`, `owner`. |
| `callback` | function | `callback(source, inventory, opts, ctx)`; return a truthy value to allow. |

**Returns**

- **registered** — true on success.
- **key / reason** — the stash key, or `stash id, options and callable policy are required`, `inventory persistence unavailable`, `invalid stash slots`, `invalid stash weight`, `invalid stash coordinates`, `invalid stash distance`, `stash identifier collides with existing storage`, `stash policy belongs to another resource`, `inventory recovery is being reconciled`.

**Example**

```lua
local ok, key = exports.kora_inventory:RegisterStashPolicy('house:42', {
    label = 'House 42', slots = 40, maxWeight = 150000, coords = vector3(120.0, 450.0, 30.0), distance = 2.0,
}, function(source, inventory)
    return exports.myhousing:hasKey(source, 42)
end)
```

**Representative console output**

```text
ok = true, key = 'stash:house:42'. Players with the house key can open it; sessions already open on it are closed.
```

### `exports.kora_inventory:RebindStashPolicy(id, callback)`

Re-attaches a callback to a persisted stash policy after a restart, without rewriting its stored options. Only the resource that registered the policy may rebind it. Alias `rebindStashPolicy`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | string | Stash id. |
| `callback` | function | Access callback. |

**Returns**

- **rebound** — true, with the key as the second value; or false and `persisted stash policy is not owned by this resource`.

**Example**

```lua
AddEventHandler('onResourceStart', function(name)
    if name ~= GetCurrentResourceName() then return end
    exports.kora_inventory:RebindStashPolicy('house:42', canOpenHouse42)
end)
```

**Representative console output**

```text
true, 'stash:house:42'. Sessions open on that stash are closed with reason `stash policy rebound`.
```

### `exports.kora_inventory:UnregisterStashPolicy(id)`

Removes the callback from a stash you own and marks it as requiring a policy, so it can no longer be opened until the policy is registered or rebound. Contents are untouched. Alias `unregisterStashPolicy`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | string | Stash id. |

**Returns**

- **unregistered** — true, or false and `stash policy is not owned by this resource`.

**Example**

```lua
exports.kora_inventory:UnregisterStashPolicy('house:42')
```

**Representative console output**

```text
true. Open sessions close with `stash policy unavailable`.
```

### `exports.kora_inventory:SetStashBlocked(id, blocked)`

Persists a blocked flag on a policy-owned stash. A blocked stash cannot be opened or changed and open sessions are closed. Alias `setStashBlocked`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | string | Stash id. |
| `blocked` | boolean | True to block, false to unblock. A non-boolean is rejected. |

**Returns**

- **updated** — true on success, otherwise false with `stash policy is not owned by this resource`, `inventory recovery is being reconciled` or a save error.

**Example**

```lua
-- evict the tenant: lock the storage until the new owner is verified
exports.kora_inventory:SetStashBlocked('house:42', true)
```

**Representative console output**

```text
true. The stash answers `inventory is locked` to every open until unblocked.
```

### `exports.kora_inventory:ClaimStash(source, id, operationKey)`

Moves the entire contents of a policy-owned stash into a player's inventory in one durable, idempotent operation (a fenced SQL transaction with a receipt). Use it to hand a tenant their belongings when a property is released. Retrying with the same key never pays out twice. Alias `claimStash`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Player server id receiving the items. |
| `id` | string | Stash id; the calling resource must own its policy. |
| `operationKey` | string | Your idempotency key, 1 to 128 characters, unique per claim. |

**Returns**

- **claimed** — true with a receipt `{ operationKey, stashId, citizenid, amount, completedAt }`, or false with a message.
- **message** — `Invalid recovery request.`, `Inventory persistence is unavailable.`, `Recovery is unavailable.`, `Recovery key has different arguments.`, `Recovery storage is empty.`, `Your character changed. Try again.`, `The recovery receipt requires repair.`, `Recovery outcome is pending. Retry the same claim.`, or a capacity error such as `over weight`.

**Example**

```lua
local ok, result = exports.kora_inventory:ClaimStash(src, 'house:42', ('release-42-%s'):format(citizenid))
if ok then
    print(('returned %d items'):format(result.amount))
else
    print('claim failed:', result) -- retry with the SAME key if the message says pending
end
```

**Representative console output**

```text
true, { operationKey = 'release-42-ABC123', stashId = 'house:42', citizenid = 'ABC123', amount = 14, completedAt = 1767225600 }
```

## Common use cases

- Job lockers and armouries restricted by grade and location.
- Per-citizen apartment or locker storage.
- Business or house storage controlled by the owning resource.
- Temporary containers for heists or deliveries.

## Limits and related APIs

A stash returned by `GetStashItems` is created if missing, so validate ids. `groups` values must be numeric grades. The policy helpers need persistence to be ready and enabled, and only the registering resource may change or recover a policy-owned stash. Access callbacks receive the live inventory record, so do not mutate it. A stash opened with `RegisterStash` only (no coords/groups/owner/access) can be opened by any player who asks for its key.

## Related guides

- [Opening inventories](./inventories.md)
- [Persistence](./persistence.md)
- [Containers and evidence](./containers.md)
- [Events and callbacks](./events.md)

## Operating notes (from the code)

Facts below were written from the current code of this resource; they add to, and where noted refine, the reference above.

### Stashes

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

#### Resource-owned policy stashes

`registerStashPolicy(id, options, callback)` returns `true, inventoryKey` or `false, error`. Options: `label`, `slots`, `maxWeight`, `owner`, `groups`, `coords`, `distance`. The callback receives `(source, inventory, options)` and must return `true`; every transfer checks it again. The registering resource owns the policy; a stopped or missing provider denies access. Registration persists a required-policy marker before opening access and closes existing sessions. A fourth callback argument is trusted context; only `ClaimStash` sets `{ recovery = true }`.

- `rebindStashPolicy(id, callback)` replaces the callback of an already persisted policy for its owner without saving contents or capacity.
- `unregisterStashPolicy(id)` closes access and keeps the required marker.
- `setStashBlocked(id, blocked)` returns `true` only after the stash lock is held and the block is durably saved; a busy stash returns `false, error`, so retry before checking emptiness. It closes sessions and survives restarts.
- `ClaimStash(source, id, operationKey)` moves all items to the player and returns `true, receipt` or `false, error`. The stash, `players.inventory` and an operation receipt are committed in one checked SQL transaction, coordinated with kora_core's persistence fence. Reuse the same key after an uncertain result: a completed key returns its original receipt, and a clean capacity rejection may be retried after making room. Receipts are stored in `kora_inventory_recovery_operations`.

### Temporary stashes

`createTemporaryStash(properties)` returns an inventory key; use it with `openInventory`. Temporary stashes are only persisted when `persistence.persistTemporary` is true.
