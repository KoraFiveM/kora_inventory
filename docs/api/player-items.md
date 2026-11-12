---
title: "Player items"
sidebar_position: 2
---


# Player items

Add, remove, count and rearrange the items in a player's own inventory. Every write is applied to kora_core's PlayerData through a per-inventory lock, bumps the inventory revision, pushes a live patch to anyone viewing it and records an audit entry. These are the functions your gameplay scripts use to reward, charge and check items.

Namespace: `exports.kora_inventory` · Source: `server.lua (addItem, removeItem, canCarry, ... api table)`

## How it works

All player writes funnel through `playerSetPath`, which calls `exports.kora_core:setPath` for a single slot (or the whole `items` table for replacements). While kora_inventory itself is writing, it marks the write as its own so the `kora_core:server:inventoryChanged` listener does not double-count it; writes made by other resources through kora_core are noticed by that listener and still bump the revision and refresh any open panel. Calls that change an inventory take a lock keyed by inventory; a second caller in a different thread receives `inventory busy`. With physical cash enabled, the cash item name is redirected to `addMoney` / `removeMoney`.

## Granting and charging items

1. **Validate on the server** — Decide the item and amount from server state. Never copy a name or count from a client event.
2. **Check capacity (optional)** — `canCarry(src, name, amount)` tells you in advance whether the grant fits, which avoids half-completed rewards when you grant several items.
3. **Call AddItem or RemoveItem** — Check the boolean and handle the reason string. Pass a short `reason` so the audit entry says why.
4. **React to the commit** — Listen to `kora_inventory:server:audit` or the `createItem` hook if another system must know.

## Terms used on this page

| Term | Meaning |
| --- | --- |
| Slot | Integer position 1..`playerSlots`. Slots hold either nothing or one instance table. |
| Revision | A counter bumped on every committed change. The UI sends the revision it saw, so a stale view cannot overwrite a newer one. |
| Reason | Free text you supply on add/remove for the audit trail (for example `scrapjob-reward`). |

## Functions

All of these take the player's server id as the first argument and are server-only exports. Several have an alias in the other letter case (listed in each entry); `getWeight` and `moveItem` exist only in lower case.

### `exports.kora_inventory:AddItem(src, name, amount?, slot?, info?, reason?)`

Adds an item to a player (alias `addItem`). Checks capacity, runs the `createItem` hook (which may replace the metadata), prepares weapon metadata for weapons, then writes the slot (stacking into an existing stack when possible) and shows an item receipt.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `name` | string | Item name in the shared `items` or `weapons` registry. |
| `amount?` | integer | Whole number of at least 1. Default 1. Fractions are floored. Do not pass 0 or a negative number: it is not rejected up front and can end in a failed transaction or a malformed stack. |
| `slot?` | integer | Preferred slot. If it already holds a stackable match the amount is added there; if it is occupied by something else the add fails with `no free slot`. |
| `info?` | table | Instance metadata. Copied, so later changes to your table do not affect the item. |
| `reason?` | string | Audit text. |

**Returns**

- **added** — true when the item was written.
- **reason** — on failure: `unknown item`, `over weight`, `no free slot`, `inventory busy`, `transaction failed` or a hook/weapon error such as `item is not a registered weapon`.

**Example**

```lua
local added, reason = exports.kora_inventory:AddItem(src, 'lockpick', 3, nil, { batch = 'A12' }, 'hardware-reward')
if not added then
    Kora.notify.send(src, { title = 'Inventory', message = 'Could not receive item: ' .. tostring(reason), type = 'error' })
end
```

**Representative console output**

```text
added = true. The player sees an item box for 3x Lockpick and the stack appears in their lowest suitable slot.
```

### `exports.kora_inventory:RemoveItem(src, name, amount?, slot?, reason?)`

Removes an amount of an item from a player (alias `removeItem`). Without a slot it drains matching slots from slot 1 upward; if the player does not hold enough it fails without removing anything.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `name` | string | Exact item name (matched case-sensitively here, unlike the lookup functions). |
| `amount?` | integer | Whole number of at least 1. Default 1. |
| `slot?` | integer | Remove from this slot only. The slot must hold an item with exactly this name. |
| `reason?` | string | Audit text. |

**Returns**

- **removed** — true on success.
- **reason** — `invalid amount`, `item not in slot`, `not enough of item`, `empty slot`, `inventory busy`.

**Example**

```lua
local removed, reason = exports.kora_inventory:RemoveItem(src, 'water_bottle', 2, nil, 'recipe-ingredient')
if not removed then return end
```

**Representative console output**

```text
removed = true. One receipt is shown per drained slot.
```

### `exports.kora_inventory:canCarry(src, name, amount?)`

Read-only check that a player could receive an item: it exists, the weight fits, and a stack or free slot is available (unique items need one free slot per unit). Also available as `CanAddItem`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `name` | string | Item name. |
| `amount?` | integer | Default 1. |

**Returns**

- **canCarryItem** — true when the grant would fit.
- **reason** — `unknown item`, `no such player`, `over weight` or `no free slot`.

**Example**

```lua
local fits, why = exports.kora_inventory:canCarry(src, 'weapon_pistol', 1)
if not fits then print('cannot grant pistol:', why) end
```

**Representative console output**

```text
fits = true, or false with why = 'no free slot'. Nothing changes either way.
```

### `exports.kora_inventory:CanAddItem(src, name, amount?)`

Alias of `canCarry` on the native identity. (The qb-inventory identity has its own `CanAddItem` that also accepts stash identifiers; see the qb compat module.)

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `name` | string | Item name. |
| `amount?` | integer | Default 1. |

**Returns**

- **canCarryItem** — boolean.
- **reason** — as `canCarry`.

**Example**

```lua
if exports.kora_inventory:CanAddItem(src, 'sandwich', 4) then
    exports.kora_inventory:AddItem(src, 'sandwich', 4)
end
```

**Representative console output**

```text
Adds four sandwiches only when they fit.
```

### `exports.kora_inventory:getWeight(src)`

Returns the player's current carried weight and the maximum.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |

**Returns**

- **currentWeight** — number, grams (0 for an unknown player).
- **maxWeight** — number, `Config.kora_inventory.playerMaxWeight`.

**Example**

```lua
local current, max = exports.kora_inventory:getWeight(src)
print(('%.1f / %.1f kg'):format(current / 1000, max / 1000))
```

**Representative console output**

```text
12.4 / 120.0 kg
```

### `exports.kora_inventory:GetFreeWeight(src)`

Remaining capacity in grams (`maxWeight - currentWeight`). Alias `getFreeWeight`. For an unknown player the native version reports the full maximum (the qb-inventory identity reports 0 instead).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |

**Returns**

- **freeWeight** — number, grams.

**Example**

```lua
local free = exports.kora_inventory:GetFreeWeight(src)
local perItem = 500
local maxCrates = math.floor(free / perItem)
```

**Representative console output**

```text
free = 107600 -> maxCrates = 215
```

### `exports.kora_inventory:GetItemByName(src, name)`

Returns one stack of the named item (alias `getItemByName`). Matching is case-insensitive. Which stack you get when several exist is not defined (slots are scanned in table order), so use `GetItemsByName` or `GetItemCount` when it matters.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `name` | string | Item name. |

**Returns**

- **item** — instance table (`slot`, `name`, `amount`, `info` ...) or nil.

**Example**

```lua
local item = exports.kora_inventory:GetItemByName(src, 'phone')
if item then print(item.slot, item.info.handsetId) end
```

**Representative console output**

```text
14 phone-3f9a...
```

### `exports.kora_inventory:GetItemsByName(src, name)`

Returns every stack of an item the player holds (alias `getItemsByName`; an empty list when none). Order is unspecified.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `name` | string | Item name. |

**Returns**

- **items** — array of instance tables.

**Example**

```lua
for _, stack in ipairs(exports.kora_inventory:GetItemsByName(src, 'lockpick')) do
    print(stack.slot, stack.amount)
end
```

**Representative console output**

```text
3 4
9 1
```

### `exports.kora_inventory:GetItemBySlot(src, slot)`

Returns the instance in a slot, or nil (alias `getItemBySlot`).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `slot` | integer | Slot number. |

**Returns**

- **item** — instance table or nil.

**Example**

```lua
local item = exports.kora_inventory:GetItemBySlot(src, 1)
if item and item.name == 'weapon_pistol' then print(item.info.serial) end
```

**Representative console output**

```text
KORA-WEAPONPISTOL-1767225600-482913
```

### `exports.kora_inventory:GetItemCount(src, names)`

Total amount across all stacks of one item name or of any name in a list (alias `getItemCount`). Matching is case-insensitive.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `names` | string \| string[] | One name or an array of names. Anything else returns 0. |

**Returns**

- **count** — number.

**Example**

```lua
local ammo = exports.kora_inventory:GetItemCount(src, { 'pistol_ammo', 'smg_ammo' })
```

**Representative console output**

```text
ammo = 3
```

### `exports.kora_inventory:HasItem(src, names, amount?)`

True when the player holds enough (alias `hasItem`). A string needs `amount` (default 1). An array needs every name present (or `amount` of each when given). A `{ [name] = count }` map needs each count; for maps the `amount` argument is ignored here (the qb-inventory identity applies it to every entry instead).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `names` | string \| string[] \| table&lt;string, number> | Item name(s) or a map of name to required count. |
| `amount?` | integer | Required count for a string or array. Default 1. |

**Returns**

- **hasItems** — boolean.

**Example**

```lua
if exports.kora_inventory:HasItem(src, { lockpick = 1, screwdriver = 1 }) then
    -- both present
end
```

**Representative console output**

```text
true
```

### `exports.kora_inventory:GetFreeSlot(src)`

Lowest empty slot number, or nil when the inventory is full (alias `getFreeSlot`).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |

**Returns**

- **slot** — integer or nil.

**Example**

```lua
local slot = exports.kora_inventory:GetFreeSlot(src)
if not slot then print('inventory full') end
```

**Representative console output**

```text
slot = 6
```

### `exports.kora_inventory:moveItem(src, fromSlot, toSlot, amount?)`

Moves or splits within the player's own inventory. The destination must be empty or hold a stackable match. Server scripts rarely need this; the UI uses the transfer funnel instead.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `fromSlot` | integer | Source slot. |
| `toSlot` | integer | Target slot, 1..playerSlots. |
| `amount?` | integer | Amount to move; default the whole stack. |

**Returns**

- **moved** — true on success (also true when from and to are the same slot).
- **reason** — `empty source slot`, `invalid move`, `destination occupied`, `inventory busy`.

**Example**

```lua
local moved, reason = exports.kora_inventory:moveItem(src, 4, 1)
```

**Representative console output**

```text
moved = true; the stack now sits in slot 1.
```

### `exports.kora_inventory:ClearInventory(src, keep?)`

Removes every item from a player except the ones named in `keep`. With physical cash on, the cash item is always kept. Alias `clearInventory`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `keep?` | string \| string[] \| table&lt;string, boolean> | Item names to keep. |

**Returns**

- **cleared** — true on success.
- **reason** — kora_core error or `inventory busy`.

**Example**

```lua
exports.kora_inventory:ClearInventory(src, { 'phone', 'id_card' })
```

**Representative console output**

```text
All slots except phone and id_card are emptied and viewers are patched.
```

### `exports.kora_inventory:SetInventory(src, items)`

Replaces the whole player inventory with a validated table. Each row must name a registered item; slot, amount and metadata are rebuilt from the definition, keeping extra trusted fields. Also exported as `setItems`. Unavailable while physical cash is on.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `items` | table&lt;integer, table> | Slot-keyed rows with `name`, `amount`/`count` and optional `info`/`metadata`. |

**Returns**

- **replaced** — true on success.
- **reason** — `items must be a table`, `invalid item table`, `over weight`, `SetInventory is unavailable while cash is an item`, `physical cash cannot be changed by an inventory replacement`.

**Example**

```lua
local ok, reason = exports.kora_inventory:SetInventory(src, {
    [1] = { name = 'water_bottle', amount = 2 },
    [2] = { name = 'phone', amount = 1, info = { handsetId = 'phone-1234567890abcdef' } },
})
```

**Representative console output**

```text
ok = true. All other slots are cleared.
```

### `exports.kora_inventory:GetInventory(src)`

Returns the player's items table straight from kora_core (slot-keyed). The result is a copy across the export boundary. Alias `getInventory`. The qb-inventory and ox_inventory identities return different shapes for this name.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |

**Returns**

- **items** — slot-keyed table; empty for an unknown player.

**Example**

```lua
local items = exports.kora_inventory:GetInventory(src)
for slot, item in pairs(items) do print(slot, item.name, item.amount) end
```

**Representative console output**

```text
1 water_bottle 2
2 phone 1
```

### `exports.kora_inventory:PhoneItemTransaction(src, request)`

Restricted integration for the phone resource (`kora_phone`, or the old `kora_phone-stevie` folder name; any other caller gets `phone integration only`). Binds identities to unique handset and SIM items and inserts, removes, resells or replaces a SIM as one atomic inventory write, optionally with a bank payment and a resale listing in a `kora_phone:` shop, with money compensated if the inventory write fails. Alias `phoneItemTransaction`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `request` | table | `op` is one of `bindHandset`, `bindSim`, `insertSim`, `removeSim`, `resell`, `replaceSim`. Handset ops need `handsetSlot` and `handsetId`; `bindSim` needs `simSlot` and `simId`. Ids are 16 to 64 characters of letters, digits, `-` and `_`. Other fields by op: `itemName` (bind ops, must match the item), `legacySimId` (`bindHandset`), `simSlot` and `simId` (`insertSim`), `simId` (`removeSim`, `replaceSim`), `newSimId` and `fee` (`replaceSim`), `payout`, `shopId` (must start with `kora_phone:`) and `salePrice` (`resell`). |

**Returns**

- **ok** — true on success.
- **error / handset / returnedSim** — on success nil, a copy of the updated handset (or the resold item) and a copy of any SIM returned to the inventory; on failure false and a reason such as `phone integration only`, `invalid phone transaction`, `invalid phone identity`, `unknown phone operation`, `invalid phone service amount`, `item missing or stacked`, `unsupported phone item`, `identity already bound`, `SIM slot occupied`, `inserted SIM changed`, `remove SIM before resale`, `no free slot`, `shop not found`, `handset already stocked`, `phone shop is full`, `bank service unavailable`, `inventory changed during payment`, `bank compensation failed`.

**Example**

```lua
-- only the phone resource can call this
local ok, err, handset = exports.kora_inventory:PhoneItemTransaction(src, {
    op = 'bindHandset', handsetSlot = 14, handsetId = 'handset-0123456789abcdef', itemName = 'phone',
})
```

**Representative console output**

```text
ok = true, handset.info.handsetId = 'handset-0123456789abcdef'. Any other resource receives false, 'phone integration only'.
```

## Common use cases

- Pay out job rewards after server-side validation.
- Charge ingredients before a custom action.
- Gate an interaction on `HasItem` or `GetItemCount`.
- Strip a player's items on jail with `ClearInventory(src, keep)`.

## Limits and related APIs

Amounts are whole numbers; fractions are floored. Player slot count and weight are global config, not per player. `RemoveItem` compares names exactly while `HasItem`, `GetItem*` lower-case the input. While a durable exchange or stash recovery holds kora_core's inventory column fence for a player, ordinary writes to that player are refused by kora_core and the call fails.

## Related guides

- [Items and metadata](./items.md)
- [Opening inventories](./inventories.md)
- [Events and callbacks](./events.md)
- [qb-inventory compat](./compat-qb.md)
