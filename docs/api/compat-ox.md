---
title: "ox_inventory compat"
sidebar_position: 22
---


# ox_inventory compat

## Server

kora_inventory provides the `ox_inventory` identity so scripts written against ox_inventory's server exports keep working. Signatures and return shapes are pinned to a specific upstream commit (`test/contracts/upstream.lua`); every deliberate difference is noted where it happens. The adapter builds a table and `providers.lua` publishes it; it never touches the native `exports.kora_inventory` table.

Namespace: `exports.ox_inventory` · Source: `server/compat/ox.lua, server/compat/providers.lua`

### How it works

All reads resolve an inventory reference through the authority (`resolveInventory`), return detached copies (never live objects), and match item names against the registry (so `WATER` and `water` find the same slots; an unknown item is nil or 0, not an empty result). All writes take the inventory lock, go through the shared write funnel (player writes via kora_core), bump the revision and patch viewers. Metadata matching follows upstream: a nil or false `strict` means partial matching (the requested keys must be present), and the only exports that default to strict are `GetItemSlots` and `RemoveItem`.

### Differences from upstream worth knowing

1. **Detached snapshots** — `Inventory` / `GetInventory` return a snapshot table (no methods) because a live object would bypass the lock and revision funnel.
2. **Money** — `getCash`, `addCash`, `removeCash` use kora_core accounts; `getBank` returns nothing, `getCards` returns `{}`, `giveCard` returns false.
3. **Player sizes** — `SetSlotCount` and `SetMaxWeight` refuse player inventories (kora_core / config own them) and print a warning.
4. **Equipped weapon** — `GetCurrentWeapon` returns the first weapon item, not the drawn one; use `exports.kora_inventory:GetEquippedWeapon` for that.

### Terms used on this page

| Term | Meaning |
| --- | --- |
| Reference | Any form `resolveInventory` accepts (source number, `kind:id` key, bare id, `{ key }`, `{ type, id }`). |
| Strict matching | Metadata must equal the slot's metadata exactly. Default is partial matching, except `GetItemSlots` and `RemoveItem`. |
| ox slot table | A table with `name`, `count`, `slot`, `metadata`, `weight` ... also carrying kora's `amount` and `info`. |

### Functions

Call as `exports.ox_inventory:Name(...)`. `inv` arguments accept the reference forms shown in the first parameter. Return shapes follow ox_inventory, not the native kora exports.

#### `exports.ox_inventory:Inventory(inv, owner?)`

Alias of `GetInventory`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |
| `owner?` | string | Preferred inventory type for bare ids. |

**Returns**

- **inventory** — snapshot table or nil.

**Example**

```lua
local inv = exports.ox_inventory:Inventory(src)
```

**Representative console output**

```text
{ id = 12, type = 'player', slots = 41, maxWeight = 120000, weight = 3560, items = {...} }
```

#### `exports.ox_inventory:GetInventory(inv, owner?)`

Returns a detached snapshot `{ id, key, type, label, slots, maxWeight, weight, items }` with items in ox shape.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |
| `owner?` | string | Preferred type for a bare id. |

**Returns**

- **inventory** — table or nil.

**Example**

```lua
local inv = exports.ox_inventory:GetInventory('stash:pd_armoury')
```

**Representative console output**

```text
{ type = 'stash', slots = 60, weight = 14500, items = {...} }
```

#### `exports.ox_inventory:GetInventoryItems(inv, owner?)`

Returns the slot-keyed items in ox shape.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |
| `owner?` | string | Preferred type. |

**Returns**

- **items** — table or nil when the inventory does not resolve.

**Example**

```lua
local items = exports.ox_inventory:GetInventoryItems(src)
```

**Representative console output**

```text
{ [1] = { name = 'water_bottle', count = 2, slot = 1, ... } }
```

#### `exports.ox_inventory:GetSlot(inv, slot)`

Returns one slot in ox shape.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |
| `slot` | integer | Slot. |

**Returns**

- **slot** — table or nil.

**Example**

```lua
local slot = exports.ox_inventory:GetSlot(src, 3)
```

**Representative console output**

```text
{ name = 'lockpick', count = 4, slot = 3 }
```

#### `exports.ox_inventory:GetEmptySlot(inv)`

Lowest empty slot.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |

**Returns**

- **slot** — integer, or nil when full or unresolved.

**Example**

```lua
local free = exports.ox_inventory:GetEmptySlot(src)
```

**Representative console output**

```text
6
```

#### `exports.ox_inventory:GetSlotForItem(inv, item, metadata?)`

Slot where an item would be placed: a non-unique stack with exactly equal metadata, otherwise the first empty slot.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |
| `item` | string | Item name. |
| `metadata?` | table | Metadata for the stack match. |

**Returns**

- **slot** — integer or nil.

**Example**

```lua
local slot = exports.ox_inventory:GetSlotForItem(src, 'water_bottle')
```

**Representative console output**

```text
1
```

#### `exports.ox_inventory:GetSlotWithItem(inv, item, metadata?, strict?)`

First slot (lowest number) holding the item.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |
| `item` | string | Item name. |
| `metadata?` | table \| any | A non-table value is treated as `{ type = value }`. |
| `strict?` | boolean | Exact metadata match. |

**Returns**

- **slot** — ox slot table, or nil.

**Example**

```lua
local slot = exports.ox_inventory:GetSlotWithItem(src, 'phone')
```

**Representative console output**

```text
{ name = 'phone', slot = 14, ... }
```

#### `exports.ox_inventory:GetSlotIdWithItem(inv, item, metadata?, strict?)`

Slot number of the first match.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |
| `item` | string | Item name. |
| `metadata?` | table | Metadata. |
| `strict?` | boolean | Exact match. |

**Returns**

- **slot** — integer or nil.

**Example**

```lua
local n = exports.ox_inventory:GetSlotIdWithItem(src, 'phone')
```

**Representative console output**

```text
14
```

#### `exports.ox_inventory:GetSlotsWithItem(inv, item, metadata?, strict?)`

All matching slots in ascending order. nil for an unknown item or inventory.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |
| `item` | string | Item name. |
| `metadata?` | table | Metadata. |
| `strict?` | boolean | Exact match. |

**Returns**

- **slots** — array of ox slot tables, or nil.

**Example**

```lua
local stacks = exports.ox_inventory:GetSlotsWithItem(src, 'lockpick')
```

**Representative console output**

```text
{ { slot = 3, count = 4 }, { slot = 9, count = 1 } }
```

#### `exports.ox_inventory:GetSlotIdsWithItem(inv, item, metadata?, strict?)`

Slot numbers of all matches.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |
| `item` | string | Item name. |
| `metadata?` | table | Metadata. |
| `strict?` | boolean | Exact match. |

**Returns**

- **slots** — integer array or nil.

**Example**

```lua
local ids = exports.ox_inventory:GetSlotIdsWithItem(src, 'lockpick')
```

**Representative console output**

```text
{ 3, 9 }
```

#### `exports.ox_inventory:GetItemCount(inv, item, metadata?, strict?)`

Total count of an item across slots. Returns 0 (not nil) for an unresolved inventory or item.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |
| `item` | string | Item name. |
| `metadata?` | table | Metadata. |
| `strict?` | boolean | Exact match. |

**Returns**

- **count** — integer.

**Example**

```lua
local n = exports.ox_inventory:GetItemCount(src, 'water_bottle')
```

**Representative console output**

```text
4
```

#### `exports.ox_inventory:GetItem(inv, item, metadata?, returnsCount?)`

Returns the item definition with a `count`, or just the count.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |
| `item` | string | Item name. |
| `metadata?` | table | Metadata (partial match). |
| `returnsCount?` | boolean | True returns only the number. |

**Returns**

- **result** — definition copy with `count`, a number when `returnsCount`, or nil for an unknown item.

**Example**

```lua
local item = exports.ox_inventory:GetItem(src, 'water_bottle')
print(item.label, item.count)
```

**Representative console output**

```text
Water 4
```

#### `exports.ox_inventory:GetItemSlots(inv, item, metadata?, strict?)`

Slot to count map for an item. Defaults to strict metadata matching.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |
| `item` | string | Item name. |
| `metadata?` | table | Metadata. |
| `strict?` | boolean | Default true here. |

**Returns**

- **slots** — table `{ [slot] = count }`.
- **totalCount** — integer.
- **emptySlots** — free slots remaining.

**Example**

```lua
local slots, total, empty = exports.ox_inventory:GetItemSlots(src, 'lockpick')
```

**Representative console output**

```text
{ [3] = 4, [9] = 1 }, 5, 30
```

#### `exports.ox_inventory:Search(inv, search, items, metadata?)`

Searches an inventory. `search` is `'slots'`/1 or `'count'`/2. A single name (a string or a one-element array) returns the result directly; several names return a name-keyed table. Matching is partial. Names are lower-cased (`weapon_` prefixes are upper-cased) and the single-name result is returned under the normalised key.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |
| `search` | string \| integer | `slots`, `count`, 1 or 2. |
| `items` | string \| string[] | Item name(s). |
| `metadata?` | table | Metadata. |

**Returns**

- **result** — table, number, or false for invalid input.

**Example**

```lua
local count = exports.ox_inventory:Search(src, 'count', 'lockpick')
local both = exports.ox_inventory:Search(src, 'count', { 'lockpick', 'screwdriver' })
```

**Representative console output**

```text
4 / { lockpick = 4, screwdriver = 1 }
```

#### `exports.ox_inventory:CanCarryItem(inv, item, count?, metadata?)`

Whether the inventory can hold the item (weight and slots are checked by the authority).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |
| `item` | string | Item name. |
| `count?` | integer | Default 1. |
| `metadata?` | table | Metadata. |

**Returns**

- **canCarry** — boolean, or nil when the item or inventory cannot be resolved.

**Example**

```lua
if exports.ox_inventory:CanCarryItem(src, 'weapon_pistol', 1) then end
```

**Representative console output**

```text
true
```

#### `exports.ox_inventory:CanCarryAmount(inv, item)`

How many units of an item fit by weight, unclamped like upstream (a negative number means already overweight; zero-weight items return the integer maximum).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |
| `item` | string \| table | Item name or item table. |

**Returns**

- **amount** — integer, or nil for an unresolved inventory or item.

**Example**

```lua
local n = exports.ox_inventory:CanCarryAmount(src, 'water_bottle')
```

**Representative console output**

```text
215
```

#### `exports.ox_inventory:CanCarryWeight(inv, weight)`

Whether the free weight is at least `weight`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |
| `weight` | number | Grams. |

**Returns**

- **canCarry** — boolean, or nil.
- **available** — free weight in grams.

**Example**

```lua
local ok, free = exports.ox_inventory:CanCarryWeight(src, 5000)
```

**Representative console output**

```text
true, 107600
```

#### `exports.ox_inventory:CanSwapItem(inv, firstItem, firstCount, testItem, testCount)`

Whether giving up `firstCount` of one item would leave room for `testCount` of another, by real weight arithmetic.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |
| `firstItem` | string | Item given up. |
| `firstCount` | integer | Count given up. |
| `testItem` | string | Item to receive. |
| `testCount` | integer | Count to receive. |

**Returns**

- **canSwap** — boolean; nil when the inventory does not hold enough of the first item or an argument cannot be resolved.

**Example**

```lua
local ok = exports.ox_inventory:CanSwapItem(src, 'water_bottle', 2, 'sandwich', 3)
```

**Representative console output**

```text
true
```

#### `exports.ox_inventory:AddItem(inv, item, count, metadata?, slot?, cb?)`

Adds an item to any inventory. Runs the `createItem` hook (it may replace metadata), checks capacity, writes, and returns the resulting slot in ox shape.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |
| `item` | string | Item name. |
| `count` | integer | At least 1. |
| `metadata?` | table \| any | Non-tables become `{ type = value }`. |
| `slot?` | integer | Preferred slot. |
| `cb?` | function | Called with `(success, response)` and its return value is returned. |

**Returns**

- **success** — boolean.
- **response** — ox slot table on success; on failure `invalid_item`, `invalid_count`, `invalid_inventory`, a capacity reason from the authority (`weight`, `slots`, `item`, `inventory`), the write error, or `inventory_full` when none is given.

**Example**

```lua
local ok, slot = exports.ox_inventory:AddItem(src, 'lockpick', 2, { batch = 'A' })
```

**Representative console output**

```text
true, { name = 'lockpick', count = 2, slot = 3, ... }
```

#### `exports.ox_inventory:RemoveItem(inv, item, count, metadata?, slot?, ignoreTotal?, strict?)`

Removes an item. Defaults to strict metadata matching. The error vocabulary is upstream's.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |
| `item` | string | Item name. |
| `count` | number | Rounded; at least 1 after rounding. |
| `metadata?` | table | Metadata filter. |
| `slot?` | integer | Slot to remove from. |
| `ignoreTotal?` | boolean | Remove as much as available instead of failing. |
| `strict?` | boolean | Default true. |

**Returns**

- **success** — boolean.
- **reason** — `invalid_item`, `invalid_count`, `negative_count`, `invalid_inventory`, `no_item_in_slot`, `not_enough_items_in_slot`, `not_enough_items`, `remove_failed`.

**Example**

```lua
local ok, why = exports.ox_inventory:RemoveItem(src, 'water_bottle', 1)
```

**Representative console output**

```text
true
```

#### `exports.ox_inventory:SetItem(inv, item, count, metadata?)`

Sets the total of an item by adding or removing the difference.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |
| `item` | string | Item name. |
| `count` | integer | Target total (0 or more). |
| `metadata?` | table | Metadata. |

**Returns**

- **success** — boolean (true when already equal).
- **reason** — `invalid_item`, `invalid_count` or the add/remove error.

**Example**

```lua
exports.ox_inventory:SetItem(src, 'lockpick', 5)
```

**Representative console output**

```text
true
```

#### `exports.ox_inventory:SetMetadata(inv, slot, metadata)`

Replaces the metadata of a slot. No return value; refusals are not reported.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |
| `slot` | integer | Slot. |
| `metadata` | table \| any | New metadata. |

**Returns**

- **No return value.**

**Example**

```lua
exports.ox_inventory:SetMetadata(src, 3, { note = 'marked' })
```

**Representative console output**

```text
The slot's info and metadata are replaced.
```

#### `exports.ox_inventory:SetDurability(inv, slot, durability)`

Sets `metadata.durability` of a slot.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |
| `slot` | integer | Slot. |
| `durability` | number | New value. |

**Returns**

- **No return value.**

**Example**

```lua
exports.ox_inventory:SetDurability(src, 1, 80)
```

**Representative console output**

```text
Durability is 80.
```

#### `exports.ox_inventory:SetSlotCount(inv, slots)`

Changes the slot count of a secondary inventory; refuses players, and refuses a value below an occupied slot (a warning is printed).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |
| `slots` | integer | New slot count. |

**Returns**

- **No return value.**

**Example**

```lua
exports.ox_inventory:SetSlotCount('stash:pd_armoury', 80)
```

**Representative console output**

```text
The stash has 80 slots.
```

#### `exports.ox_inventory:SetMaxWeight(inv, maxWeight)`

Changes the weight limit of a secondary inventory; refuses players and values below the current weight.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |
| `maxWeight` | integer | Grams. |

**Returns**

- **No return value.**

**Example**

```lua
exports.ox_inventory:SetMaxWeight('stash:pd_armoury', 300000)
```

**Representative console output**

```text
The limit is 300000.
```

#### `exports.ox_inventory:GetContainerFromSlot(inv, slot)`

Returns the container bound to the item in a slot (from `metadata.container` or `metadata.containerId`), creating one sized from `metadata.size` when missing. The created container inherits the holder's owner so it is never world-readable.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |
| `slot` | integer | Slot. |

**Returns**

- **container** — snapshot or nil.

**Example**

```lua
local box = exports.ox_inventory:GetContainerFromSlot(src, 4)
```

**Representative console output**

```text
{ type = 'container', id = ..., items = {...} }
```

#### `exports.ox_inventory:RemoveInventory(inv)`

Deletes a non-player secondary inventory (memory and database).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |

**Returns**

- **No return value.**

**Example**

```lua
exports.ox_inventory:RemoveInventory('temp-1')
```

**Representative console output**

```text
The inventory is gone.
```

#### `exports.ox_inventory:SwapSlots(fromInventory, toInventory, slot1, slot2)`

Swaps two slots, within one inventory or across two, atomically with rollback.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `fromInventory` | integer \| string | First reference. |
| `toInventory` | integer \| string | Second reference. |
| `slot1` | integer | Slot in the first. |
| `slot2` | integer | Slot in the second. |

**Returns**

- **moved** — ox slot of the item now in `slot2`.
- **displaced** — ox slot of the displaced item. Or nil with `invalid_slot`, `invalid_inventory`, `swap_failed`, `inventory_update_failed`.

**Example**

```lua
local a, b = exports.ox_inventory:SwapSlots(src, src, 1, 2)
```

**Representative console output**

```text
{ slot = 2, ... }, { slot = 1, ... }
```

#### `exports.ox_inventory:ClearInventory(inv, keep?)`

Clears an inventory except named items. No return value.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |
| `keep?` | string \| string[] | Names to keep. |

**Returns**

- **No return value.**

**Example**

```lua
exports.ox_inventory:ClearInventory(src, { 'phone' })
```

**Representative console output**

```text
Everything else is removed.
```

#### `exports.ox_inventory:RegisterStash(id, label, slots, maxWeight, owner, groups, coords, instance?)`

Registers a stash (forwards to the native `RegisterStash`). `instance` is recorded on the record but not enforced as an access check.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | string | Stash id. |
| `label` | string | Label. |
| `slots` | integer | Slots. |
| `maxWeight` | integer | Grams. |
| `owner` | any | Owner or true. |
| `groups` | table | Job grades. |
| `coords` | vector3 | Location. |
| `instance?` | any | Recorded only. |

**Returns**

- **No return value.**

**Example**

```lua
exports.ox_inventory:RegisterStash('locker1', 'Locker', 20, 50000, nil, { police = 0 }, vec3(0, 0, 0))
```

**Representative console output**

```text
The stash exists.
```

#### `exports.ox_inventory:CreateTemporaryStash(properties)`

Creates a temporary stash with a collision-free id when none is given.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `properties` | table | `id`, `label`, `slots`, `maxWeight`, `items`, ... |

**Returns**

- **key** — `temporary:<id>`.

**Example**

```lua
local key = exports.ox_inventory:CreateTemporaryStash({ label = 'Bag', slots = 8, maxWeight = 20000 })
```

**Representative console output**

```text
temporary:temp-1767225600-1
```

#### `exports.ox_inventory:RegisterShop(shopType, shopDetails)`

Registers a shop through the native `RegisterShop`. Non-table details are ignored. No return value.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `shopType` | string | Shop id. |
| `shopDetails` | table | See native RegisterShop data. |

**Returns**

- **No return value.**

**Example**

```lua
exports.ox_inventory:RegisterShop('tools', { label = 'Tools', slots = 4, inventory = { { name = 'lockpick', amount = 10, price = 100 } } })
```

**Representative console output**

```text
The shop exists.
```

#### `exports.ox_inventory:CustomDrop(prefix, items, coords, slots?, maxWeight?, instance?, model?)`

Creates a temporary drop with a unique id. `instance` also becomes the routing bucket.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `prefix` | string | Label prefix. |
| `items` | table | Items. |
| `coords` | vector3 | Position. |
| `slots?` | integer | Slots. |
| `maxWeight?` | integer | Grams. |
| `instance?` | integer | Bucket. |
| `model?` | string | Recorded only. |

**Returns**

- **id** — the drop id.

**Example**

```lua
local id = exports.ox_inventory:CustomDrop('Loot', items, GetEntityCoords(ped))
```

**Representative console output**

```text
loot-1767225600-1
```

#### `exports.ox_inventory:CreateDropFromPlayer(playerId)`

Copies a player's items into a drop and clears the player in the same lock.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `playerId` | integer | Player. |

**Returns**

- **id** — drop id, or nil when the player has no items or the clear failed (the drop is then removed).

**Example**

```lua
local id = exports.ox_inventory:CreateDropFromPlayer(src)
```

**Representative console output**

```text
drop-1767225600-2
```

#### `exports.ox_inventory:GetCurrentWeapon(inv)`

Returns the first weapon-type item found. This answers "is a weapon carried?" not "which is drawn?"; use `exports.kora_inventory:GetEquippedWeapon` for that.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | integer \| string \| table | Inventory reference: a player source, an inventory key (`stash:id`), a bare id, or a table with `key` or `type` + `id`. |

**Returns**

- **weapon** — ox slot table or nil.

**Example**

```lua
local w = exports.ox_inventory:GetCurrentWeapon(src)
```

**Representative console output**

```text
{ name = 'weapon_pistol', ... }
```

#### `exports.ox_inventory:UpdateVehicle(oldPlate, newPlate)`

Renames the trunk and glovebox inventories when a plate changes, moving contents, viewers and the stored row together.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `oldPlate` | string | Old plate. |
| `newPlate` | string | New plate. |

**Returns**

- **No return value; a warning is printed if the target already exists.**

**Example**

```lua
exports.ox_inventory:UpdateVehicle('ABC 123', 'XYZ 987')
```

**Representative console output**

```text
trunk:XYZ 987 holds the old contents.
```

#### `exports.ox_inventory:InspectInventory(playerId, invId)`

Opens `invId` for the viewer `playerId` through the normal access checks. Inspecting yourself is a no-op.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `playerId` | integer | Viewer (first, as upstream). |
| `invId` | integer \| string | Inventory to open. |

**Returns**

- **No return value.**

**Example**

```lua
exports.ox_inventory:InspectInventory(officer, suspect)
```

**Representative console output**

```text
Opens only if an inspection policy allows it.
```

#### `exports.ox_inventory:ConfiscateInventory(source)`

Moves a player's items into an in-memory `confiscation:<source>` inventory (never openable by a client) and clears the player under one lock.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Player. |

**Returns**

- **No return value.**

**Example**

```lua
exports.ox_inventory:ConfiscateInventory(src)
```

**Representative console output**

```text
The player is emptied.
```

#### `exports.ox_inventory:ReturnInventory(source)`

Restores a confiscated inventory to the player and removes the confiscation record.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Player. |

**Returns**

- **No return value.**

**Example**

```lua
exports.ox_inventory:ReturnInventory(src)
```

**Representative console output**

```text
The player gets their items back.
```

#### `exports.ox_inventory:ConvertItems(unused, items)`

Converts a name-keyed `{ name = count }` map (or full item tables) into a slot-keyed ox array.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `unused` | any | Ignored (upstream signature). |
| `items` | table | Map or items. |

**Returns**

- **items** — array in ox shape.

**Example**

```lua
local list = exports.ox_inventory:ConvertItems(nil, { water_bottle = 2 })
```

**Representative console output**

```text
{ { slot = 1, name = 'water_bottle', count = 2 } }
```

#### `exports.ox_inventory:ConvertInventory(inv)`

Returns the snapshot for a known reference, or converts a table `{ id, type, slots, maxWeight, items }` into the same shape with recomputed weight.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `inv` | table \| string \| integer | Reference or inventory-like table. |

**Returns**

- **inventory** — table or nil.

**Example**

```lua
local inv = exports.ox_inventory:ConvertInventory({ id = 'x', slots = 10, maxWeight = 5000, items = { water_bottle = 2 } })
```

**Representative console output**

```text
{ type = 'stash', weight = 1000, items = {...} }
```

#### `exports.ox_inventory:Items(name?)`

Returns ox-format item definitions translated from kora_core's registry (copies). With a name, one definition or nil. Without, a map of every item.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `name?` | string | Item name. |

**Returns**

- **definition** — ox item table or map.

**Example**

```lua
local def = exports.ox_inventory:Items('water_bottle')
print(def.label, def.weight, def.stack)
```

**Representative console output**

```text
Water 500 true
```

#### `exports.ox_inventory:ItemList(name?)`

Alias of `Items`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `name?` | string | Item name. |

**Returns**

- **definition** — as `Items`.

**Example**

```lua
local all = exports.ox_inventory:ItemList()
```

**Representative console output**

```text
{ water_bottle = {...}, ... }
```

#### `exports.ox_inventory:setPlayerInventory(player, data)`

Replaces a player's items with the table in `data` through the validated replace.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `player` | table \| integer | Player table with `source`, or a source. |
| `data` | table | Slot-keyed rows. |

**Returns**

- **No return value.**

**Example**

```lua
exports.ox_inventory:setPlayerInventory(src, { [1] = { name = 'phone', amount = 1 } })
```

**Representative console output**

```text
The inventory is replaced.
```

#### `exports.ox_inventory:useItem(source, slot, cb?)`

Uses an item through the same funnel as the native `useItem`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Player. |
| `slot` | integer \| string | Slot (or item name). |
| `cb?` | function | Called with `(ok, err)`. |

**Returns**

- **used** — boolean.
- **reason** — `invalid_source` or the use failure.

**Example**

```lua
exports.ox_inventory:useItem(src, 2, function(ok, err) end)
```

**Representative console output**

```text
true
```

#### `exports.ox_inventory:forceOpenInventory(source, invType, data)`

Opens an inventory for a player by type and id, through the normal access checks.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Player. |
| `invType` | string | Type. |
| `data` | string \| table | Id or `{ id }`. |

**Returns**

- **opened** — boolean.
- **result** — payload or reason.

**Example**

```lua
exports.ox_inventory:forceOpenInventory(src, 'stash', 'pd_armoury')
```

**Representative console output**

```text
true
```

#### `exports.ox_inventory:registerHook(event, callback, options?)`

Registers an ox-style hook (same as `exports.kora_inventory:RegisterHook`).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `event` | string | Hook event. |
| `callback` | function | Callback. |
| `options?` | table | Filters. |

**Returns**

- **hookId** — string.

**Example**

```lua
local id = exports.ox_inventory:registerHook('buyItem', function(payload) end)
```

**Representative console output**

```text
myresource:buyItem:1
```

#### `exports.ox_inventory:removeHooks(id?)`

Removes the calling resource's hooks.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id?` | string | Hook id. |

**Returns**

- **No return value.**

**Example**

```lua
exports.ox_inventory:removeHooks()
```

**Representative console output**

```text
All your hooks are removed.
```

#### `exports.ox_inventory:getCash(source)`

Reads the player's kora_core cash balance.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Player. |

**Returns**

- **balance** — number.

**Example**

```lua
local cash = exports.ox_inventory:getCash(src)
```

**Representative console output**

```text
2450
```

#### `exports.ox_inventory:addCash(source, amount, reason?)`

Adds to the kora_core cash account.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Player. |
| `amount` | number | Amount. |
| `reason?` | string | Default `ox_inventory`. |

**Returns**

- **added** — kora_core result.

**Example**

```lua
exports.ox_inventory:addCash(src, 100)
```

**Representative console output**

```text
true
```

#### `exports.ox_inventory:removeCash(source, amount, reason?)`

Removes from the kora_core cash account.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Player. |
| `amount` | number | Amount. |
| `reason?` | string | Default `ox_inventory`. |

**Returns**

- **removed** — kora_core result.

**Example**

```lua
exports.ox_inventory:removeCash(src, 100)
```

**Representative console output**

```text
true
```

#### `exports.ox_inventory:getBank(...)`

A literal no-op, as upstream. Read bank balances with kora_core.

**Parameters**



**Returns**

- **No return value.**

**Example**

```lua
exports.ox_inventory:getBank(src)
```

**Representative console output**

```text
nil
```

#### `exports.ox_inventory:getCards(source)`

Always returns an empty table (no card system).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Ignored. |

**Returns**

- **cards** — `{}`.

**Example**

```lua
local cards = exports.ox_inventory:getCards(src)
```

**Representative console output**

```text
{}
```

#### `exports.ox_inventory:giveCard(...)`

Always returns false (no card system).

**Parameters**



**Returns**

- **given** — false.

**Example**

```lua
exports.ox_inventory:giveCard(src)
```

**Representative console output**

```text
false
```

### Common use cases

- Running ox_inventory-based scripts (crafting benches, shops, evidence tools) on kora_inventory.
- Porting server scripts by changing only the resource name.

### Limits and related APIs

Differences from upstream: detached snapshots instead of live objects, no durability decay on read, `GetCurrentWeapon` is not the drawn weapon, money routes to kora_core, player dimensions cannot be changed. Hooks use ox payload shapes (see Hooks). The returned `Items()` tables are copies; editing them does not change the registry.

### Related guides

- [Hooks](./hooks.md)
- [Items and metadata](./items.md)
- [Player items](./player-items.md)

## Client

The client side of the `ox_inventory` identity. Reads come from kora_core's replicated PlayerData and the session issued by the server; UI helpers (`notify`, `Progress`, `Keyboard`) are adapted onto kora_lib. The module registers itself only under the `ox_inventory` identity and never overwrites `exports.kora_inventory:openInventory`.

Namespace: `exports.ox_inventory` · Source: `client/compat/ox.lua, client.lua`

### How it works

Item lookups are gated on the item registry the way upstream is: an unknown item gives nil or 0, a known item you do not hold gives an empty result. Metadata matching is partial unless `strict` is given. Sorting by slot restores the "lowest slot first" behaviour upstream gets from dense arrays. UI helpers translate vocabularies (`inform` to `info`, ox notification positions onto kora_lib's six placements, `lib.progressBar` callbacks receive `cancelled`). Functions with no backing subsystem are documented no-ops.

### Notes for ox client scripts

1. **Reads are local and advisory** — Use them for display. The server remains the authority.
2. **Progress callbacks** — `Progress(options, cb)` calls `cb(cancelled)` as ox does (the argument is "cancelled", not "completed").
3. **Stash target** — `setStashTarget` stores a target that `openInventory('stash')` with no id then opens.

### Terms used on this page

| Term | Meaning |
| --- | --- |
| No-op | An export kept only for compatibility that intentionally does nothing. |

### Functions

Client exports of the `ox_inventory` identity. Anything marked a no-op exists only so scripts do not error.

#### `exports.ox_inventory:openInventory(invType, data?)`

Opens an inventory; for `stash` with no data it opens the target stored by `setStashTarget`. Calls the native client transport directly.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `invType` | string | Type. |
| `data?` | any | Id or table. |

**Returns**

- **No return value.**

**Example**

```lua
exports.ox_inventory:openInventory('stash', 'locker1')
```

**Representative console output**

```text
Requests the stash.
```

#### `exports.ox_inventory:closeInventory()`

Closes the session.

**Parameters**



**Returns**

- **No return value.**

**Example**

```lua
exports.ox_inventory:closeInventory()
```

**Representative console output**

```text
Closes.
```

#### `exports.ox_inventory:useSlot(slot)`

Submits a `use` intent for a slot.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `slot` | integer | Slot. |

**Returns**

- **accepted** — boolean, result — as `submitIntent`.

**Example**

```lua
exports.ox_inventory:useSlot(2)
```

**Representative console output**

```text
true
```

#### `exports.ox_inventory:useItem(data, cb?)`

Submits a `use` intent for `data.slot` (or a slot number); `cb(ok)` is called if given.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `data` | table \| integer | Item table with `slot`, or a slot. |
| `cb?` | function | Callback. |

**Returns**

- **ok** — boolean.

**Example**

```lua
exports.ox_inventory:useItem({ slot = 2 }, function(ok) end)
```

**Representative console output**

```text
true
```

#### `exports.ox_inventory:openNearbyInventory()`

Calls `requestGiveTarget` with no request id, which answers `missing give request id`; it does not open a nearby inventory.

**Parameters**



**Returns**

- **started** — false, `missing give request id`.

**Example**

```lua
exports.ox_inventory:openNearbyInventory()
```

**Representative console output**

```text
false
```

#### `exports.ox_inventory:giveItemToTarget(serverId, slot, count)`

Submits a `give` intent. The `serverId` argument is ignored: recipient selection always runs locally (one nearby player resolves at once, several require pointing at one).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `serverId` | integer | Ignored. |
| `slot` | integer | Slot. |
| `count` | integer | Amount. |

**Returns**

- **accepted** — boolean.

**Example**

```lua
exports.ox_inventory:giveItemToTarget(0, 3, 1)
```

**Representative console output**

```text
Starts recipient selection for slot 3.
```

#### `exports.ox_inventory:GetPlayerItems()`

Copy of the local player's items.

**Parameters**



**Returns**

- **items** — slot-keyed table.

**Example**

```lua
local items = exports.ox_inventory:GetPlayerItems()
```

**Representative console output**

```text
{ [1] = { ... } }
```

#### `exports.ox_inventory:GetPlayerWeight()`

Total carried weight in grams.

**Parameters**



**Returns**

- **weight** — number.

**Example**

```lua
local w = exports.ox_inventory:GetPlayerWeight()
```

**Representative console output**

```text
3560
```

#### `exports.ox_inventory:GetPlayerMaxWeight()`

The open session's capacity, otherwise `Config.kora_inventory.playerMaxWeight` (fallback 120000).

**Parameters**



**Returns**

- **maxWeight** — number.

**Example**

```lua
local m = exports.ox_inventory:GetPlayerMaxWeight()
```

**Representative console output**

```text
120000
```

#### `exports.ox_inventory:GetItemCount(name, metadata?, strict?)`

Count of an item (0 for unknown items).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `name` | string | Item name. |
| `metadata?` | table | Metadata. |
| `strict?` | boolean | Exact match. |

**Returns**

- **count** — integer.

**Example**

```lua
local n = exports.ox_inventory:GetItemCount('lockpick')
```

**Representative console output**

```text
4
```

#### `exports.ox_inventory:GetSlotWithItem(name, metadata?, strict?)`

First matching slot table; nil for unknown items.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `name` | string | Item name. |
| `metadata?` | table | Metadata. |
| `strict?` | boolean | Exact match. |

**Returns**

- **slot** — item table or nil.

**Example**

```lua
local slot = exports.ox_inventory:GetSlotWithItem('phone')
```

**Representative console output**

```text
{ slot = 14, ... }
```

#### `exports.ox_inventory:GetSlotIdWithItem(name, metadata?, strict?)`

Slot number of the first match.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `name` | string | Item name. |
| `metadata?` | table | Metadata. |
| `strict?` | boolean | Exact match. |

**Returns**

- **slot** — integer or nil.

**Example**

```lua
local n = exports.ox_inventory:GetSlotIdWithItem('phone')
```

**Representative console output**

```text
14
```

#### `exports.ox_inventory:GetSlotsWithItem(name, metadata?, strict?)`

All matching slots; nil for unknown items, empty for known items not held.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `name` | string | Item name. |
| `metadata?` | table | Metadata. |
| `strict?` | boolean | Exact match. |

**Returns**

- **slots** — array or nil.

**Example**

```lua
local stacks = exports.ox_inventory:GetSlotsWithItem('lockpick')
```

**Representative console output**

```text
{ ... }
```

#### `exports.ox_inventory:Search(search, items, metadata?)`

Same semantics as the server `Search` against the local player's items.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `search` | string \| integer | `slots`, `count`, 1 or 2. |
| `items` | string \| string[] | Item name(s). |
| `metadata?` | table | Metadata. |

**Returns**

- **result** — table, number or false.

**Example**

```lua
local n = exports.ox_inventory:Search('count', 'lockpick')
```

**Representative console output**

```text
4
```

#### `exports.ox_inventory:Items(name?)`

ox-format definitions from the shared registry.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `name?` | string | Item name. |

**Returns**

- **definition** — ox item table or map.

**Example**

```lua
local def = exports.ox_inventory:Items('water_bottle')
```

**Representative console output**

```text
{ label = 'Water', weight = 500, ... }
```

#### `exports.ox_inventory:ItemList(name?)`

Alias of `Items`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `name?` | string | Item name. |

**Returns**

- **definition** — as `Items`.

**Example**

```lua
local all = exports.ox_inventory:ItemList()
```

**Representative console output**

```text
{ ... }
```

#### `exports.ox_inventory:setStashTarget(id, owner?)`

Stores the stash `openInventory('stash')` opens when called with no data. Pass nil to clear.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | string \| nil | Stash id. |
| `owner?` | any | Stored with the target. |

**Returns**

- **No return value.**

**Example**

```lua
exports.ox_inventory:setStashTarget('locker1')
```

**Representative console output**

```text
The next stash open uses locker1.
```

#### `exports.ox_inventory:getCurrentWeapon()`

The owned weapon item matching the ped's selected weapon (lowest slot when several). Also reports a weapon armed by another resource.

**Parameters**



**Returns**

- **weapon** — item table or nil.

**Example**

```lua
local w = exports.ox_inventory:getCurrentWeapon()
```

**Representative console output**

```text
{ name = 'weapon_pistol', slot = 1 }
```

#### `exports.ox_inventory:notify(data)`

Shows a kora_lib notification. Folds `description` or `text` onto `message`, maps `inform` to `info`, and maps ox positions onto kora_lib's.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `data` | table | `{ title, description\|text\|message, type, position }`. |

**Returns**

- **No return value.**

**Example**

```lua
exports.ox_inventory:notify({ title = 'Shop', description = 'Bought', type = 'success' })
```

**Representative console output**

```text
A toast appears.
```

#### `exports.ox_inventory:Progress(options, completed?)`

Runs a kora_lib progress bar from ox options. `completed(cancelled)` receives true when cancelled.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | table | `label`, `duration`, `canCancel`, `disable`, `anim`, `prop`. |
| `completed?` | function | Callback with `cancelled`. |

**Returns**

- **success** — boolean.

**Example**

```lua
local ok = exports.ox_inventory:Progress({ label = 'Searching', duration = 3000, canCancel = true })
```

**Representative console output**

```text
true when it finishes.
```

#### `exports.ox_inventory:ProgressActive()`

Whether a kora_lib progress bar is active.

**Parameters**



**Returns**

- **active** — boolean.

**Example**

```lua
if exports.ox_inventory:ProgressActive() then end
```

**Representative console output**

```text
false
```

#### `exports.ox_inventory:CancelProgress()`

Cancels the active progress bar.

**Parameters**



**Returns**

- **No documented return value (forwards `Kora.progressbar.cancel`).**

**Example**

```lua
exports.ox_inventory:CancelProgress()
```

**Representative console output**

```text
The bar stops.
```

#### `exports.ox_inventory:Keyboard(heading, rows)`

Opens a kora_lib input dialog from ox rows and returns an array aligned with `rows`, or nil on cancel. Unknown row types become text fields.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `heading` | string | Dialog title. |
| `rows` | table | Rows `{ type, label, default, placeholder, required, min, max, options }`. |

**Returns**

- **values** — array or nil.

**Example**

```lua
local values = exports.ox_inventory:Keyboard('Name it', { { type = 'input', label = 'Name' } })
```

**Representative console output**

```text
{ 'Duffel' }
```

#### `exports.ox_inventory:displayMetadata(...)`

No-op: the NUI renders raw metadata keys.

**Parameters**



**Returns**

- **No return value.**

**Example**

```lua
exports.ox_inventory:displayMetadata({ serial = 'Serial' })
```

**Representative console output**

```text
Nothing.
```

#### `exports.ox_inventory:suppressItemNotifications(...)`

No-op: item receipts are server-authored and gated by `Config.kora_inventory.itemBoxes`.

**Parameters**



**Returns**

- **No return value.**

**Example**

```lua
exports.ox_inventory:suppressItemNotifications(true)
```

**Representative console output**

```text
Nothing.
```

#### `exports.ox_inventory:weaponWheel(...)`

No-op: kora_inventory runs no per-frame control loop.

**Parameters**



**Returns**

- **No return value.**

**Example**

```lua
exports.ox_inventory:weaponWheel(true)
```

**Representative console output**

```text
Nothing.
```

#### `exports.ox_inventory:setGetPlayerNameMethod(...)`

No-op by design: the give UI never shows player names.

**Parameters**



**Returns**

- **No return value.**

**Example**

```lua
exports.ox_inventory:setGetPlayerNameMethod(fn)
```

**Representative console output**

```text
Nothing.
```

### Common use cases

- Client scripts that query items or open stashes through ox_inventory exports.

### Limits and related APIs

No-op exports exist for compatibility only. Reads are local and advisory. `openNearbyInventory` and `giveItemToTarget` do not behave as in ox (see their entries).

### Related guides

- [Client API](./client-api.md)
- [qb-inventory compat](./compat-qb.md)
