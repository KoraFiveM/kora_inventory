---
title: Hooks
sidebar_position: 7
---

# Hooks

Two hook APIs run on the server. Hooks observe or cancel an action after the inventory has validated it; they can never bypass its checks.

## ox-style hooks: `registerHook`

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

## qb-style hooks

The `qb-inventory` identity provides `AddHook`, `RemoveHook`, `AddListener` and `RemoveListener` for `ItemMoved`, `ItemDropped`, `ItemUsed`, `ItemBought`, `ItemAdded`, `ItemRemoved`, `InventoryOpened` and `ShopOpened`. Callbacks receive `(type, data)` as upstream. See [Compatibility](./compatibility.md).

## Inspecting another player

Opening another player's inventory is denied by default. Register a policy:

```lua
exports.kora_inventory:registerInspectionAccess(function(source, target, sourceData, targetData)
    return IsPlayerAceAllowed(source, 'inventory.inspect')
end)
```

A policy returning `false, reason` or raising an error denies. `Config.kora_inventory.playerInspection.access` is the config equivalent. There is no permissive toggle.

## Crafting hooks

`RegisterCraftHook` and `RemoveCraftHook` approve or reject a craft; see [Crafting](./crafting.md).
