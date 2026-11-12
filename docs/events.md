---
title: Events
sidebar_position: 6
---

# Events, callbacks and state

Most network events below are internal transport between the bundled client and the server. They check `GetInvokingResource()` so another resource cannot call them, and every payload is treated as an intent that the server validates. Integrations should use the [exports](./exports.md) and the server events in the first table.

## Server events (local, for other resources to listen to)

Fired with `TriggerEvent` on the server; listen with `AddEventHandler`.

| Event | Arguments | When |
| --- | --- | --- |
| `kora_inventory:server:ready` | `status` | Secondary inventories were restored from the database. |
| `kora_inventory:server:persistenceReady` | `reports` | Schema setup finished (kora_inventory listens to this itself). |
| `kora_inventory:server:persistenceRejected` | `bad` | A persisted row was malformed and ignored. |
| `kora_inventory:server:migrationProgress` | `report, source, phase, row` | Progress of `kora_inventory-migrate`. |
| `kora_inventory:server:sessionOpened` | `src, payload` | A session opened. |
| `kora_inventory:server:sessionClosed` | `src, session, reason` | A session closed. |
| `kora_inventory:server:itemsMoved` | `src, payload` | After a committed move, swap, stack or give. |
| `kora_inventory:server:itemPurchased` | `src, purchase` | After a shop purchase: `shopId`, `itemName`, `count`, `metadata`, `price` (total). |
| `kora_inventory:server:usedItem` | `src, itemName, item` | After a successful item use. |
| `kora_inventory:server:openedContainer` | `src, itemName, item` | A configured portable container item was opened. |
| `kora_inventory:server:audit` | `action, src, details` | Every recorded audit entry (note the argument order). |
| `kora_inventory:server:crafted` | `src, recipeId, result` | After a successful craft. |
| `kora_inventory:server:weaponStateChanged` | `src, slot, info` | Weapon metadata was changed through the weapon API. |
| `kora_inventory:server:weaponRoundFired` | `src, round` | One accepted shot consumed a loaded round (ballistics). |
| `kora_inventory:server:trainingRoundFired` | `src, data` | A shot with a training weapon (see [Weapons](./weapons.md)). |
| `kora_inventory:server:evidenceMoved` | `action, source, target, evidenceId, item` | Evidence seized or released. |

The server also listens for `kora_core:server:inventoryChanged` (to advance revisions and refresh open panels after another resource changes a player's items through kora_core), `kora_core:server:playerLoaded`, `QBCore:Server:OnPlayerUnload` and `playerDropped`.

## Client to server (net events)

| Event | Payload | Purpose |
| --- | --- | --- |
| `kora_inventory:server:open` | `invType, data` | Ask to open an inventory; the server resolves and authorises it. |
| `kora_inventory:server:close` | `token` | Close the session with that token. |
| `kora_inventory:server:transfer` | `request` | Move, stack, swap items between the two inventories of a session. |
| `kora_inventory:server:intent` | `request` | `use`, `drop`, `give`, `buy` or `sync` with the session token. |
| `kora_inventory:server:call` | `requestId, action, request` | Direct transport used by the bundled UI (`action` is `transfer` or `intent`). |
| `kora_inventory:server:weaponToggled` | `slot` | Confirms a draw/holster that the server itself requested. |
| `kora_inventory:server:weaponUnequipped` | none | Payload-free: puts the weapon back on the player's own body. |
| `kora_inventory:server:weaponFired` | none | Shot report; the server resolves the weapon and rounds. |
| `kora_inventory:server:throwableThrown` | none | The drawn throwable was thrown. |
| `kora_inventory:server:weaponAmmoConsumed` | `slot, amount` | Can only lower the stored ammo of the server-confirmed drawn weapon. |
| `kora_inventory:server:legacyWeaponUse`, `legacyWeaponHolster` | `slot` / none | Used by the legacy `qb-weapons` client events. |
| `QBCore:Server:UseItem` | `item` | Legacy use event; only the slot is read, the item is re-resolved. Also used by the hotbar keys. |

## Server to client (net events)

| Event | Payload | Purpose |
| --- | --- | --- |
| `kora_inventory:client:sessionOpened` | `payload` | `token`, `primary`, `secondary`, `expires`. |
| `kora_inventory:client:sessionPatched` | `token, patch` | Revisioned replacement view after a change. |
| `kora_inventory:client:sessionClosed` | `token, reason` | |
| `kora_inventory:client:rejected` | `reason` | A request was refused. |
| `kora_inventory:client:callResult` | `requestId, ok, result` | Answer to `kora_inventory:server:call`. |
| `kora_inventory:client:itemBox` | `payload` | Item receipt. |
| `kora_inventory:client:dropCreated`, `dropRemoved`, `dropsUpdated` | `id, coords` / `id` / `list` | Ground drop presence (ids and coordinates only). |
| `kora_inventory:client:toggleWeapon`, `weaponRemoved`, `addAmmo` | request / name / request | Weapon draw, forced holster, ammo display. |
| `kora_inventory:client:startTrainingWeapon`, `stopTrainingWeapon` | name, rounds, damage / none | Training weapon control. |

Client-side net events that open the bundled shops: `kora_inventory:client:openAmmunation`, `openLiquorStore` and `openConvenienceStore` (each only calls `openInventory('shop', id)`; the server repeats all location checks).

## Local client events (renderer contract)

Fired after the server resolves a request, for any renderer to consume: `kora_inventory:ui:sessionOpened` (`{ token, primary, secondary, expires }`), `kora_inventory:ui:sessionPatched` (`{ token, patch }`), `kora_inventory:ui:sessionClosed` (`{ token, reason }`), `kora_inventory:ui:rejected` (`{ reason }`). Other local events: `kora_inventory:client:submitIntent` (the only way the NUI bridge forwards an intent), `kora_inventory:client:requestGiveAvailability`, `requestGiveTarget`, `cancelGiveTarget` and `giveTargetResolved`, `kora_inventory:client:useStarted` and `useRejected`.

## Callbacks (`Kora.callback`)

| Callback | Side | Purpose |
| --- | --- | --- |
| `kora_inventory:server:open`, `transfer`, `intent` | server | Third-party renderer transport; the bundled UI uses direct events by default. |
| `kora_inventory:server:drops` | server | Returns ids and coordinates of drops in the caller's bucket. Never contents. |
| `kora_inventory:client:useParachute` | client | Used by the server parachute handler. |
| `qb-inventory:server:GetCurrentDrops`, `createDrop`, `attemptPurchase`, `giveItem` | server | qb-inventory compatibility, see [Compatibility](./compatibility.md). |
| `qb-weapons:server:GetConfig`, `weapon:server:GetWeaponAmmo`, `qb-weapons:server:RepairWeapon`, `RemoveAttachment` | server | Legacy qb-weapons callbacks. The repair and attachment ones refuse. |

## State bags and metadata read or written

| Name | Direction | Meaning |
| --- | --- | --- |
| `kora_inventory:weaponCarry` (player state) | written by server | Carried weapon list; clients only render it. Cleared with `false`. |
| `inv_busy` (`LocalPlayer.state`) | written by client | True while a kora_inventory UI session is open. |
| `koraCuffed` (player state), `ishandcuffed` metadata | read | Cuffed block. |
| `isdead`, `inlaststand` metadata | read | Downed block. |
| `koraUiBlocked` (name from `uiBlockBag`) | read | Generic UI block. |
| `kora_vehiclekeys:locked` (entity state) | read | Locked vehicle detection. |
| `fftSession` | read | Only with FFT hooks. |
