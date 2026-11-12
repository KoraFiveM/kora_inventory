---
title: "Weapons and weapon carry"
sidebar_position: 11
---


# Weapons and weapon carry

kora_inventory owns the weapon lifecycle: weapon items carry canonical server metadata (serial, durability, ammo, per-round records, tint, components), drawing and holstering is a timed, server-requested action, owned weapons are rendered on the player's body for everyone nearby, and every accepted shot is recorded by the server. This page lists the server exports for reading and changing weapon state, the carried-weapon queries and temporary training weapons.

Namespace: `exports.kora_inventory` · Source: `server/crafting.lua (weapons table), server/weaponcarry.lua, server/useables.lua`

## How it works

Using a weapon item asks the client to play a draw or holster animation (`drawTime`, `holsterTime`, plus `concealedDrawTime` when the weapon sits outside the hotbar in `hotbar` visibility mode). Only after the client confirms with `kora_inventory:server:weaponToggled` for the slot the server asked about, and the item is still in that slot, does the server record the weapon as equipped and republish the carried list on the replicated player state bag `kora_inventory:weaponCarry`. Shots are reported by the client with no payload; the server rate-limits them (`ballistics.shotCooldown`), removes the first recorded round from `info.loadedBullets`, applies configured durability wear, and fires `kora_inventory:server:weaponRoundFired`. Ammunition is only ever added by loading a magazine on the server. All weapon state writes go through one locked path that re-validates the metadata with `PrepareWeaponMetadata`, saves it to the item and fires `kora_inventory:server:weaponStateChanged`.

## Giving and managing a weapon

1. **Grant it** — `AddItem(src, 'weapon_pistol', 1)` is enough. The inventory adds a unique item and generates a serial, durability and empty magazine. Weapons added in bulk each get their own serial.
2. **Let the player draw it** — Use (Use button, hotbar key or `useItem`) runs the timed draw. The item stays in the slot while equipped.
3. **Load ammo** — Using a magazine item loads the drawn weapon if the ammo type matches.
4. **Change state from your own rules** — Repair, attachments and tint go through `SetWeaponState`; wear through `ConsumeWeaponDurability`.

## Terms used on this page

| Term | Meaning |
| --- | --- |
| Serial | A unique string generated on creation: `<SerialPrefix>-<WEAPONNAME>-<time>-<n>`. Existing serials are never rewritten. |
| Loaded bullets | The list of per-round records (`id, ammoType, lot`) in `info.loadedBullets`; `info.ammo` always equals its length when ballistics are on. |
| Tier | Where a weapon is worn and how it is drawn: `back`, `sling` or `hip`, chosen from its `weapontype` through `weaponCarry.tiers`. |
| Training weapon | A temporary weapon given by a resource that is not an inventory item and has a fixed number of rounds. |

## Weapon state table (SetWeaponState changes)

Only these fields can be changed through `SetWeaponState`. Anything else in the table is ignored.

| Option | Type | Description |
| --- | --- | --- |
| `durability` | number | Clamped 0 to 100. `quality` is mirrored automatically. |
| `ammo` | integer | Floored and clamped 0 to `weapons.maxAmmo`. With ballistics on, `loadedBullets` is trimmed or topped up with legacy-marked rounds to match. |
| `components` | string[] \| table&lt;string, boolean> | Component item names. Every name must be in the allow-list `weapons.components[weapon]` (or its `default` row). |
| `tint` | integer | Floored and clamped 0 to 32. |

## Canonical metadata (PrepareWeaponMetadata)

Called on every weapon that enters a player inventory (add, purchase, craft, give). It keeps a supplied serial, otherwise generates one (at most 96 characters); clamps `durability` (reading `quality` as a fallback) and `ammo`; normalises `loadedBullets` (old count-only weapons get one legacy-marked record per round); clamps `tint`; rejects components that are not allow-listed; and mirrors `quality = durability`. A non-weapon returns `item is not a registered weapon`.

## Shots and wear

The client reports `CEventGunShot` for its own ped as a payload-free `kora_inventory:server:weaponFired`. The server only accepts it when it already recorded that player as having a weapon drawn, consumes one stored round, subtracts `durability.perShot * multiplier` (unless excluded or disabled), and publishes the round to listeners with the weapon name and serial. With ballistics disabled, the older lower-only path stores the ped's ammo count, which can only decrease the saved value.

## Visible weapon carry

The server builds the carried list from the player's real items (slot order) and sets it on the state bag; clients render it as props attached to the body using the tier's attachment positions, skipping weapons in hand and weapons with no free position. `visibility = 'hotbar'` renders only slots `1..hotbarSlots`. A client cannot submit or edit the list; clearing uses an explicit `false`, never nil. When the inventory item moves, drops, is given or is removed, the server tells the client to strip the drawn weapon (`kora_inventory:client:weaponRemoved`).

## Damage tuning

The shared definition's `damageModifier` and `disableCriticalHits` are sent with each draw and applied client-side only while the weapon is in hand; they are reset when it is holstered or lost.

## Functions

All weapon exports are server-only and take a player source and an inventory slot. A client can never set weapon state; gameplay resources validate an action and then call these.

### `exports.kora_inventory:PrepareWeaponMetadata(name, metadata?)`

Returns canonical weapon metadata for a weapon item name: clamped, with a serial and normalised rounds. Use it when you build weapon tables yourself; the add paths already call it.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `name` | string | Weapon item name. |
| `metadata?` | table | Existing metadata to normalise. |

**Returns**

- **info** — the prepared metadata table.
- **reason** — `item is not a registered weapon`, `invalid weapon tint`, `weapon components are not configured`, `weapon component is not allowed`.

**Example**

```lua
local info, err = exports.kora_inventory:PrepareWeaponMetadata('weapon_pistol', { durability = 80 })
-- info.serial is set, info.quality == 80, info.ammo == 0
```

**Representative console output**

```text
info = { durability = 80, quality = 80, ammo = 0, loadedBullets = {}, components = {}, serial = 'KORA-WEAPONPISTOL-1767225600-482913' }
```

### `exports.kora_inventory:GetWeaponState(src, slot)`

Returns a copy of the metadata of the weapon in a player's slot.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `slot` | integer | Inventory slot. |

**Returns**

- **info** — metadata table, or nil if the slot is empty or not a weapon.

**Example**

```lua
local state = exports.kora_inventory:GetWeaponState(src, 1)
if state then print(state.durability, state.ammo, state.serial) end
```

**Representative console output**

```text
92.7 12 KORA-WEAPONPISTOL-1767225600-482913
```

### `exports.kora_inventory:SetWeaponState(src, slot, changes)`

Changes durability, ammo, components or tint of a weapon item in one locked, validated write.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `slot` | integer | Inventory slot of the weapon. |
| `changes` | table | See the weapon state table. |

**Returns**

- **updated** — true on success.
- **state** — the new metadata copy on success, or a reason: `invalid weapon state`, `invalid weapon slot`, `weapon not found`, `invalid weapon durability`, `invalid weapon ammo`, `invalid weapon tint`, `weapon components are not configured`, `weapon component is not allowed`, `over weight`, `inventory busy`.

**Example**

```lua
-- repair at a workshop after your own server-side payment check
local ok, state = exports.kora_inventory:SetWeaponState(src, slot, { durability = 100 })
```

**Representative console output**

```text
ok = true, state.durability = 100. `kora_inventory:server:weaponStateChanged` fires.
```

### `exports.kora_inventory:ConsumeWeaponDurability(src, slot, amount)`

Subtracts durability percentage points (never below 0), rounded to two decimals.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `slot` | integer | Weapon slot. |
| `amount` | number | Positive points to remove. |

**Returns**

- **updated** — true on success.
- **state** — new metadata copy, or `invalid durability amount`, `weapon not found`, `invalid weapon slot`.

**Example**

```lua
exports.kora_inventory:ConsumeWeaponDurability(src, slot, 5.0)
```

**Representative console output**

```text
true, with durability reduced by 5.
```

### `exports.kora_inventory:SetWeaponAmmo(src, slot, ammo)`

Sets the stored ammo count (equivalent to `SetWeaponState(src, slot, { ammo = ammo })`).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `slot` | integer | Weapon slot. |
| `ammo` | integer | New count. |

**Returns**

- **updated** — true on success.
- **state** — metadata copy or an error as `SetWeaponState`.

**Example**

```lua
exports.kora_inventory:SetWeaponAmmo(src, slot, 0)
```

**Representative console output**

```text
true; the magazine record list is emptied to match.
```

### `exports.kora_inventory:SetWeaponComponents(src, slot, components)`

Sets the attached components (equivalent to `SetWeaponState(src, slot, { components = ... })`). Every name must be allow-listed for that weapon.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `slot` | integer | Weapon slot. |
| `components` | string[] | Component item names. |

**Returns**

- **updated** — true on success.
- **state** — metadata copy or `weapon components are not configured` / `weapon component is not allowed`.

**Example**

```lua
local ok, state = exports.kora_inventory:SetWeaponComponents(src, slot, { 'suppressor_attachment' })
```

**Representative console output**

```text
ok = true if 'suppressor_attachment' is in `weapons.components[weapon]`; otherwise false, 'weapon component is not allowed'.
```

### `exports.kora_inventory:LoadWeaponRounds(src, slot, ammoType, count)`

Adds `count` independently identified rounds to a weapon. The caller has already proved the player owns the ammunition; this only checks the ammo type fits the weapon and capacity remains.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `slot` | integer | Weapon slot. |
| `ammoType` | string | Native ammo type, must equal the weapon definition's `ammotype`. |
| `count` | integer | Rounds to load (at least 1). |

**Returns**

- **loaded** — true on success.
- **state** — new metadata, or `invalid ammunition amount`, `ammunition does not fit this weapon`, `weapon is full`.

**Example**

```lua
local ok, state = exports.kora_inventory:LoadWeaponRounds(src, slot, 'AMMO_PISTOL', 12)
```

**Representative console output**

```text
ok = true; state.ammo grows by up to 12 depending on remaining capacity.
```

### `exports.kora_inventory:FireWeaponRound(src, slot)`

Consumes the first stored round of a weapon and returns it for evidence systems. The returned table includes the weapon serial, so never send it to a client.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `slot` | integer | Weapon slot. |

**Returns**

- **fired** — true on success.
- **round** — `{ id, ammoType, lot, weapon, weaponSerial }`, or a reason such as `weapon is empty`.

**Example**

```lua
local fired, round = exports.kora_inventory:FireWeaponRound(src, slot)
if fired then recordCasing(round.id, round.weaponSerial) end
```

**Representative console output**

```text
true, { id = 'RD-1767225600-000123-482913', ammoType = 'AMMO_PISTOL', lot = 'LOT-000457', weapon = 'weapon_pistol', weaponSerial = 'KORA-...' }
```

### `exports.kora_inventory:GetCarriedWeapons(src)`

Returns the list a player's body would show right now, built from their real items. Read-only; there is no setter.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |

**Returns**

- **carried** — array of `{ name, tier, model, bone, pos, rot, tint, components }` in slot order; empty when weapon carry is disabled.

**Example**

```lua
for _, entry in ipairs(exports.kora_inventory:GetCarriedWeapons(src)) do
    print(entry.name, entry.tier)
end
```

**Representative console output**

```text
weapon_carbinerifle back
```

### `exports.kora_inventory:GetEquippedWeapon(src)`

Returns the weapon the server believes the player has drawn.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |

**Returns**

- **equipped** — `{ slot, name, components? }`, or nil when empty-handed.

**Example**

```lua
local holding = exports.kora_inventory:GetEquippedWeapon(src)
if holding then print(holding.slot, holding.name) end
```

**Representative console output**

```text
1 weapon_pistol
```

### `exports.kora_inventory:StartTrainingWeapon(src, weaponName, rounds)`

Gives a player a temporary weapon with a fixed number of rounds that is not an inventory item (shooting ranges). Each shot is counted on the server and fires `kora_inventory:server:trainingRoundFired`; the weapon is removed when rounds run out, the owner resource stops, or the player leaves.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `weaponName` | string | Registry weapon name. |
| `rounds` | integer | 1 to 100. |

**Returns**

- **started** — true on success.
- **reason** — `invalid training weapon`, `invalid training round count`, `holster the current weapon first`, `a training weapon is already active`.

**Example**

```lua
local ok, why = exports.kora_inventory:StartTrainingWeapon(src, 'weapon_pistol', 30)
if not ok then print(why) end
```

**Representative console output**

```text
true; the client receives the weapon with 30 rounds.
```

### `exports.kora_inventory:StopTrainingWeapon(src)`

Ends a training weapon. Only the resource that started it may stop it.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |

**Returns**

- **stopped** — true if stopped, false if there is none or it belongs to another resource.

**Example**

```lua
exports.kora_inventory:StopTrainingWeapon(src)
```

**Representative console output**

```text
true; the weapon is removed from the ped.
```

## Common use cases

- Gunsmith and repair resources adjusting durability, components and tint.
- Police evidence from fired rounds and weapon serials.
- Shooting ranges with server-counted training rounds.
- Scripts that need to know what a player is carrying or holding.

## Limits and related APIs

Weapon state can only be changed on the server. Reload state is saved only when a magazine item is used while the weapon is drawn. FiveM does not expose native fire state to the server, so shot reports are rate-limited reports from the shooter, not proof. Throwables and equipment are not carried visibly by default (`tiers`). A weapon in a slot above `hotbarSlots` is concealed in `hotbar` mode and costs extra draw time. Component rendering on carried weapons needs `weaponCarry.components` entries.

## Related guides

- [Items and metadata](./items.md)
- [Usable items](./usables.md)
- [Crafting](./crafting.md)
- [Events and callbacks](./events.md)
- [Configuration](./configuration.md)

## Operating notes (from the code)

Facts below were written from the current code of this resource; they add to, and where noted refine, the reference above.

kora_inventory owns weapon metadata and the draw/holster lifecycle, and provides the `qb-weapons` identity (see [Compatibility](../compatibility.md)).

### Weapon metadata API (server only)

| Export | Notes |
| --- | --- |
| `PrepareWeaponMetadata(name, metadata)` | Returns metadata with a server serial, bounded durability and ammo, and only allowed components. |
| `GetWeaponState(src, slot)` | Copy of the weapon item's info, or `nil` for a non-weapon. |
| `SetWeaponState(src, slot, changes)` | `changes` may hold `durability` (0-100), `ammo` (0 to `maxAmmo`), `components`, `tint` (0-32). Fires `kora_inventory:server:weaponStateChanged`. |
| `ConsumeWeaponDurability(src, slot, amount)` | |
| `SetWeaponAmmo(src, slot, ammo)`, `SetWeaponComponents(src, slot, components)` | Wrappers over `SetWeaponState`. |
| `LoadWeaponRounds(src, slot, ammoType, count)` | Adds per-round records; refuses an ammo type that does not match the weapon. |
| `FireWeaponRound(src, slot)` | Consumes ammo only; returns `true, round`. |
| `GetCarriedWeapons(src)` | Read-only carried list built by the server. |
| `GetEquippedWeapon(src)` | `{ slot, name, components? }` or `nil`. |
| `StartTrainingWeapon(src, weaponName, rounds)` | Gives the player a temporary range weapon (1-100 rounds); the calling resource owns it. Returns `false, reason` if a weapon is drawn or a training weapon is active. |
| `StopTrainingWeapon(src)` | Only the owning resource can stop it. |

Do not add a generic client event for these. Gameplay code must call them from validated server actions.

New serials are `PREFIX-WEAPONNAME-time-n`, from `Config.SerialPrefix`. Stored durability is rounded to two decimals. Only components listed in `Config.kora_inventory.weapons.components` are accepted. `quality` is kept as a mirror of `durability` for old metadata.

#### Ballistics and wear

With `weapons.ballistics.enabled` (default), `info.loadedBullets` holds one generated record per loaded round. The client reports only that its ped fired (`kora_inventory:server:weaponFired`); the server resolves the equipped slot, consumes one round and its wear in one commit, then emits `kora_inventory:server:weaponStateChanged` and `kora_inventory:server:weaponRoundFired` for an evidence resource. `shotCooldown` (65 ms) is a floor between accepted reports. Cartridge ids are not firearm serials.

`weapons.durability`: `perShot` (`0.10`, so ten accepted rounds remove one point), `defaultMultiplier`, per-weapon `multipliers`, `excluded` weapons, `enabled`.

### Ammunition

Using an ammo item loads the weapon currently drawn. The server resolves the weapon from its own record of the confirmed draw, and the round count from the shared item definition's `rounds`. The magazine's `ammoType` must match the weapon's `ammotype`, otherwise nothing is consumed. `server/useables.lua` registers a useable for every registry item with both `ammoType` and a positive `rounds`, including items registered at runtime. A holstered weapon is refused.

### Visible carry and draw pacing

`Config.kora_inventory.weaponCarry` renders owned weapons on the body and makes equipping a timed, animated draw. `enabled = false` turns it all off.

| Key | Default | Meaning |
| --- | --- | --- |
| `visibility` | `'hotbar'` | `'all'` renders every carryable weapon; `'hotbar'` only slots `1..hotbarSlots`. |
| `drawTime`, `holsterTime` | `900`, `700` ms | Durations; `0` gives the old instant toggle. The bar cannot be cancelled. |
| `concealedDrawTime` | `1800` ms | Extra cost for drawing a weapon that was not openly carried (only in `'hotbar'` mode). |
| `pistolsOnHip` | `true` | `false` moves the `Pistol` tier to the back. |
| `holsterOnEmote` | `true` | Holsters a drawn weapon when the player starts an emote (when the player state bag `kora_emotemenu:active` becomes set). |
| `drawAnim`, `holsterAnim`, `drawAnims`, `holsterAnims` | see file | Animation per tier (`back`, `sling`, `hip`); `false` skips the animation but keeps timing. |
| `disable` | `combat = true` | Controls disabled while drawing. |
| `tiers` | by `weapontype` | Maps a kora_core weapon type to `back`, `sling` or `hip`. |
| `attachments` | per tier | Ordered bone positions; a weapon with no free position is not rendered. |
| `weapons` | `weapon_petrolcan`, `weapon_fireextinguisher` excluded | Per-item overrides: `tier = false`, `bone`, `pos`, `rot`, `model`. |
| `components` | `{}` | Component item name to GTA component model name rendered on a holstered weapon. Empty by default. |

The carried list is built on the server and published on the player state bag `kora_inventory:weaponCarry`; clients only render it. There is deliberately no setter. A drawn weapon is holstered and removed from the ped when its item leaves the inventory by any route (`kora_inventory:client:weaponRemoved`).

### Parachute

`server/useables.lua` registers a handler for the `parachute` item (configured under `builtinUsables`): a cancellable progress bar with an animation, then `GADGET_PARACHUTE` is given, the pack is shown on the back (freemode peds) and one item is consumed. The item is only consumed once the client confirms it was equipped; a cancelled bar or an already equipped parachute keeps it. Set `builtinUsables.parachute = false` to leave the item to another resource.
