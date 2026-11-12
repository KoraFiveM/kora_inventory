---
title: Compatibility
sidebar_position: 7
---

# Compatibility identities

`fxmanifest.lua` declares `provide 'qb-inventory'`, `provide 'ox_inventory'` and `provide 'qb-weapons'`. Resources calling those names reach kora_inventory. The qb and ox surfaces are published as separate identities by `server/compat/providers.lua` (a namespace distinct from kora_inventory's own exports), so same-named functions keep their different upstream signatures and return shapes. A compat module never calls `exports()` itself.

The exact names are pinned in `test/contracts/upstream.lua` (qb-inventory commit `5edddc3`, ox_inventory commit `ce8ad4c`) and checked by `test/smoke/provider_contract.lua`.

## qb-inventory

Server exports: `AddHook`, `AddItem`, `AddListener`, `AddToStash`, `CanAddItem`, `ClearInventory`, `ClearStash`, `CloseInventory`, `CreateInventory`, `CreateShop`, `GetFirstSlotByItem`, `GetFreeWeight`, `GetInventory`, `GetItemByName`, `GetItemBySlot`, `GetItemCount`, `GetItemsByName`, `GetSlots`, `GetSlotsByItem`, `GetTotalWeight`, `HasItem`, `LoadInventory`, `OpenInventory`, `OpenInventoryById`, `OpenShop`, `RemoveFromStash`, `RemoveHook`, `RemoveInventory`, `RemoveItem`, `RemoveListener`, `SaveInventory`, `SetInventory`, `SetItemData`, `UseItem`. Client: `HasItem`.

- `AddItem` and `RemoveItem` accept a player source or a stash, `trunk-<plate>`, `glovebox-<plate>`, `drop-<id>` or temporary identifier. Unknown inventories are refused; shops, evidence, confiscation and portable containers are not reachable. `RemoveItem` without a slot drains matching slots.
- `HasItem` accepts string, array and `name = count` forms, counted across slots.
- `OpenInventory(src)` with no identifier opens the player's own inventory. `CreateInventory` on an existing stash refreshes label, slots and max weight.
- Legacy `qb-inventory:server:OpenInventory` / `inventory:server:OpenInventory` (`type, id`) open only inventories the server already knows, through the normal checks; client-supplied capacity or stock is ignored, and trunk and glovebox are refused.
- Hooks `ItemMoved`, `ItemDropped`, `ItemUsed`, `ItemBought`, `ItemAdded`, `ItemRemoved`, `InventoryOpened`, `ShopOpened` are implemented on top of the ox hook engine. Opening the player's own inventory raises no `InventoryOpened`.
- Client events handled: `qb-inventory:client:openInventory`, `closeInv`, `updateInventory`, `ItemBox`, `requiredItems`, `giveAnim` plus the `inventory:client:*` aliases; `hotbar`, `setupDropTarget`, `removeDropTarget` and `qb-inventory:server:RobPlayer` are no-ops. Server events: `qb-inventory:server:closeInventory`, `useItem`, `UseItem`, `openDrop`, `openVending`, `OpenInventory` and `SetIsOpenState` (no-op).
- Callbacks: `qb-inventory:server:GetCurrentDrops`, `createDrop`, `attemptPurchase`, `giveItem`.

## ox_inventory

Server and client exports listed in `test/contracts/upstream.lua` are provided (for example `Items`, `ItemList`, `Search`, `GetItemCount`, `RegisterShop`, `RegisterStash`, `CreateTemporaryStash`, `CustomDrop`, `CreateDropFromPlayer`, `registerHook`, `removeHooks`, `useItem` on the server; `openInventory`, `closeInventory`, `Progress`, `Keyboard`, `notify` and others on the client). The client adapters map ox notification positions onto kora_lib placements (`center-left` and `center-right` keep their side but use the top edge), preserve multi-select input rows and map progress scenarios and props onto kora_lib.

## qb-weapons

kora_inventory provides `qb-weapons` so resources that only depend on it keep starting. It accepts the legacy draw, holster, ammo, durability and read-only ammo callback names and routes them to the current lifecycle. Legacy client item tables are reduced to a slot and the real item is read from the player's inventory; reported ammo can only decrease and reported quality can only consume durability. The repair-station and attachment-item systems are not recreated: the old repair and attachment callbacks are registered and refuse. The client export `getConfigWeaponAttachments` is derived from the explicit component allow-lists.

## Deliberate divergences from upstream

| Area | Upstream | Here |
| --- | --- | --- |
| `SetInventoryData` | Trusts client inventory ids. | Translated onto the validated transfer funnel; only the two inventories of the caller's own session. |
| `Inventories`, `Drops`, `RegisteredShops` globals | Mutable tables other resources write to. | Not exposed. |
| `qb-inventory:server:updateDrop` | Writes drop coordinates from the client. | Inert no-op. |
| `qb-inventory:server:snowball` | Grants a weapon on a client event. | Inert no-op. |
| `SaveInventory(source, offline)` | Writes player items. | Flushes secondary inventories only; kora_core owns player persistence. |
| `GetCurrentDrops`, `createDrop` | Return contents or a networked bag. | Return ids without contents. |
| `updateInventory` | Refreshes the UI. | No-op for the server event; the session stream keeps the UI current. |
| Give distance | 5.0 | `interactionDistance` (3.0). |
| ox `GetInventory` / `Inventory` | Live instance with methods. | Detached snapshot. |
| ox `SetSlotCount`, `SetMaxWeight` | Resizes any inventory. | Refuses player inventories. |
| ox `SetMetadata` | Accepts `metadata.weight`. | Rejects it. |
| ox `addCash`, `removeCash`, `getBank`, `getCards`, `giveCard` | Work on `money` or card items. | Routed to kora_core accounts. |

Item definitions for the ox identity come from kora_core's registry, not `data/items.lua`; use `ImportOxItems` to bring ox definitions over (see [Items](./api/items.md)).
