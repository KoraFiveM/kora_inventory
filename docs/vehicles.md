---
title: Vehicles
sidebar_position: 10
---

# Vehicle storage

`server/vehicles.lua` is the trunk and glovebox domain. It derives persistent keys `trunk:<PLATE>` and `glovebox:<PLATE>` from a live, server-resolved vehicle entity. A client open request may contain only a network id; plate, class, coordinates and capacity are never accepted from the client.

Before opening, and again on every access in an active session, the server verifies the entity exists and is a vehicle, the player entity, routing bucket, server-side range, native plate, vehicle class and configured capacity. Plates are trimmed, upper-cased, whitespace-normalised and restricted to the GTA plate alphabet before becoming a key.

Open from another resource with `exports.kora_inventory:openInventory('trunk', netId)` (or `'glovebox'`) on the client; this works even with `vehicles.enabled = false`.

## Capacity

`Config.kora_inventory.vehicles.classes` maps a GTA vehicle class number to `trunk` and `glovebox` rows of `slots` and `maxWeight`. A required `default` row covers unknown classes (`unknownClassFallback`). Set a storage type to `false` to disable it for the class (motorcycles, cycles, trains and the like ship disabled; boats, helicopters and planes have no glovebox).

## Access policy

For ownership, keys or faction rules set `vehicles.ownerCheck` and/or `vehicles.accessCheck` to trusted server callbacks. A callback returning `false, reason` denies. `KoraInventory.vehicles.registerAccess(callback, options)` (options: `kind`, `class`, `plate`) is available to code running in this resource's server realm; it is a Lua global of this resource and is **not** an export.

When `respectLocks` is on, the server refuses the trunk of a locked vehicle. A vehicle is locked when the `kora_vehiclekeys:locked` entity state says so, otherwise by the native door lock status. The glovebox needs the player seated in the vehicle (`gloveboxRequireSeated`).

## Opening with the inventory key

`client/vehicles.lua` hooks the inventory key (`TAB`) before the player inventory:

- Seated in a vehicle: opens the glovebox.
- On foot within `bootReach` of the boot: opens the trunk. The boot is the rear bumper, or the front for the models in `frontBootModels`. Classes in `bootSkipClasses` are ignored.
- A locked vehicle refuses the trunk with a notice; the server enforces this too unless `respectLocks = false`.

With `trunkAnimation.enabled` the player turns to the boot, the boot (bonnet for `frontBootModels`) opens and an animation loops while the panel is open. The door is closed again, only if this feature opened it, when the session closes for any reason, the player dies or walks away, or the resource stops. Trunks opened by other resources through `openInventory` are not animated; the glovebox is never animated.

## Trunk and hood toggles

`client/vehicle_doors.lua` (needs `kora_target`) adds, under `vehicles.doors`:

- ALT menu: aiming at the trunk lists Open/Close trunk and Trunk storage; aiming at the hood lists Open/Close hood. The aimed point must be within `partDepth` metres of the vehicle's end near its centre line, and an entry is hidden if the vehicle has no such lid.
- `/trunk` and `/hood` toggle from the driver seat only (names from `commandNames`, read once at start).
- Doors are changed after taking network control, so everyone sees the same state. With `doors.respectLocks` a locked vehicle cannot be opened from outside; closing, and opening from inside, is always allowed.

Text lives in `locales/en.json` under `vehicle_doors`.
