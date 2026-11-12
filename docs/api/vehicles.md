---
title: "Vehicle storage"
sidebar_position: 12
---


# Vehicle storage

Trunks and gloveboxes are inventories keyed by a vehicle's plate: `trunk:<PLATE>` and `glovebox:<PLATE>`. A client may only name a vehicle by network id; the server derives the plate, GTA class, coordinates, lock state and capacity from the live entity and re-validates on every request. This module also owns the inventory-key behaviour (TAB seated opens the glovebox, TAB at the boot opens the trunk) and the trunk/hood door toggles. Its Lua table is resource-internal; other resources interact through configuration callbacks and `openInventory`.

Namespace: `KoraInventory.vehicles` · Source: `server/vehicles.lua, client/vehicles.lua, client/vehicle_doors.lua`

## How it works

Opening runs `vehicles.validate`: the network id must resolve to an existing vehicle entity within distance (`distance` for gloveboxes, `trunkDistance` for trunks) and routing bucket; the plate is normalised (trimmed, upper-cased, at most `plateMaxLength`); the class comes from kora_lib's vehicle lookup (unknown classes use the `default` row unless `unknownClassFallback = false`); a locked vehicle refuses trunk access when `respectLocks` is on; then `ownerCheck`, `accessCheck` and any registered access hooks must all pass. The inventory record is created or refreshed with the class capacity and an access function that revalidates the same vehicle and plate for every later request. Storage is persisted and survives vehicle respawns because it is keyed by plate.

## How a trunk opens

1. **Player aims for the boot** — Pressing TAB on foot within `bootReach` of a boot (rear, or front for `frontBootModels`) or choosing "Trunk storage" in the ALT menu.
2. **Client sends only the network id** — `openInventory('trunk', netId)`. An un-networked vehicle shows "This vehicle has no storage you can open."
3. **Server validates** — `vehicles.validate` resolves entity, distance, plate, class, lock and your policy callbacks.
4. **Animation and session** — The panel opens; the player turns to the boot, the lid opens and the animation loops until the session ends.

## Terms used on this page

| Term | Meaning |
| --- | --- |
| Boot position | World position computed from the model dimensions: beyond the rear bumper, or beyond the nose for front-boot models. |
| Class row | The `{ trunk, glovebox }` capacities for a GTA vehicle class in `vehicles.classes`. |
| Vehicle descriptor | The server-generated table passed to access callbacks: `entity, netId, plate, class, kind, coords, distance, slots, maxWeight`. |

## Functions

These functions live on the resource-internal `KoraInventory.vehicles` table and are not exports. They are documented for maintainers and for understanding behaviour; external resources use `openInventory('trunk', netId)` on the client or `Config.kora_inventory.vehicles.ownerCheck/accessCheck`.

### `KoraInventory.vehicles.open(src, kind, networkId)`

Validates and opens a vehicle inventory for a player. Reached from `openInventory(src, 'trunk' | 'glovebox', netId)`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `kind` | string | `trunk` or `glovebox`. |
| `networkId` | integer | Vehicle network id. |

**Returns**

- **opened** — boolean.
- **result** — session payload or a reason: `invalid vehicle storage type`, `invalid vehicle entity`, `entity is not a vehicle`, `vehicle does not exist`, `player entity unavailable`, `different routing bucket`, `too far away`, `invalid vehicle plate`, `invalid vehicle class`, `vehicle storage unavailable`, `vehicle is locked`, or an access callback reason.

**Example**

```lua
-- client
exports.kora_inventory:openInventory('trunk', NetworkGetNetworkIdFromEntity(vehicle))
```

**Representative console output**

```text
The server opens trunk:<PLATE> next to the player's inventory if every check passes.
```

### `KoraInventory.vehicles.validate(src, kind, networkId, expectedPlate?)`

Resolves a live vehicle for a player and returns its descriptor. `expectedPlate` is used internally to make sure the same vehicle is still being accessed.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `kind` | string | `trunk` or `glovebox`. |
| `networkId` | integer | Vehicle network id. |
| `expectedPlate?` | string | Internal revalidation value; never accepted from a client. |

**Returns**

- **vehicle** — descriptor `{ entity, netId, plate, class, kind, coords, distance, slots, maxWeight }`.
- **reason** — one of the reasons listed for `vehicles.open`.

**Example**

```lua
local vehicle, why = KoraInventory.vehicles.validate(src, 'trunk', netId)
```

**Representative console output**

```text
vehicle = { plate = 'ABC 123', class = 1, slots = 40, maxWeight = 40000, ... }
```

### `KoraInventory.vehicles.registerAccess(callback, options?)`

Registers a runtime access check for vehicle storage, optionally scoped. Every matching hook must allow. Resource-internal; use `Config.kora_inventory.vehicles.ownerCheck/accessCheck` from outside.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `callback` | function | `callback(source, vehicle)`; return false (optionally `false, reason`) to deny. |
| `options?` | table | `kind` (`trunk`/`glovebox`), `class` (integer), `plate`. |

**Returns**

- **hookId** — integer.
- **Raises a Lua error for an invalid callback, kind, class or plate.**

**Example**

```lua
local id = KoraInventory.vehicles.registerAccess(function(source, vehicle)
    return exports.kora_vehiclekeys:hasKey(source, vehicle.plate), 'you do not have the keys'
end, { kind = 'trunk' })
```

**Representative console output**

```text
hookId = 1
```

### `KoraInventory.vehicles.removeAccess(id)`

Removes a runtime access check. Only its registering resource may remove it.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | integer | Hook id. |

**Returns**

- **removed** — true; false when unknown; false with `not hook owner`.

**Example**

```lua
KoraInventory.vehicles.removeAccess(id)
```

**Representative console output**

```text
true
```

### `KoraInventory.vehicles.capacity(kind, class)`

Looks up the configured slots and weight for a storage kind and class.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `kind` | string | `trunk` or `glovebox`. |
| `class` | integer \| nil | GTA vehicle class; nil uses the default row. |

**Returns**

- **capacity** — `{ slots, maxWeight }`.
- **reason** — `invalid vehicle storage type`, `invalid vehicle class`, `vehicle storage unavailable` (the row is false), `invalid vehicle capacity configuration`.

**Example**

```lua
local capacity = KoraInventory.vehicles.capacity('trunk', 2)
```

**Representative console output**

```text
{ slots = 50, maxWeight = 60000 }
```

### `KoraInventory.vehicles.normalisePlate(value)`

Normalises a native plate through kora_lib (trim, upper-case, collapse whitespace, strip key separators, limit to `plateMaxLength`).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `value` | string | Raw plate text. |

**Returns**

- **plate** — normalised plate, or nil with `invalid vehicle plate`.

**Example**

```lua
local plate = KoraInventory.vehicles.normalisePlate(' abc  123 ')
```

**Representative console output**

```text
ABC 123
```

### `KoraInventory.vehicles.inventoryKey(kind, plate)`

Builds the storage key for a plate.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `kind` | string | `trunk` or `glovebox`. |
| `plate` | string | Plate text. |

**Returns**

- **key** — `trunk:ABC 123`, or nil with a reason.

**Example**

```lua
local key = KoraInventory.vehicles.inventoryKey('glovebox', 'ABC 123')
```

**Representative console output**

```text
glovebox:ABC 123
```

### `KoraInventory.vehicles.modelClass(model)`

Resolves a model hash to its GTA vehicle class through kora_lib's lookup. Never raises; a failed lookup logs once per model and returns nil.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `model` | integer | Model hash. |

**Returns**

- **class** — integer or nil.

**Example**

```lua
local class = KoraInventory.vehicles.modelClass(GetEntityModel(vehicle))
```

**Representative console output**

```text
1
```

## Common use cases

- Persistent trunk and glovebox storage that follows the plate.
- Ownership or key checks before a trunk opens.
- Custom capacities per vehicle class.

## Limits and related APIs

The vehicle domain is a resource-internal table, so external resources cannot call `registerAccess` directly; they configure `ownerCheck` / `accessCheck` in `config.lua` or open storage through the client export. Vehicles without a network id cannot open storage. Motorcycles, cycles and trains have no boot by default (`bootSkipClasses`). The storage record is shared by every vehicle with the same plate. Locked-state detection reads the `kora_vehiclekeys:locked` state bag first, then the native door lock status.

## Related guides

- [Configuration](./configuration.md)
- [Client API](./client-api.md)
- [Opening inventories](./inventories.md)

## Operating notes (from the code)

Facts below were written from the current code of this resource; they add to, and where noted refine, the reference above.

`server/vehicles.lua` is the trunk and glovebox domain. It derives persistent keys `trunk:<PLATE>` and `glovebox:<PLATE>` from a live, server-resolved vehicle entity. A client open request may contain only a network id; plate, class, coordinates and capacity are never accepted from the client.

Before opening, and again on every access in an active session, the server verifies the entity exists and is a vehicle, the player entity, routing bucket, server-side range, native plate, vehicle class and configured capacity. Plates are trimmed, upper-cased, whitespace-normalised and restricted to the GTA plate alphabet before becoming a key.

Open from another resource with `exports.kora_inventory:openInventory('trunk', netId)` (or `'glovebox'`) on the client; this works even with `vehicles.enabled = false`.

### Capacity

`Config.kora_inventory.vehicles.classes` maps a GTA vehicle class number to `trunk` and `glovebox` rows of `slots` and `maxWeight`. A required `default` row covers unknown classes (`unknownClassFallback`). Set a storage type to `false` to disable it for the class (motorcycles, cycles, trains and the like ship disabled; boats, helicopters and planes have no glovebox).

### Access policy

For ownership, keys or faction rules set `vehicles.ownerCheck` and/or `vehicles.accessCheck` to trusted server callbacks. A callback returning `false, reason` denies. `KoraInventory.vehicles.registerAccess(callback, options)` (options: `kind`, `class`, `plate`) is available to code running in this resource's server realm; it is a Lua global of this resource and is **not** an export.

When `respectLocks` is on, the server refuses the trunk of a locked vehicle. A vehicle is locked when the `kora_vehiclekeys:locked` entity state says so, otherwise by the native door lock status. The glovebox needs the player seated in the vehicle (`gloveboxRequireSeated`).

### Opening with the inventory key

`client/vehicles.lua` hooks the inventory key (`TAB`) before the player inventory:

- Seated in a vehicle: opens the glovebox.
- On foot within `bootReach` of the boot: opens the trunk. The boot is the rear bumper, or the front for the models in `frontBootModels`. Classes in `bootSkipClasses` are ignored.
- A locked vehicle refuses the trunk with a notice; the server enforces this too unless `respectLocks = false`.

With `trunkAnimation.enabled` the player turns to the boot, the boot (bonnet for `frontBootModels`) opens and an animation loops while the panel is open. The door is closed again, only if this feature opened it, when the session closes for any reason, the player dies or walks away, or the resource stops. Trunks opened by other resources through `openInventory` are not animated; the glovebox is never animated.

### Trunk and hood toggles

`client/vehicle_doors.lua` (needs `kora_target`) adds, under `vehicles.doors`:

- ALT menu: aiming at the trunk lists Open/Close trunk and Trunk storage; aiming at the hood lists Open/Close hood. The aimed point must be within `partDepth` metres of the vehicle's end near its centre line, and an entry is hidden if the vehicle has no such lid.
- `/trunk` and `/hood` toggle from the driver seat only (names from `commandNames`, read once at start).
- Doors are changed after taking network control, so everyone sees the same state. With `doors.respectLocks` a locked vehicle cannot be opened from outside; closing, and opening from inside, is always allowed.

Text lives in `locales/en.json` under `vehicle_doors`.
