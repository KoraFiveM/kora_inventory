---
title: Exports
sidebar_position: 5
---

# Exports

Call as `exports.kora_inventory:<name>(...)`. Server exports are in `server.lua` and the `server/*.lua` modules; client exports are in `client.lua`, `client/give_target.lua`, `client/compat/qb_weapons.lua` and `fft_hooks.lua`.

The same function is reachable as `camelCase` and `PascalCase` for the names declared in the alias table of `server.lua` (for example `registerStash` and `RegisterStash`). The crafting, weapon, exchange and carry exports below are registered under the single spelling shown. The `qb-inventory` and `ox_inventory` identities are a separate namespace, see [Compatibility](./compatibility.md).

Every function that changes inventory data returns `true` on success or `false, reason`. Inventory data is only changed by the server; a client export can never grant items.

## Player inventory (server)

| Export | Returns | Notes |
| --- | --- | --- |
| `getWeight(src)` | `weight, maxWeight` | |
| `canCarry(src, name, amount?)` | `true` or `false, reason` | Checks the item exists, weight and a free or stackable slot. Aliases `CanAddItem`. |
| `addItem(src, name, amount?, slot?, info?, reason?)` | `true` or `false, reason` | Runs the `createItem` hook. Shows an item box. With `cash.asItem` on, the cash item is routed to kora_core `addMoney`. Alias `AddItem`. |
| `removeItem(src, name, amount?, slot?, reason?)` | `true` or `false, reason` | Alias `RemoveItem`. |
| `getItemByName(src, name)` | item or `nil` | Case-insensitive. |
| `getItemsByName(src, name)` | list of items | |
| `getItemBySlot(src, slot)` | item or `nil` | |
| `getItemCount(src, names)` | number | `names` is a string or list; amounts are summed. |
| `hasItem(src, names, amount?)` | boolean | String, list, or `name = count` map. |
| `getFreeSlot(src)` | slot or `nil` | |
| `getFreeWeight(src)` / `GetFreeWeight` | number | Max weight minus current weight. |
| `moveItem(src, fromSlot, toSlot, amount?)` | `true` or `false, reason` | Within the player's inventory; stacks only matching non-unique items. |
| `clearInventory(src, keep?)` | `true` or `false, reason` | `keep` is a name, list or set; the cash item is always kept when `cash.asItem` is on. Alias `ClearInventory`. |
| `setItems(src, newItems)` | `true` or `false, reason` | Replaces the whole inventory after validating every definition, capacity and unchanged physical cash. Alias `SetInventory`. |
| `GetInventory(src)` / `getInventory` | slot map | |
| `createUseable(name, handler)` | | `handler(src, item)`. Alias `CreateUsableItem`. This is kora_inventory's own useable table, not kora_core's. |
| `getUseable(name)` | handler or `nil` | |
| `useItem(src, slotOrName)` | `true` or `false, reason` | Runs the same use path as the UI. A number opens configured portable containers. |
| `OpenInventory(src, identifier?, opts?)`, `CloseInventory(src)` | | qb-style open and close; see [Compatibility](./compatibility.md). |

### Hooks and inspection

| Export | Notes |
| --- | --- |
| `registerHook(event, callback, options?)` / `RegisterHook` | Returns a hook id. See [Hooks](./hooks.md). |
| `removeHooks(id?)` / `RemoveHooks` | Removes the caller's own hook, or all of the caller's hooks without an id. |
| `registerInspectionAccess(callback)` / `RegisterInspectionAccess` | `callback(source, target, sourceData, targetData)`; must return `true` to allow opening another player's inventory. Removed with the resource. |
| `removeInspectionAccess(id)` / `RemoveInspectionAccess` | |

## Stashes (server)

| Export | Notes |
| --- | --- |
| `registerStash(id, label, slots, maxWeight, owner, groups, coords, distance)` | `owner = true` registers a per-citizen template. Returns the inventory key. |
| `registerStashPolicy(id, options, callback)` | Returns `true, inventoryKey` or `false, error`. |
| `rebindStashPolicy(id, callback)` | Replaces an already persisted policy's callback for its owning resource. |
| `unregisterStashPolicy(id)` | Closes access and keeps the required marker. |
| `setStashBlocked(id, blocked)` | Returns `true` once the block is durably saved. |
| `ClaimStash(source, id, operationKey)` / `claimStash` | Moves all stash items to the player in one checked SQL transaction. |
| `stashGet(id)` / `GetStashItems`, `stashSet(id, items)` / `SetStashItems` | Read or replace stash contents. |
| `stashOpen(src, id, opts?)` | Opens the stash for a player (server side). |
| `createTemporaryStash(properties)` / `CreateTemporaryStash` | Returns an inventory key; not persisted unless `persistTemporary` is on. |

Details: [Stashes and drops](./stashes-and-drops.md).

## Shops and drops (server)

| Export | Notes |
| --- | --- |
| `registerShop(id, data)` / `RegisterShop` | `data.slots`, `data.inventory` (or `items`), `prices`, `currency`, `coords`, `distance`, `weightLimit`. Returns the key or `nil, reason`. |
| `shopGet(id)` / `GetShopItems`, `shopSet(id, items)` / `SetShopItems` | Read or replace a registered shop's stock. Unknown ids are rejected. |
| `buyItem(src, shopId, slot, count?)` / `BuyItem` | Opens the shop for the player and performs the full purchase, including taking payment. |
| `dropCreate(coords, items, bucket?)` | Returns the drop id. |
| `dropTake(src, dropId, slot, amount?)` | |

Details: [Shops](./shops.md), [Stashes and drops](./stashes-and-drops.md).

## Crafting and weapons (server)

`RegisterCraftRecipe`, `RemoveCraftRecipe`, `GetCraftRecipe`, `CanCraftRecipe`, `CanCraftItems`, `CraftItem`, `RegisterCraftHook`, `RemoveCraftHook` (see [Crafting](./crafting.md)); `PrepareWeaponMetadata`, `GetWeaponState`, `SetWeaponState`, `ConsumeWeaponDurability`, `SetWeaponAmmo`, `SetWeaponComponents`, `LoadWeaponRounds`, `FireWeaponRound`, `GetCarriedWeapons`, `GetEquippedWeapon`, `StartTrainingWeapon`, `StopTrainingWeapon` (see [Weapons](./weapons.md)).

## Exchanges and items (server)

| Export | Notes |
| --- | --- |
| `ExecutePlayerExchange(source, operationKey, request)` | Callers must be in `exchangeCallers`. See [Player exchanges](./exchanges.md). |
| `GetPlayerExchange(operationKey)` | Reads the calling resource's receipt. |
| `ImportOxItems(definitions, opts?)` / `importOxItems` | Registers ox `data/items.lua` entries into kora_core's item registry. Existing items are skipped unless `opts.overwrite`. Returns `registered, errors`. See [Items](./items.md). |

## Internal bridge exports (server)

Not for general use: `physicalCashGet`, `physicalCashAdd`, `physicalCashRemove`, `physicalCashSet`, `physicalCashTransfer`, `physicalCashImport`, `physicalCashCanImport` (private bridge for kora_core's physical cash), `PhoneItemTransaction` / `phoneItemTransaction`, `getPersistenceStatus`, and `deleteLegacyPoliceTrash`.

## Client exports

| Export | Notes |
| --- | --- |
| `openInventory(invType, data?)` | Asks the server to open `player`, `stash`, `shop`, `drop`, `trunk`, `glovebox` and other types. The server decides. |
| `closeInventory()` | |
| `submitIntent(intent)` | Used by the bundled NUI bridge. |
| `getCurrentSession()` | |
| `HasItem(names, amount?)` | Reads the local session snapshot. |
| `giveTargetAvailable`, `requestGiveTarget`, `cancelGiveTarget` | Give-target selection used by the UI bridge. |
| `getConfigWeaponAttachments()` | Legacy `qb-weapons` attachment config, derived from the configured component allow-lists. |
| `fftVersion()`, `fftAction(action, item, amount)` | Only when FFT hooks are enabled, see [FFT hooks](./fft.md). |

Modules such as `KoraInventory.containers`, `KoraInventory.evidence` and `KoraInventory.vehicles.registerAccess` are Lua globals inside this resource's server realm and are not exported. See [Containers and evidence](./containers-evidence.md) and [Vehicles](./vehicles.md).
