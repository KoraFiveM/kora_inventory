---
title: "Hooks"
sidebar_position: 10
---


# Hooks

Hooks let a server resource observe or veto inventory actions before they commit, and observe the result afterwards. The payloads follow ox_inventory's hook module (slot tables, string hook ids, `payload.source`); kora keys travel along as extra fields. Seven events exist: `swapItems`, `buyItem`, `createItem`, `openShop`, `openInventory`, `usingItem` and `craftItem`.

Namespace: `exports.kora_inventory` · Source: `server.lua (registerHook, runHooks, finishHooks), server/compat/qb_hooks.lua`

## How it works

A hook is registered per event and kept in registration order. When an action reaches its hook point, every matching hook runs inside `pcall` with `(payload, source)`. Returning `false` cancels the action (nothing is charged or moved) and the caller receives the reason; an error inside a hook is printed and ignored. For hooks owned by a `kora_*` resource, or registered with `koraKeys = true`, a returned string also cancels with that string and the id fields hold kora inventory keys (`player:12`, `stash:pd_armoury`). For all other owners only `false` cancels and the ids are ox style (a server id for a player, the bare id for a stash, `trunk<PLATE>` / `glove<PLATE>`). After the action finishes, `TriggerEvent(hookId, success, payload)` fires about 50 ms later for each hook that ran.

## Using a hook

1. **Choose the event** — Pick the action you care about: moving (`swapItems`), buying (`buyItem`), creating (`createItem`), opening a shop or inventory, using an item, or crafting.
2. **Register with filters** — Pass an options table to narrow it by item, inventory or inventory type so your callback only runs when relevant.
3. **Return false to cancel** — Anything else lets the action continue. `createItem` is the exception: return a table to replace the metadata.
4. **Optionally listen after the fact** — Use `AddEventHandler(hookId, function(success, payload) end)` to be told whether the action actually committed.

## Terms used on this page

| Term | Meaning |
| --- | --- |
| Hook id | A string `resource:event:index` returned by `RegisterHook`; also the name of the post-event. |
| Post-event | `TriggerEvent(hookId, success, payload)` fired after the guarded action finishes (success is true when it committed). |
| Kora keys mode | Hook owners named `kora_*`, or hooks with `koraKeys = true`, see kora inventory keys and may cancel with a string. |

## Hook options table

The third argument of `RegisterHook`. A hook with no matching filter never runs.

| Option | Type | Description |
| --- | --- | --- |
| `itemFilter` | table&lt;string, true> | Run only when the payload's item name (or the destination slot's item for swaps) is a key of this map. |
| `inventoryFilter` | string[] \| table&lt;string, true> | An array of Lua patterns matched against the stringified from/to inventory ids, or a map of exact inventory keys or ids. |
| `typeFilter` | table&lt;string, true> | Run only when the inventory type (`inventoryType`, `shopType` or `fromType`; also `toType` in kora keys mode) is a key of this map. |
| `print` | boolean | Print a console line when the hook triggers or rejects. |
| `koraKeys` | boolean | Force (`true`) or disable (`false`) kora keys mode regardless of the owner name. |

## swapItems

Fires for UI transfers, gives and drops. `action` is `move`, `swap`, `stack` or `give`. Payload: `source, action, fromInventory, fromType, fromSlot` (slot table), `toInventory, toType, toSlot` (slot table or number), `count, itemName, fromKey, toKey`. A new ground drop uses `toInventory = 'newdrop'`, `toSlot = 1` and `dropId`. The `moveItem` export and compat `SwapSlots` do not fire it.

## buyItem

Fires after the purchase is validated and affordable, before payment. Payload: `source, shopType, shopId, toInventory` (server id), `fromSlot` (slot table with `price`, `currency`), `itemName, metadata, count, price, totalPrice, currency, fromKey, toKey`. Cancelling charges nothing.

## createItem

Fires when an item is newly created: `AddItem`, shop purchases and the compat add paths; never for moves, swaps, gives, rollbacks or crafted outputs. Payload: `source, inventoryId, inventoryKey, itemName, item` (ox definition), `metadata, count, resource`. Return a table to replace the metadata; `false` and everything else is ignored.

## openShop / openInventory

`openShop` payload: `source, shopId, shopType, label, slots, items` (slot tables with `price`), `groups, coords, distance, inventoryKey`. `openInventory` payload: `source, inventoryId, inventoryKey, inventoryType`. Returning false refuses the open.

## usingItem

Fires before a handler runs. Payload: `source, itemName, item` (slot table), `inventoryId` (server id), `inventoryKey, inventoryType = 'player'`, `consume` (the ox amount a use consumes, 0 for non-consumables).

## craftItem

Fires during `CraftItem` after capacity is planned. Payload: `source, benchId, benchIndex, recipe` (`{ name, count, ingredients = { [item] = count }, metadata, id, label }`), `toInventory, toSlot, recipeId, itemName, amount, context, inventoryKey, toKey`.

## Functions

Register and remove hooks from the resource that owns them; hooks are removed automatically when that resource stops.

### `exports.kora_inventory:RegisterHook(eventName, callback, options?)`

Registers a hook for one of the seven events and returns its id. The callback may be omitted (pass nil with an options table) to subscribe to the post-event only. Alias `registerHook`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `eventName` | string | `swapItems`, `buyItem`, `createItem`, `openShop`, `openInventory`, `usingItem` or `craftItem`. |
| `callback` | function \| nil | `callback(payload, source)`. Return false to cancel (a string too in kora keys mode). |
| `options?` | table | Filters (see the options table). |

**Returns**

- **hookId** — string such as `myresource:swapItems:1`.

**Example**

```lua
local id = exports.kora_inventory:RegisterHook('swapItems', function(payload)
    if payload.toType == 'trunk' and payload.itemName == 'weapon_pistol' then
        return false -- no pistols in trunks
    end
end, { itemFilter = { weapon_pistol = true }, typeFilter = { trunk = true } })

AddEventHandler(id, function(success, payload)
    if success then print('pistol moved by', payload.source) end
end)
```

**Representative console output**

```text
id = 'myresource:swapItems:1'. Moving a pistol into a trunk is cancelled; successful moves also trigger the post-event.
```

### `exports.kora_inventory:RemoveHooks(id?)`

Removes hooks registered by the calling resource: the one with the given id, or all of them when no id is given. Hooks of other resources are never touched. Alias `removeHooks`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id?` | string | Hook id from `RegisterHook`. |

**Returns**

- **No return value.**

**Example**

```lua
exports.kora_inventory:RemoveHooks(id)   -- one hook
exports.kora_inventory:RemoveHooks()     -- every hook this resource registered
```

**Representative console output**

```text
The hooks stop running.
```

## Common use cases

- Banning certain items from certain inventories.
- Logging purchases, moves or crafts to Discord or a database.
- Rewriting item metadata (provenance, quality) at creation time.
- Blocking shops or inventories during events.

## Limits and related APIs

Hook callbacks run synchronously inside the inventory lock; keep them fast and never call back into a blocked inventory function that needs the same lock. A hook error is logged and treated as "allow". Hooks are in memory only. qb-inventory's `AddHook`/`AddListener` are separate registries built on top of these dispatchers (see the qb compat module).

## Related guides

- [qb-inventory compat](./compat-qb.md)
- [ox_inventory compat](./compat-ox.md)
- [Events and callbacks](./events.md)

## Operating notes (from the code)

Facts below were written from the current code of this resource; they add to, and where noted refine, the reference above.

Two hook APIs run on the server. Hooks observe or cancel an action after the inventory has validated it; they can never bypass its checks.

### ox-style hooks: `registerHook`

```lua
local id = exports.kora_inventory:registerHook('swapItems', function(payload, source)
    if payload.toType == 'stash' and payload.toInventory == 'evidence_locker' then
        return false -- cancel
    end
end, { itemFilter = { lockpick = true }, typeFilter = { stash = true } })

exports.kora_inventory:removeHooks(id)
```

The callback gets `(payload, source)`; `payload.source` is always set. Returning `false` cancels. A returned string also cancels with that reason only for `kora_*` resources or hooks created with `koraKeys = true`; for other resources only `false` cancels, as in ox. `registerHook` returns an id like `resource:event:n`. `removeHooks(id)` removes the caller's own hook; with no id it removes all of the caller's hooks. Hooks are removed when the owning resource stops.

| Event | Payload fields |
| --- | --- |
| `swapItems` | `action` (`move`, `swap`, `stack`, `give`), `fromInventory`, `toInventory`, `fromType`, `toType`, `fromSlot`, `toSlot`, `count`, `dropId` (new drops) |
| `buyItem` | `shopType`, `shopId`, `toInventory`, `toSlot`, `fromSlot`, `itemName`, `metadata`, `count`, `price`, `totalPrice`, `currency` |
| `createItem` | `inventoryId`, `item`, `metadata`, `count`, `resource` |
| `craftItem` | `benchId`, `benchIndex`, `recipe`, `toInventory`, `toSlot` |
| `openInventory` | `inventoryId`, `inventoryType` |
| `openShop` | `shopId`, `shopType`, `label`, `slots`, `items`, `groups`, `coords`, `distance` |
| `usingItem` | `inventoryId`, `item`, `consume` |

ox ids are a player's server id, the bare stash/drop/shop id, or `newdrop` for a new ground drop. Slot tables use ox fields (`name`, `count`, `metadata`, `slot`, `weight`); `toSlot` is a number when the target is empty. kora adds `itemName` and the kora inventory keys `fromKey`, `toKey`, `inventoryKey` (for example `stash:box`).

Behaviour notes:

- Gives and ground drops fire `swapItems` (`give`, and `move` to `newdrop`) after validation and before anything moves.
- `buyItem` fires after validation and the affordability check, before payment and delivery. Cancelling takes no money.
- `createItem` fires for public add paths and shop purchases, never for moves, swaps, gives, rollbacks or crafted outputs. It is not cancellable: only a returned table (which replaces the metadata) has an effect.
- After the guarded action finishes, `TriggerEvent(hookId, success, payload)` fires for every hook that ran (about 50 ms later), so a hook may be registered without a callback to listen for outcomes.

Options:

| Option | Meaning |
| --- | --- |
| `itemFilter` | Map `item = true`; checked against `fromSlot`, `item`, `itemName`, `recipe`, then `toSlot`. |
| `inventoryFilter` | Array of Lua patterns tested against the from/to/inventory id, or a kora exact-key map such as `stash:box = true`. |
| `typeFilter` | Map of types (`inventoryType`, `shopType`, `fromType`). |
| `print` | Print a console line each time the hook runs and when it rejects. |
| `koraKeys` | Force kora keys (`true`) or ox ids (`false`) in the id fields. First-party `kora_*` resources get kora keys by default. |

### qb-style hooks

The `qb-inventory` identity provides `AddHook`, `RemoveHook`, `AddListener` and `RemoveListener` for `ItemMoved`, `ItemDropped`, `ItemUsed`, `ItemBought`, `ItemAdded`, `ItemRemoved`, `InventoryOpened` and `ShopOpened`. Callbacks receive `(type, data)` as upstream. See [Compatibility](../compatibility.md).

### Inspecting another player

Opening another player's inventory is denied by default. Register a policy:

```lua
exports.kora_inventory:registerInspectionAccess(function(source, target, sourceData, targetData)
    return IsPlayerAceAllowed(source, 'inventory.inspect')
end)
```

A policy returning `false, reason` or raising an error denies. `Config.kora_inventory.playerInspection.access` is the config equivalent. There is no permissive toggle.

### Crafting hooks

`RegisterCraftHook` and `RemoveCraftHook` approve or reject a craft; see [Crafting](./crafting.md).
