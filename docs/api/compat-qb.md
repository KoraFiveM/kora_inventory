---
title: "qb-inventory compat"
sidebar_position: 21
---


# qb-inventory compat

## Server

kora_inventory provides the `qb-inventory` identity so unmodified qb-inventory dependants keep working. It publishes its own export table under that name (separate from the native `exports.kora_inventory` table) with upstream return shapes, plus the upstream net events and QBCore callbacks, all routed onto the same validated engine. Where upstream trusted the client, the compat layer takes a slot or an amount from the client at most and re-reads everything else on the server.

Namespace: `exports['qb-inventory']` · Source: `server/compat/qb.lua, qb_hooks.lua, qb_events.lua, qb_callbacks.lua, server/compat/providers.lua`

### How it works

Each export is built by `server/compat/qb.lua` and registered by `providers.lua` through `Kora.compat.provideExport('qb-inventory', name, fn)`. Identifier arguments are flexible: a number is a player server id; a string names a stash, trunk, glovebox, drop or temporary inventory, optionally with the upstream prefixes `trunk-<id>`, `glovebox-<id>` and `drop-<id>` (honoured only when the resolved inventory really is that kind, so `trunk-player:7` can never reach a player). Hooks (`AddHook`, `AddListener`) subscribe lazily to the ox-style dispatcher and translate payloads to upstream shapes. Registration fails with an error at startup if a real `qb-inventory`, `ox_inventory` or `qb-weapons` resource is running.

### Differences to keep in mind

1. **Different return shapes** — `GetInventory(identifier)` returns an inventory descriptor here, while `exports.kora_inventory:GetInventory(src)` returns a player's items table.
2. **Slot or source arguments** — Item readers take a player source; `GetSlotsByItem`, `GetFirstSlotByItem` and `GetTotalWeight` take an items table, as upstream.
3. **Hooks are separate** — `AddHook` / `AddListener` use their own registries; they are not the ox-style `RegisterHook`.

### Terms used on this page

| Term | Meaning |
| --- | --- |
| Identifier | A player source (number) or an inventory id string, with optional `trunk-`, `glovebox-` or `drop-` prefix. |
| Hook vs listener | A hook runs before the action and cancels it by returning false; a listener runs after it commits. |
| Compat identity | The `exports[...]` name provided by `provide`; separate table from the native exports. |

### qb hook and listener events

Events accepted by `AddHook` and `AddListener`. Callbacks receive `(subtype, data)`. The payloads are detached copies, so a hook can veto an action but cannot reach live inventory state.

| Option | Type | Description |
| --- | --- | --- |
| `ItemMoved` | event | subtype `moved`, `stacked`, `swapped`, `split` or `given`; data `{ fromType, toType, fromInventory, toInventory, fromId, toId, fromSlot, toSlot, amount }`. Fired by UI transfers and gives. |
| `ItemDropped` | event | subtype is the item type; data `{ source, sourceInventory, coords, item, amount }`. |
| `ItemUsed` | event | subtype is the item type; data `{ source, sourceInventory, item }`. |
| `ItemBought` | event | subtype is the shop type; data `{ shopType, shop, toId, item, amount, totalPrice }`. |
| `ItemAdded / ItemRemoved` | event | Raised only by the compat `AddItem` / `RemoveItem` wrappers (never by internal moves). data `{ item, amount, reason, resource, toId\|fromId, toInventory\|fromInventory, toType\|fromType, toSlot\|fromSlot }`. An `ItemAdded` hook may return a table to replace the metadata. |
| `InventoryOpened` | event | subtype is the inventory type; data `{ source, sourceInventory, inventoryId, inventory }`. |
| `ShopOpened` | event | subtype is the shop type; data `{ source, sourceInventory, shop }`. |

### Functions

Call these as `exports['qb-inventory']:Name(...)`. Names not listed here (for example `GetStashItems`) exist only on the native identity. A few names also exist natively with different shapes (`GetInventory`, `CanAddItem`, `SetInventory`, `HasItem`).

#### `exports['qb-inventory']:AddItem(identifier, item, amount?, slot?, info?, reason?, isInternalMove?)`

Adds an item to a player or to a stash, trunk, glovebox, drop or temporary inventory. Runs the `ItemAdded` hook first (skipped when `isInternalMove`), then the usual capacity, weapon-metadata and `createItem` checks. Returns a plain boolean like upstream, with the reason as a second value.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `identifier` | integer \| string | Player source or inventory id. |
| `item` | string | Item name. |
| `amount?` | integer | Default 1. Secondary inventories require a positive whole number. |
| `slot?` | integer | Preferred slot. |
| `info?` | table | Metadata. |
| `reason?` | string | Audit text. |
| `isInternalMove?` | boolean | Skip the hook. |

**Returns**

- **added** — boolean.
- **reason** — `invalid item`, `invalid item or amount`, `inventory not found` (also for shops, containers and evidence), `cancelled by hook`, `unknown item`, `over weight`, `no free slot`.

**Example**

```lua
local ok, why = exports['qb-inventory']:AddItem('stash-lockers', 'lockpick', 2, nil, { note = 'spare' }, 'restock')
```

**Representative console output**

```text
ok = true
```

#### `exports['qb-inventory']:RemoveItem(identifier, item, amount, slot?, reason?, isInternalMove?)`

Removes an item. With no slot the matching slots are drained lowest first and the removal is refused up front if there is not enough, which accepts more successful calls than upstream (upstream needs the first slot alone to hold enough).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `identifier` | integer \| string | Player source or inventory id. |
| `item` | string | Item name. |
| `amount` | integer | Amount (required). |
| `slot?` | integer | Slot to remove from. |
| `reason?` | string | Audit text. |
| `isInternalMove?` | boolean | Skip the hook. |

**Returns**

- **removed** — boolean.
- **reason** — `invalid item`, `invalid amount`, `inventory not found`, `item not in slot`, `not enough of item`, `cancelled by hook`.

**Example**

```lua
exports['qb-inventory']:RemoveItem(src, 'water_bottle', 1)
```

**Representative console output**

```text
true
```

#### `exports['qb-inventory']:GetSlotsByItem(items, itemName)`

Returns the sorted slot numbers in an items table that hold an item.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `items` | table | Slot-keyed items table. |
| `itemName` | string | Item name. |

**Returns**

- **slots** — number[] (empty when none).

**Example**

```lua
local slots = exports['qb-inventory']:GetSlotsByItem(items, 'lockpick')
```

**Representative console output**

```text
{ 3, 9 }
```

#### `exports['qb-inventory']:GetFirstSlotByItem(items, itemName)`

Returns the lowest slot holding an item in an items table.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `items` | table | Slot-keyed items table. |
| `itemName` | string | Item name. |

**Returns**

- **slot** — integer or nil.

**Example**

```lua
local slot = exports['qb-inventory']:GetFirstSlotByItem(items, 'lockpick')
```

**Representative console output**

```text
3
```

#### `exports['qb-inventory']:GetTotalWeight(items)`

Total weight in grams of an items table, using effective item weights.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `items` | table | Slot-keyed items table. |

**Returns**

- **weight** — number.

**Example**

```lua
local grams = exports['qb-inventory']:GetTotalWeight(items)
```

**Representative console output**

```text
3560
```

#### `exports['qb-inventory']:GetSlots(identifier)`

Used and free slot counts of an inventory.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `identifier` | integer \| string | Player source or inventory id. |

**Returns**

- **used** — number of occupied slots (0 when unknown).
- **free** — free slots, or nil when the inventory is unknown.

**Example**

```lua
local used, free = exports['qb-inventory']:GetSlots('stash-lockers')
```

**Representative console output**

```text
4, 16
```

#### `exports['qb-inventory']:SetItemData(identifier, itemName, key, value, slot?)`

Sets an arbitrary field on an item instance (for example `info` or `quality`). Definition-owned fields such as `name`, `amount`, `weight`, `type`, `unique`, `label` and `useable` are refused. Applied through a locked, validated replace.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `identifier` | integer \| string | Player source or inventory id. |
| `itemName` | string | Item name. |
| `key` | string | Field name. |
| `value` | any | New value. |
| `slot?` | integer | Slot; default the first matching slot. |

**Returns**

- **result** — true on success; false for a refused key, missing item or failed write; nil when the inventory does not resolve.

**Example**

```lua
exports['qb-inventory']:SetItemData(src, 'phone', 'info', { handsetId = 'abc' })
```

**Representative console output**

```text
true
```

#### `exports['qb-inventory']:ClearStash(identifier)`

Empties a stash.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `identifier` | string | Stash id. |

**Returns**

- **No return value.**

**Example**

```lua
exports['qb-inventory']:ClearStash('policetrash')
```

**Representative console output**

```text
The stash is empty; viewers are patched.
```

#### `exports['qb-inventory']:CreateInventory(identifier, data?)`

Creates a stash, or updates label, slots and weight of an existing plain stash (never one controlled by a stash policy).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `identifier` | string | Stash id. |
| `data?` | table | `label`, `slots`, `maxWeight`, `items` (or `inventory`), `coords`, `owner`, `groups`. |

**Returns**

- **No return value.**

**Example**

```lua
exports['qb-inventory']:CreateInventory('crate-1', { label = 'Crate', slots = 10, maxWeight = 20000 })
```

**Representative console output**

```text
The stash exists.
```

#### `exports['qb-inventory']:RemoveInventory(identifier)`

Deletes a non-player secondary inventory from memory and from the database.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `identifier` | string | Inventory id. |

**Returns**

- **removed** — true, or false with a storage error; nil when it does not exist or is a player.

**Example**

```lua
exports['qb-inventory']:RemoveInventory('crate-1')
```

**Representative console output**

```text
true
```

#### `exports['qb-inventory']:AddToStash(stashId, item, amount, slot?, info?)`

Adds to a stash only (other kinds answer `inventory not found`).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `stashId` | string | Stash id. |
| `item` | string | Item name. |
| `amount` | integer | Amount. |
| `slot?` | integer | Slot. |
| `info?` | table | Metadata. |

**Returns**

- **added** — boolean.
- **reason** — as `AddItem`.

**Example**

```lua
exports['qb-inventory']:AddToStash('pd_armoury', 'weapon_pistol', 1)
```

**Representative console output**

```text
true
```

#### `exports['qb-inventory']:RemoveFromStash(stashId, item, amount, slot?)`

Removes from a stash only. Refused up front if the stash lacks enough.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `stashId` | string | Stash id. |
| `item` | string | Item name. |
| `amount` | integer | Amount. |
| `slot?` | integer | Slot. |

**Returns**

- **removed** — boolean.
- **reason** — `invalid item or amount`, `inventory not found`, `item not in slot`, `not enough of item`.

**Example**

```lua
exports['qb-inventory']:RemoveFromStash('pd_armoury', 'weapon_pistol', 1)
```

**Representative console output**

```text
true
```

#### `exports['qb-inventory']:LoadInventory(source, citizenid)`

Returns a detached slot-keyed items table: the online player's live items, or, for an offline `citizenid`, the data read through kora_core.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Player source (or any number when offline). |
| `citizenid` | string | Citizen id for the offline lookup. |

**Returns**

- **items** — table (empty when nothing is found).

**Example**

```lua
local items = exports['qb-inventory']:LoadInventory(src, citizenid)
```

**Representative console output**

```text
{ [1] = { name = 'phone', ... } }
```

#### `exports['qb-inventory']:SaveInventory(source, offline?)`

Asks kora_core to save a player's items (and flushes the players table). With `offline = true`, `source` is a table `{ citizenid, items }` saved as an offline player. Player persistence stays in kora_core.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer \| table | Player source, or the offline table. |
| `offline?` | boolean | True for an offline snapshot. |

**Returns**

- **No return value on success; `false, reason` when saving or flushing fails.**

**Example**

```lua
exports['qb-inventory']:SaveInventory(src)
```

**Representative console output**

```text
nil (success)
```

#### `exports['qb-inventory']:SetInventory(identifier, items, reason?)`

Replaces the contents of a player (validated, like the native `SetInventory`) or of any secondary inventory (through the locked write funnel).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `identifier` | integer \| string | Player source or inventory id. |
| `items` | table | Slot-keyed rows. |
| `reason?` | string | Ignored. |

**Returns**

- **result** — true on success; false when the inventory does not exist or validation fails.

**Example**

```lua
exports['qb-inventory']:SetInventory('crate-1', { [1] = { name = 'water_bottle', amount = 3 } })
```

**Representative console output**

```text
true
```

#### `exports['qb-inventory']:UseItem(itemName, source, item?)`

Uses an item. Accepts upstream's `(itemName, source, itemData)` and kora's earlier `(source, itemOrSlot)` form. The slot comes from `itemData.slot` when given; otherwise the item name selects the first stack.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `itemName` | string \| integer | Item name (upstream form) or player source (kora form). |
| `source` | integer \| any | Player source (upstream form) or slot/item table (kora form). |
| `item?` | table | Upstream item data; only `slot` is read. |

**Returns**

- **used** — boolean.
- **reason** — as `useItem`, or `UseItem requires a player source`.

**Example**

```lua
exports['qb-inventory']:UseItem('sandwich', src)
```

**Representative console output**

```text
true
```

#### `exports['qb-inventory']:OpenInventoryById(source, target)`

Opens another player's inventory for `source` through the full access check: distance, routing bucket and the inspection policy still apply.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Viewer. |
| `target` | integer | Player whose inventory is opened. |

**Returns**

- **opened** — boolean.
- **result** — payload or `player not found`, `too far away`, `player inspection not authorised`, `player inspection denied`.

**Example**

```lua
exports['qb-inventory']:OpenInventoryById(officer, suspect)
```

**Representative console output**

```text
false, 'player inspection not authorised' unless an inspection policy allows it.
```

#### `exports['qb-inventory']:CreateShop(shopData)`

Registers a shop from one table (upstream form) or a collection of shops keyed by name; the older `(name, data)` form is also accepted. Slot count is derived from the stock when not given.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `shopData` | table \| string | A table with `name`, `label`, `items` (or `inventory`), `coords`, ... or a collection, or a shop name when used with the second argument. |

**Returns**

- **key** — `shop:<name>` of the last registered shop, or nil with a reason.

**Example**

```lua
exports['qb-inventory']:CreateShop({ name = 'tools', label = 'Tools', slots = 4, coords = vec3(1, 2, 3), items = { { name = 'lockpick', amount = 10, price = 100 } } })
```

**Representative console output**

```text
shop:tools
```

#### `exports['qb-inventory']:OpenShop(source, name)`

Opens a registered shop for a player (through `OpenInventory` with `type = 'shop'`).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Player. |
| `name` | string | Shop name. |

**Returns**

- **opened** — boolean.
- **result** — payload or reason.

**Example**

```lua
exports['qb-inventory']:OpenShop(src, 'tools')
```

**Representative console output**

```text
true
```

#### `exports['qb-inventory']:OpenInventory(source, identifier?, data?)`

Opens the player's own inventory (nil identifier), an existing trunk, glovebox or drop by prefixed identifier through the full access check, or a stash (created on demand by this trusted call).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Player. |
| `identifier?` | string | Inventory id. |
| `data?` | table | Stash options. |

**Returns**

- **opened** — boolean.
- **result** — payload or `invalid inventory identifier` / an access reason.

**Example**

```lua
exports['qb-inventory']:OpenInventory(src, 'stash-lockers', { label = 'Lockers', slots = 20, maxWeight = 100000 })
```

**Representative console output**

```text
true
```

#### `exports['qb-inventory']:CloseInventory(source, identifier?)`

Closes the player's session. The identifier is advisory because sessions are keyed by player.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Player. |
| `identifier?` | string | Ignored. |

**Returns**

- **closed** — boolean.

**Example**

```lua
exports['qb-inventory']:CloseInventory(src)
```

**Representative console output**

```text
true
```

#### `exports['qb-inventory']:GetInventory(identifier)`

Returns a detached descriptor of an inventory (not just its items), so another resource cannot mutate live state.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `identifier` | integer \| string | Player source or inventory id. |

**Returns**

- **inventory** — `{ id, identifier, key, label, slots, maxweight, maxWeight, isOpen, items }` (`isOpen` is the viewing player's source or false), or nil.

**Example**

```lua
local inv = exports['qb-inventory']:GetInventory('stash-lockers')
if inv then print(inv.label, inv.slots, inv.maxweight) end
```

**Representative console output**

```text
Lockers 20 100000
```

#### `exports['qb-inventory']:GetItemBySlot(source, slot)`

Item in a player's slot, or nil (also nil for an unknown player).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Player. |
| `slot` | integer | Slot. |

**Returns**

- **item** — table or nil.

**Example**

```lua
local item = exports['qb-inventory']:GetItemBySlot(src, 1)
```

**Representative console output**

```text
item table
```

#### `exports['qb-inventory']:GetItemByName(source, item)`

First stack of an item for a player, or nil.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Player. |
| `item` | string | Item name. |

**Returns**

- **item** — table or nil.

**Example**

```lua
local phone = exports['qb-inventory']:GetItemByName(src, 'phone')
```

**Representative console output**

```text
item table
```

#### `exports['qb-inventory']:GetItemsByName(source, item)`

All stacks of an item. Returns nil (not an empty list) for an unknown player.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Player. |
| `item` | string | Item name. |

**Returns**

- **items** — array or nil.

**Example**

```lua
local stacks = exports['qb-inventory']:GetItemsByName(src, 'lockpick')
```

**Representative console output**

```text
{ ... }
```

#### `exports['qb-inventory']:GetItemCount(source, items)`

Total count of one name or a list of names. Returns nil for an unknown player.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Player. |
| `items` | string \| string[] | Name(s). |

**Returns**

- **count** — number or nil.

**Example**

```lua
local n = exports['qb-inventory']:GetItemCount(src, 'water_bottle')
```

**Representative console output**

```text
4
```

#### `exports['qb-inventory']:GetFreeWeight(source)`

Free weight in grams. Returns 0 for an unknown player (the native export would report the full maximum).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Player. |

**Returns**

- **free** — number.

**Example**

```lua
local free = exports['qb-inventory']:GetFreeWeight(src)
```

**Representative console output**

```text
107600
```

#### `exports['qb-inventory']:HasItem(source, items, amount?)`

Checks possession. A string goes to the native check. Tables follow upstream: an explicit `amount` applies to every entry and overrides the per-name counts of the map form; an array with no `amount` only needs each item present; an empty table is false. Counts are summed across slots.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Player. |
| `items` | string \| string[] \| table&lt;string, number> | Name(s). |
| `amount?` | integer | Required count. |

**Returns**

- **hasItems** — boolean.

**Example**

```lua
if exports['qb-inventory']:HasItem(src, { 'lockpick', 'screwdriver' }, 1) then end
```

**Representative console output**

```text
true
```

#### `exports['qb-inventory']:CanAddItem(identifier, item, amount?)`

Capacity check for a player or any inventory identifier. Reports exactly `weight` or `slots` as the reason; any other failure is a bare false.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `identifier` | integer \| string | Player source or inventory id. |
| `item` | string | Item name. |
| `amount?` | integer | Default 1. |

**Returns**

- **canAdd** — boolean.
- **reason** — `weight` or `slots` when it does not fit.

**Example**

```lua
local ok, reason = exports['qb-inventory']:CanAddItem(src, 'weapon_pistol', 1)
```

**Representative console output**

```text
false, 'slots'
```

#### `exports['qb-inventory']:ClearInventory(source, keep?)`

Clears a player's inventory except named items (same as the native export).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Player. |
| `keep?` | string \| string[] | Items to keep. |

**Returns**

- **cleared** — boolean.

**Example**

```lua
exports['qb-inventory']:ClearInventory(src, { 'phone' })
```

**Representative console output**

```text
true
```

#### `exports['qb-inventory']:AddHook(eventName, callback)`

Registers a pre-action hook for a qb event (see the events table). Return false to cancel. Removed automatically when the registering resource stops.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `eventName` | string | One of `ItemMoved`, `ItemDropped`, `ItemUsed`, `ItemBought`, `ItemAdded`, `ItemRemoved`, `InventoryOpened`, `ShopOpened`. |
| `callback` | function | `callback(subtype, data)`. |

**Returns**

- **index** — integer for `RemoveHook`; nil for an invalid event or callback.

**Example**

```lua
local index = exports['qb-inventory']:AddHook('ItemBought', function(shopType, data)
    if shopType == 'ammunation' and not hasLicence(data.toId) then return false end
end)
```

**Representative console output**

```text
1
```

#### `exports['qb-inventory']:RemoveHook(eventName, index)`

Removes a hook by the index returned from `AddHook`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `eventName` | string | Event name. |
| `index` | integer | Index. |

**Returns**

- **No return value.**

**Example**

```lua
exports['qb-inventory']:RemoveHook('ItemBought', index)
```

**Representative console output**

```text
The hook no longer runs.
```

#### `exports['qb-inventory']:AddListener(eventName, callback)`

Registers a post-action listener that runs after the action committed.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `eventName` | string | Event name. |
| `callback` | function | `callback(subtype, data)`. |

**Returns**

- **index** — integer for `RemoveListener`.

**Example**

```lua
exports['qb-inventory']:AddListener('ItemMoved', function(kind, data) log(kind, data.amount) end)
```

**Representative console output**

```text
1
```

#### `exports['qb-inventory']:RemoveListener(eventName, index)`

Removes a listener.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `eventName` | string | Event name. |
| `index` | integer | Index. |

**Returns**

- **No return value.**

**Example**

```lua
exports['qb-inventory']:RemoveListener('ItemMoved', index)
```

**Representative console output**

```text
The listener no longer runs.
```

#### `RegisterNetEvent('qb-inventory:server:SetInventoryData', function(fromInventory, toInventory, fromSlot, toSlot, fromAmount, toAmount) end)`

Upstream's move/split/swap event. Translated onto the validated transfer: only the two inventories of the caller's own session can be named, and the token and current revisions are supplied by the server.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `fromInventory` | string | `player`, `otherplayer-<id>`, or the secondary's id (with optional `drop-` / `shop-` prefix). |
| `toInventory` | string | Same forms. |
| `fromSlot` | integer | Source slot. |
| `toSlot` | integer | Target slot. |
| `fromAmount` | integer | Amount. |
| `toAmount` | integer | Ignored. |

**Returns**

- **No return value. A refusal arrives as `kora_inventory:client:rejected`.**

**Example**

```lua
-- client
TriggerServerEvent('qb-inventory:server:SetInventoryData', 'player', 'stash-lockers', 3, 1, 2, 0)
```

**Representative console output**

```text
Two items move into slot 1 of the open stash.
```

#### `RegisterNetEvent('qb-inventory:server:useItem', function(item) end)`

Uses the item in the slot named by `item.slot` (or the number passed). Name and metadata are re-read on the server.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `item` | table \| integer | `{ slot }` or a slot number. |

**Returns**

- **No return value.**

**Example**

```lua
TriggerServerEvent('qb-inventory:server:useItem', { slot = 2 })
```

**Representative console output**

```text
The item is used.
```

#### `RegisterNetEvent('qb-inventory:server:UseItem', function(inventoryName, item) end)`

qb-inventory 1.x use event. Accepts `(inventoryName, item)` or `(item)`; only the slot is read.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inventoryName` | string \| table | Ignored when two arguments are given. |
| `item` | table \| integer | Item or slot. |

**Returns**

- **No return value.**

**Example**

```lua
TriggerServerEvent('inventory:server:UseItem', 'player', { slot = 2 })
```

**Representative console output**

```text
The item is used.
```

#### `RegisterNetEvent('qb-inventory:server:openDrop', function(dropId) end)`

Opens a drop by id (a `drop-` prefix is stripped) through the normal access, distance and bucket checks.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `dropId` | string \| integer | Drop id. |

**Returns**

- **No return value.**

**Example**

```lua
TriggerServerEvent('qb-inventory:server:openDrop', 'drop-7')
```

**Representative console output**

```text
Drop 7 opens if reachable.
```

#### `RegisterNetEvent('qb-inventory:server:openVending', function() end)`

Opens the `vending` shop through `OpenInventory`. Note the bundled vending machine shop is registered as `vendingmachine` and requires client coordinates, so this legacy event only opens a shop with the id `vending` if one exists.

**Parameters**



**Returns**

- **No return value.**

**Example**

```lua
TriggerServerEvent('qb-inventory:server:openVending')
```

**Representative console output**

```text
Opens a shop named `vending` if registered; otherwise nothing.
```

#### `RegisterNetEvent('qb-inventory:server:OpenInventory', function(invType, id) end)`

qb-inventory 1.x open event. Only `stash`, `shop`, `drop`, `player` and `otherplayer` are accepted, ids are validated (`^[%w_%-:]+$`, at most 96 characters), and only inventories that already exist on the server can be opened; the client-supplied capacity or stock argument is never read. Trunks and gloveboxes are refused because a plate is not a network id.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `invType` | string | Type name. |
| `id` | string \| integer | Id. |

**Returns**

- **No return value. Refusals arrive as `kora_inventory:client:rejected`.**

**Example**

```lua
TriggerServerEvent('inventory:server:OpenInventory', 'stash', 'pd_armoury')
```

**Representative console output**

```text
The stash opens if it exists and access passes.
```

#### `RegisterNetEvent('qb-inventory:server:closeInventory', function() end)`

Closes the caller's session.

**Parameters**



**Returns**

- **No return value.**

**Example**

```lua
TriggerServerEvent('qb-inventory:server:closeInventory')
```

**Representative console output**

```text
The session closes.
```

#### `RegisterNetEvent('qb-inventory:server:updateDrop', function() end)`

Accepted but deliberately inert: `updateDrop` would let a client write drop coordinates, `snowball` would grant a weapon on a client event, and `SetIsOpenState` (also `inventory:server:SetIsOpenState`) would let a client flip open state. Registering the names stops stock clients erroring.

**Parameters**



**Returns**

- **No return value.**

**Example**

```lua
-- no effect
```

**Representative console output**

```text
Nothing happens.
```

#### `Kora.callback.trigger('qb-inventory:server:GetCurrentDrops')`

Positional metadata of drops created by the compat drop callback, in the caller's routing bucket. Contents are never included. `entityId` is always 0 (the bag prop is local to each client).

**Parameters**



**Returns**

- **drops** — map `id -> { name, label, entityId, coords, createdTime, maxweight, slots }`.

**Example**

```lua
local drops = Kora.callback.trigger('qb-inventory:server:GetCurrentDrops')
```

**Representative console output**

```text
{ ['7'] = { name = 'drop-7', coords = ..., entityId = 0 } }
```

#### `Kora.callback.trigger('qb-inventory:server:createDrop', item)`

Drops from the caller's own inventory. Only the slot (`fromSlot` or `slot`) and an amount are read; the dropped record is a copy of what is really in that slot and the position is the player's ped.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `item` | table | `{ fromSlot \| slot, amount?, inventory? }`; `inventory` must be the session's primary. |

**Returns**

- **dropId** — the drop id, or false (the reason is sent as `kora_inventory:client:rejected`).

**Example**

```lua
local id = Kora.callback.trigger('qb-inventory:server:createDrop', { fromSlot = 4, amount = 1 })
```

**Representative console output**

```text
7
```

#### `Kora.callback.trigger('qb-inventory:server:attemptPurchase', data)`

Buys from a shop. Only the shop id, slot and amount are read; the item name, price and payment come from the server through `BuyItem`. The shop's own distance replaces upstream's hard-coded 10.0.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `data` | table | `{ shop (id or table, optional `shop-` prefix), item = { slot }, amount }`. |

**Returns**

- **purchased** — boolean.

**Example**

```lua
local ok = Kora.callback.trigger('qb-inventory:server:attemptPurchase', { shop = 'shop-hardware', item = { slot = 1 }, amount = 2 })
```

**Representative console output**

```text
true
```

#### `Kora.callback.trigger('qb-inventory:server:giveItem', target, item, amount, slot, info)`

Gives items to a nearby player. Requires an open session. Both players must not be dead, downed or cuffed, in the same bucket and within `interactionDistance`. The item metadata always comes from the source item (the `info` argument is ignored); the item is removed first and rolled back if the recipient cannot receive it.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `target` | integer | Recipient server id. |
| `item` | string | Fallback item name when no slot is given. |
| `amount` | integer | Amount. |
| `slot` | integer | Source slot. |
| `info` | table | Ignored. |

**Returns**

- **given** — boolean (the reason is sent as `kora_inventory:client:rejected`).

**Example**

```lua
local ok = Kora.callback.trigger('qb-inventory:server:giveItem', 14, 'lockpick', 1, 3)
```

**Representative console output**

```text
true
```

### Common use cases

- Running unmodified qb-inventory dependants (shops, stashes, police jobs) against kora_inventory.
- Porting qb scripts gradually to the native exports.

### Limits and related APIs

Upstream globals (`Inventories`, `Drops`, `RegisteredShops`) are not exposed because a mutable global would bypass the lock, revision and broadcast funnel. `qb-inventory:server:updateDrop`, `snowball` and the open-state events are intentional no-ops. `SaveInventory` leaves player persistence to kora_core. The qb identity and the native identity are separate tables: do not assume a name behaves the same on both.

### Related guides

- [Player items](./player-items.md)
- [Hooks](./hooks.md)
- [Events and callbacks](./events.md)

## Client

The client side of the qb-inventory identity: one export published as `qb-inventory`, the upstream client events (accepted and routed to the validated transport or ignored deliberately), and the legacy commands. kora_inventory owns its UI, so most upstream presentation events are harmless no-ops.

Namespace: `exports['qb-inventory']` · Source: `client.lua, client/compat.lua`

### How it works

`client/compat.lua` translates legacy intent events only. It never renders a legacy payload or accepts a legacy item table as truth: an upstream `openInventory` call is reduced to a requested identifier that the server resolves, access-checks and snapshots. The conventional `inv_busy` state bag is kept in sync with the real session and is advisory to other scripts.

### Legacy open

1. **Legacy event arrives** — `qb-inventory:client:openInventory(items, other)` or `inventory:client:OpenInventory`.
2. **Reduced to an identifier** — The item list is ignored. `other.name` is turned into a type and id (`shop-`, `otherplayer-`, `drop-`, `trunk-`, `glovebox-` prefixes; anything else is a stash).
3. **Server decides** — The open request goes through the normal server validation.

### Terms used on this page

| Term | Meaning |
| --- | --- |
| inv_busy | A replicated state bag set to true while a session is open (cleared during a use so handler effects can add or remove items). |

### Functions

The client export is `HasItem`; `openInventory` and `closeInventory` are also published under this identity from `client.lua`.

#### `exports['qb-inventory']:HasItem(items, amount?)`

Same as `exports.kora_inventory:HasItem`: checks the local player's items. Display use only.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `items` | string \| string[] \| table&lt;string, number> | Name(s). |
| `amount?` | integer | Required count. |

**Returns**

- **hasItems** — boolean.

**Example**

```lua
if exports['qb-inventory']:HasItem('phone') then end
```

**Representative console output**

```text
true
```

#### `exports['qb-inventory']:openInventory(invType, data?)`

Same function as `exports.kora_inventory:openInventory`, published under the qb identity.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `invType` | string | Inventory type. |
| `data?` | any | Id or table. |

**Returns**

- **No return value.**

**Example**

```lua
exports['qb-inventory']:openInventory('stash', 'pd_armoury')
```

**Representative console output**

```text
Requests the stash.
```

#### `exports['qb-inventory']:closeInventory()`

Same function as `exports.kora_inventory:closeInventory`, published under the qb identity.

**Parameters**



**Returns**

- **No return value.**

**Example**

```lua
exports['qb-inventory']:closeInventory()
```

**Representative console output**

```text
Closes the session.
```

#### `RegisterNetEvent('qb-inventory:client:openInventory', function(items, other) end)`

Legacy open. Also `inventory:client:OpenInventory`. The first argument is ignored; with no `other` table it toggles the player's own inventory.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `items` | table | Ignored. |
| `other` | table \| nil | `{ name }` with an optional type prefix. |

**Returns**

- **No return value.**

**Example**

```lua
TriggerEvent('qb-inventory:client:openInventory', {}, { name = 'shop-hardware' })
```

**Representative console output**

```text
Requests shop:hardware from the server.
```

#### `RegisterNetEvent('qb-inventory:client:closeInv', function() end)`

Closes the session.

**Parameters**



**Returns**

- **No return value.**

**Example**

```lua
TriggerEvent('qb-inventory:client:closeInv')
```

**Representative console output**

```text
The inventory closes.
```

#### `RegisterNetEvent('qb-inventory:client:updateInventory', function() end)`

Deliberate no-op. The server sends it after every committed change so scripts that only know the upstream name hear about changes; an open panel is already kept current by patches, and re-opening here would close and reopen the player's session on every item change.

**Parameters**



**Returns**

- **No return value.**

**Example**

```lua
AddEventHandler('qb-inventory:client:updateInventory', function() refreshMyUi() end)
```

**Representative console output**

```text
Your handler runs after each change.
```

#### `RegisterNetEvent('qb-inventory:client:ItemBox', function(itemData, action, amount) end)`

Legacy item notice. Only the item name is trusted; label and artwork come from the registry and the `itemBoxes` policy applies. A copy the server itself emits is marked and ignored; a legacy notice for a change the server already announced is dropped.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `itemData` | table \| string | Item name or table with `name`. |
| `action` | string | `add`, `remove` or `use`. |
| `amount` | integer | Amount. |

**Returns**

- **No return value.**

**Example**

```lua
TriggerEvent('qb-inventory:client:ItemBox', { name = 'lockpick' }, 'add', 1)
```

**Representative console output**

```text
A receipt box appears unless the server already showed it.
```

#### `RegisterNetEvent('qb-inventory:client:requiredItems', function(items, show) end)`

Shows or hides a "Required: ..." text hint. Only item names are read; labels come from the registry (at most 12).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `items` | table | Names or `{ name }` rows. |
| `show` | boolean | False clears the hint. |

**Returns**

- **No return value.**

**Example**

```lua
TriggerEvent('qb-inventory:client:requiredItems', { 'lockpick', 'screwdriver' }, true)
```

**Representative console output**

```text
Text "Required: Lockpick, Screwdriver" appears at the left centre.
```

#### `RegisterNetEvent('qb-inventory:client:giveAnim', function() end)`

Plays the upstream give animation (`mp_common` / `givetake1_b`), skipped in a vehicle.

**Parameters**



**Returns**

- **No return value.**

**Example**

```lua
TriggerEvent('qb-inventory:client:giveAnim')
```

**Representative console output**

```text
The ped plays the give animation.
```

#### `RegisterNetEvent('qb-inventory:client:hotbar', function() end)`

Accepted and deliberately ignored: the hotbar is part of the UI, drop targets are managed by `client/drops.lua`, and opening another player's inventory is gated by the server inspection policy (the `RobPlayer` name is registered client-side upstream).

**Parameters**



**Returns**

- **No return value.**

**Example**

```lua
-- no effect
```

**Representative console output**

```text
Nothing happens.
```

### Common use cases

- Keeping stock qb client scripts working.
- Opening stashes, shops or other players from legacy code.

### Limits and related APIs

Legacy payloads are never authority. The `/inventory`, `/openInv` and `/closeInv` commands and the TAB binding are described under Commands. `QBCore:Client:OnPlayerLoaded` clears local busy state and `OnPlayerUnload` closes the inventory.

### Related guides

- [Client API](./client-api.md)
- [Events and callbacks](./events.md)
