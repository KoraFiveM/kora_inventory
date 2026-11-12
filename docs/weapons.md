---
title: Weapons
sidebar_position: 13
---

# Weapons, ammunition and carry

kora_inventory owns weapon metadata and the draw/holster lifecycle, and provides the `qb-weapons` identity (see [Compatibility](./compatibility.md)).

## Weapon metadata API (server only)

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

### Ballistics and wear

With `weapons.ballistics.enabled` (default), `info.loadedBullets` holds one generated record per loaded round. The client reports only that its ped fired (`kora_inventory:server:weaponFired`); the server resolves the equipped slot, consumes one round and its wear in one commit, then emits `kora_inventory:server:weaponStateChanged` and `kora_inventory:server:weaponRoundFired` for an evidence resource. `shotCooldown` (65 ms) is a floor between accepted reports. Cartridge ids are not firearm serials.

`weapons.durability`: `perShot` (`0.10`, so ten accepted rounds remove one point), `defaultMultiplier`, per-weapon `multipliers`, `excluded` weapons, `enabled`.

## Ammunition

Using an ammo item loads the weapon currently drawn. The server resolves the weapon from its own record of the confirmed draw, and the round count from the shared item definition's `rounds`. The magazine's `ammoType` must match the weapon's `ammotype`, otherwise nothing is consumed. `server/useables.lua` registers a useable for every registry item with both `ammoType` and a positive `rounds`, including items registered at runtime. A holstered weapon is refused.

## Visible carry and draw pacing

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

## Parachute

`server/useables.lua` registers a handler for the `parachute` item (configured under `builtinUsables`): a cancellable progress bar with an animation, then `GADGET_PARACHUTE` is given, the pack is shown on the back (freemode peds) and one item is consumed. The item is only consumed once the client confirms it was equipped; a cancelled bar or an already equipped parachute keeps it. Set `builtinUsables.parachute = false` to leave the item to another resource.
