---
title: "qb-weapons compat"
sidebar_position: 23
---


# qb-weapons compat

kora_inventory provides `qb-weapons` so resources that only depend on the retired resource still start. These are adapters, not a second weapon controller: every weapon is still a kora_inventory item with its own draw record and canonical metadata. A table received from a client contributes at most a slot; weapon name, serial, quality, attachments and ammo count are never authority.

Namespace: `qb-weapons` · Source: `server/compat/qb_weapons.lua`

## How it works

The adapters re-resolve the slot against the player's real items and, for shot or ammo reports, against the weapon the server itself recorded as drawn. Ammo and quality reports can only lower stored values; repairs and attachments must go through the native `SetWeaponState` after your own server-side checks.

## Migrating off qb-weapons

1. **Keep the dependency** — Declaring `qb-weapons` still resolves to kora_inventory.
2. **Replace repairs and attachments** — Call `SetWeaponState` / `SetWeaponComponents` from your server code after payment and permission checks.
3. **Stop sending client weapon tables** — Send a slot only.

## Terms used on this page

| Term | Meaning |
| --- | --- |
| Legacy weapon table | The old `{ name, slot, info }` payload. Only `slot` is read. |

## Functions

Net events and callbacks kept for old clients and scripts.

### `Kora.callback.register('qb-weapons:server:GetConfig', function() end)`

Callback answered with an empty table so a leftover caller does not hang.

**Parameters**



**Returns**

- **config** — `{}`.

**Example**

```lua
local config = Kora.callback.trigger('qb-weapons:server:GetConfig')
```

**Representative console output**

```text
{}
```

### `Kora.callback.register('weapon:server:GetWeaponAmmo', function(src, legacy) end)`

Returns the stored ammo and name of the weapon in the slot named by `legacy` (a slot or `{ slot }`).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `legacy` | integer \| table | Slot or table with `slot`. |

**Returns**

- **ammo** — integer (0 when not a weapon).
- **name** — weapon item name or nil.

**Example**

```lua
local ammo, name = Kora.callback.trigger('weapon:server:GetWeaponAmmo', 1)
```

**Representative console output**

```text
12, weapon_pistol
```

### `Kora.callback.register('qb-weapons:server:RepairWeapon', function() end)`

Answered with false: repairs and attachment removal were world systems of qb-weapons and cannot be authorised by a client callback.

**Parameters**



**Returns**

- **result** — false.

**Example**

```lua
local ok = Kora.callback.trigger('qb-weapons:server:RepairWeapon')
```

**Representative console output**

```text
false
```

### `RegisterNetEvent('kora_inventory:server:legacyWeaponUse', function(value) end)`

Uses the weapon in the named slot (draw or holster). Sent by the client compat for `qb-weapons:client:UseWeapon` and `AddAmmo`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `value` | integer \| table | Slot or `{ slot }`. |

**Returns**

- **No return value.**

**Example**

```lua
-- client
TriggerServerEvent('kora_inventory:server:legacyWeaponUse', 1)
```

**Representative console output**

```text
The weapon is drawn.
```

### `RegisterNetEvent('kora_inventory:server:legacyWeaponHolster', function() end)`

Holsters the weapon the server recorded as drawn.

**Parameters**



**Returns**

- **No return value.**

**Example**

```lua
-- client
TriggerServerEvent('kora_inventory:server:legacyWeaponHolster')
```

**Representative console output**

```text
The drawn weapon is holstered.
```

### `RegisterNetEvent('qb-weapons:server:UpdateWeaponAmmo', function(legacy, amount) end)`

Lower-only ammo update for the drawn weapon: the stored ammo is lowered to `amount` when it is smaller, never raised.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `legacy` | integer \| table | Slot. |
| `amount` | integer | Reported ammo. |

**Returns**

- **No return value.**

**Example**

```lua
TriggerServerEvent('qb-weapons:server:UpdateWeaponAmmo', 1, 8)
```

**Representative console output**

```text
Stored ammo becomes 8 if it was higher.
```

### `RegisterNetEvent('qb-weapons:server:UpdateWeaponQuality', function(legacy, amount) end)`

Wears the drawn weapon by `amount` percentage points (at most 100). It cannot improve quality.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `legacy` | integer \| table | Slot. |
| `amount` | integer | Points to subtract. |

**Returns**

- **No return value.**

**Example**

```lua
TriggerServerEvent('qb-weapons:server:UpdateWeaponQuality', 1, 2)
```

**Representative console output**

```text
Durability drops by 2.
```

### `RegisterNetEvent('qb-weapons:server:removeWeaponAmmoItem', function(legacy) end)`

Uses the real ammunition item in the named slot (equivalent to pressing Use; inherits the drawn-weapon and ammo-type checks).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `legacy` | integer \| table | Slot of the ammo item. |

**Returns**

- **No return value.**

**Example**

```lua
TriggerServerEvent('qb-weapons:server:removeWeaponAmmoItem', 5)
```

**Representative console output**

```text
The magazine is loaded and consumed.
```

### `RegisterNetEvent('qb-weapons:server:SetWeaponQuality', function() end)`

Deliberate no-ops: an arbitrary client HP value would allow self-repair, and the repair collection flow no longer exists.

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

## Common use cases

- Keeping stock weapon scripts running while their server code is migrated.

## Limits and related APIs

The client half (`qb-weapons:client:UseWeapon`, `AddAmmo`, `CheckWeapon`, `EquipTint`, plus no-ops `SetCurrentWeapon`, `SetWeaponQuality`, `SyncRepairShops`) lives in `client/compat/qb_weapons.lua` and the `getConfigWeaponAttachments` client export is documented under Client API. Repairs and attachments are not supported through compat events.

## Related guides

- [Weapons and weapon carry](./weapons.md)
- [Client API](./client-api.md)
