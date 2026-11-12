---
title: "Items and metadata"
sidebar_position: 3
---


# Items and metadata

An item has two parts: a definition (what kind of thing it is) kept in kora_core's shared `items` or `weapons` registry, and instances (the actual stack in a slot) with their own amount and metadata. This page lists every definition field kora_inventory reads, every field an instance carries, the metadata keys that change how an instance behaves, and the one export that imports ox_inventory item data.

Namespace: `exports.kora_inventory` · Source: `server.lua (buildItem), shared.lua, server/compat (ox item mapping), kora_core shared/items.lua`

## How it works

kora_inventory never stores definitions. Each time it needs one it asks kora_core (`getShared('items', name)`, falling back to `weapons`), so an item registered a moment ago works immediately and an item removed from the registry stops being usable. Names are matched lower-case. When an item is added, `buildItem` copies the relevant definition fields onto the instance, and `viewItems` refreshes label, image, weight and description from the live definition and metadata every time an inventory is sent to a player.

## Adding a new item

1. **Register the definition** — From a server script call `exports.kora_core:registerShared('items', name, record)` with a lower-case `name` equal to the key. A registered record is owned by your resource and is removed when it stops, so register on every start. Weapons go in the `weapons` registry with `type = 'weapon'`.
2. **Add artwork** — Place `<name>.png` (or webp, gif, jpg) in `kora_inventory/images`, or set `imageUrl` on the record. `ui.images.preferLocal` decides which wins.
3. **Give it behaviour** — If it should be used, set `useable = true` and register a handler with `createUseable`. Items with `useable = true` and no handler fall back to the legacy `QBCore:Server:UseItem` event.
4. **Grant it from the server** — Call `AddItem`. Weapons automatically receive serial, durability and ammo metadata on the way in.

## Terms used on this page

| Term | Meaning |
| --- | --- |
| Definition | The shared record for an item name: label, weight, type and flags. One per name. |
| Instance | The table in a slot: name, amount and metadata (also called `info`). Unique items always have `amount = 1`. |
| Metadata / info | A per-instance table. `info` and `metadata` hold the same data; kora_inventory keeps both in sync and prefers `info`. |
| Unique item | A definition with `unique = true`. It never stacks; adding N creates N separate slots. Every weapon in kora_core's shipped catalogue is unique. |
| Effective item | The label, image, weight and description actually shown: instance metadata wins over the definition. |

## Item fields

Definition fields are set on the record you register in kora_core. Instance fields are what a slot holds. Anything not listed is preserved on records but ignored by the inventory.

### Definition fields (kora_core items / weapons registry)

Read by kora_inventory through `buildItem`, `effectiveItem`, the use flow, ammo loading and weapon carry.

| Option | Type | Description |
| --- | --- | --- |
| `name` | string | Required. Lower-case unique id, equal to the registry key. Lookups lower-case the requested name. |
| `label` | string | Display name. Falls back to the name. Can be overridden per instance by `metadata.label`. |
| `weight` | number | Grams per item. Defaults to 0 (zero-weight items are valid). Total weight is `weight * amount` summed over the inventory. `metadata.weight` can override it per instance. |
| `type` | string | `'item'` (default) or `'weapon'`. A definition with `type = 'weapon'`, or any registry item whose name starts with `weapon_`, is treated as a weapon: it gets weapon metadata on add and the draw/holster use. |
| `unique` | boolean | Default false. True items never stack and are split one per slot when added in bulk. |
| `useable` | boolean | Shows the Use button. A weapon is always useable. An item with a registered handler (`createUseable` or a built-in) is useable even if this is false. |
| `shouldClose` | boolean | Legacy qb field. `false` means "keep the panel open after use". Kept as given on the definition. |
| `preventClose` | boolean | kora_inventory's own field with the opposite sense: `true` leaves the panel open after use. Set implicitly when `shouldClose = false`. |
| `useTime` | integer | Milliseconds of kora_lib progress bar the client runs before a use is sent (hotbar and NUI). 0 or absent means immediate. A cancelled bar sends nothing to the server. |
| `image` | string | Local artwork file name, for example `water_bottle.png`. |
| `imageUrl` | string | Optional browser-ready URL used as a remote artwork source (see `ui.images`). |
| `description` | string | Shown in the inspector. Overridable by `metadata.description`. |
| `container` | boolean | Marks an item as a container for the UI. Set automatically on views of items whose definition has `container = true` (the shipped `backpack`). Opening is driven by `Config.kora_inventory.containers.items`, not by this flag. |
| `ammoType` | string | Ammo items only: native ammo type such as `AMMO_PISTOL`. With a positive `rounds`, the item becomes loadable by a built-in handler. |
| `rounds` | integer | Ammo items only: rounds loaded by one item. |
| `ammotype` | string | Weapons only: ammo type the weapon accepts. Must equal a magazine item's `ammoType`. |
| `ammoItem` | string | Weapons only: the magazine item name for that ammo type (informational for other systems). |
| `weapontype` | string | Weapons only: `Melee`, `Pistol`, `SMG`, `Shotgun`, `Rifle`, `Sniper`, `LMG`, `Heavy`, `Throwable`, `Equipment`. Picks the carry tier and draw animation. |
| `damageModifier` | number | Weapons only: damage multiplier applied while the weapon is drawn (negative falls back to 1.0). |
| `disableCriticalHits` | boolean | Weapons only: turns off critical hits while drawn. |
| `stack` | boolean | ox-style flag read only by the ox item translation: `false` behaves like `unique = true`. |
| `close, consume, client, server` | any | ox-style fields preserved on the record and returned by `Items()`: `close` mirrors `shouldClose`, `consume` is the amount a use consumes (default 1), `client`/`server` tables are copied. They do not change inventory behaviour by themselves. |

### Instance fields (a slot's table)

Written by `buildItem` when an item is added. Extra fields set by trusted code (`price`, `serverData`, `quality`, ...) are preserved by the replace-style writes but never invented by clients.

| Option | Type | Description |
| --- | --- | --- |
| `slot` | integer | Slot number, 1 to the inventory's slot count. |
| `name` | string | Definition name. |
| `amount` | integer | Stack size. Always 1 for unique items. `count` is accepted as an input alias by several functions. |
| `info / metadata` | table | Instance metadata; both keys hold the same table. |
| `type, unique, useable, container, image, imageUrl, label, weight, shouldClose, description` | mixed | Copied from the definition at add time and refreshed for display. |
| `preventClose` | boolean | `true` when the definition says so or has `shouldClose = false`. |
| `useTime` | integer | Non-negative whole milliseconds from the definition. |
| `created` | integer | Unix time the instance was built. |
| `price` | number | Shop stock rows only: unit price. Not part of the canonical fields, so it survives `SetShopItems`. |
| `serverData` | any | Durable-stock bookkeeping for trusted integrations. Removed from every view sent to a client and never copied into purchased metadata. |

### Metadata keys with special meaning

Any key can be stored. These change behaviour or display.

| Option | Type | Description |
| --- | --- | --- |
| `label, description` | string | Replace the definition's label or description for this instance. |
| `weight` | number | Per-instance weight override. Only a finite number of at least 0 is used; anything else falls back to the definition. |
| `image / imageUrl` | string | `imageUrl` replaces the artwork URL for this instance. If `image` is set to a string and `imageUrl` is not, no remote URL is used. The UI marks an instance override as `imageOverride`. |
| `show` | boolean | Put `show = true` on a nested table to display its children in the inspector. Plain (non-table) values at the top level are always listed; other nested tables are hidden. |
| `containerId` | string | Set by the container module when a portable container is bound to this unique item. Never accept it from a client. |
| `serial, durability, quality, ammo, loadedBullets, tint, components` | mixed | Canonical weapon metadata managed by `PrepareWeaponMetadata` and the weapon exports. `quality` mirrors `durability`. |

## Stacking

Two instances stack when they have the same name, neither is unique, and their `info` tables are equal. Equality is a shallow comparison: nested table values are compared by reference, so items whose metadata contains a nested table do not stack with each other. A stack is filled into the lowest matching slot first; otherwise the first free slot is used.

## Weight

Weight is `weight * amount` per slot using the effective weight (metadata override, then instance, then definition), summed and compared to the inventory's `maxWeight`. Moves between inventories re-check both sides, including swaps. A shop registered with `weightLimit = false` is not weight-capped.

## Where definitions come from

kora_core ships the default catalogue in `shared/items.lua` and `shared/weapons.lua`: food and drink, ammunition packs with `ammoType` and `rounds`, craft materials, the unique `backpack`, `phone`, `id_card`, `vehiclekey`, `weaponlicense`, `cash`, and the vanilla weapon list. Any resource can add more with `exports.kora_core:registerShared` (or `Kora.shared.register` after loading `@kora_core/init.lua`).

## ox_inventory mapping

ox item tables are translated both ways. Into kora: `stack = false` becomes `unique`, `weapon` becomes `type = 'weapon'`, `close ~= false` becomes `shouldClose`, `client.image` becomes `image`, and the item is useable when it has a client or server export/event, status, anim, prop or a `consume` value. Out of kora (`Items()` on the ox identity): `stack` defaults to not unique and not a weapon, `close` follows `shouldClose` (default true), `consume` defaults to 1, `client.image` falls back to `image`, `imageUrl` or `<name>.png`.

## Functions

Item definitions are registered with kora_core, not with kora_inventory. The only item-registration export here imports ox_inventory style tables.

### `exports.kora_inventory:ImportOxItems(definitions, opts?)`

Registers ox_inventory style item definitions (a `data/items.lua` table) into kora_core's `items` registry. Existing items, including weapons, are skipped unless `overwrite = true`. This is a kora-only export, not part of ox_inventory. Alias `importOxItems`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `definitions` | table | A name-keyed map (`{ bandage = { label = ..., weight = ... } }`) or an array of tables that carry `name`. |
| `opts?` | table | `{ overwrite = boolean }`. Default false. |

**Returns**

- **registered** — integer count of records written to the registry.
- **errors** — table of `name -> reason`. Reasons: `invalid_item_name`, `invalid_item_definition`, `already_registered`, a registry error string, or `register_failed`. A non-table input returns `0, { ['*'] = 'invalid_definitions' }`.

**Example**

```lua
local oxItems = {
    bandage = { label = 'Bandage', weight = 115, stack = true, close = true,
        client = { image = 'bandage.png', anim = 'bandage', usetime = 2500 } },
    lockpick = { label = 'Lockpick', weight = 160, stack = true, consume = 0 },
}
local registered, errors = exports.kora_inventory:ImportOxItems(oxItems, { overwrite = false })
print(('imported %d items'):format(registered))
for name, reason in pairs(errors) do print(name, reason) end
```

**Representative console output**

```text
imported 2 items
-- a second run prints: bandage already_registered / lockpick already_registered
```

## Common use cases

- Registering a themed item set from your own resource at start.
- Porting an ox_inventory `data/items.lua` into the kora_core registry.
- Adding per-instance labels, images or weights (for example a labelled evidence bag) through metadata instead of a new definition.

## Limits and related APIs

The record owner is the resource that registered it; stopping that resource removes the item, and instances already in inventories remain until they are used or removed (an unknown item cannot be moved by name, and views show whatever data the instance still holds). Definition fields are read live, so changing weight changes the weight of every existing stack. Item names must be lower-case to be found.

## Related guides

- [Player items](./player-items.md)
- [Usable items](./usables.md)
- [Weapons and weapon carry](./weapons.md)
- [ox_inventory compat](./compat-ox.md)

## Operating notes (from the code)

Facts below were written from the current code of this resource; they add to, and where noted refine, the reference above.

kora_inventory does not define items. Definitions live in kora_core's `items` registry and are looked up each time an operation runs; the legacy `QBCore.Shared.Items` map is never cached. Definitions can therefore be registered, updated or removed at runtime, and the built-in weapon and ammunition handlers pick up changes without a restart.

### Fields kora_inventory reads

On top of the usual `label`, `weight`, `unique`, `useable`, `image`, `imageUrl` and `description`:

| Field | Meaning |
| --- | --- |
| `useTime` | Milliseconds (default `0`). The client runs a `kora_lib` progress bar before any use request is sent; a cancelled bar never reaches the server. |
| `preventClose` | Default `false`. A completed use normally closes the panel; `true` keeps it open. A legacy `shouldClose = false` counts as `preventClose = true`. |
| `weapontype`, `ammotype` | Weapon class (drives `tiers`) and the ammunition a weapon accepts. |
| `ammoType`, `rounds` | On an ammo item: the type it loads and how many rounds. |

`useTime`, `preventClose`, `weight` and the other canonical fields cannot be forged onto a stored item through `setItems`.

```lua
-- server
exports.kora_inventory:createUseable('bandage', function(src, item)
    exports.kora_inventory:removeItem(src, 'bandage', 1, item.slot)
end)
```

An item with no handler falls back to the legacy `QBCore:Server:UseItem` event. Built-in handlers cover weapons, ammunition and the `parachute`. Consumables are handled by other resources.

### ox item data

On the `ox_inventory` identity, `Items()`, `Items(name)` and `ItemList` (server and client) return ox-format definitions translated from the registry; they are copies. `exports.kora_inventory:ImportOxItems(definitions, { overwrite = false })` registers ox `data/items.lua` entries (a name-keyed map or an array) into the registry: `stack = false` becomes `unique`, `close` becomes `shouldClose`, `client.image` becomes `image`, and ox `client`, `server`, `consume`, `degrade` and `decay` are preserved. Existing items are skipped unless `overwrite`. It returns `registered, errors`.

### Artwork

Artwork is resolved as an ordered list and walked on `onError`:

1. the item's own `imageUrl`, if it is `https://` and `ui.images.allowRemote` is not false
2. `<localPath>/<item.image>` when the legacy `image` field has an extension
3. `<localPath>/<item.name>.<ext>` for each extension in `ui.images.extensions` (`webp`, `png`, `gif`, `jpg`)
4. the first letter of the label

`preferLocal` (default `true`) moves a remote URL to the end of the list; `allowRemote = false` drops remote URLs entirely. Only `https://` is accepted and a local name must be a plain identifier. Local files live in `images/` (served as `nui://kora_inventory/images/<file>`), outside `web/` so rebuilding the NUI cannot delete them. `html/images/` is shipped for legacy consumers that embed that path in their own NUI. Animated WebP and GIF work in CEF without extra handling.
