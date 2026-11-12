---
title: Items
sidebar_position: 15
---

# Items and artwork

kora_inventory does not define items. Definitions live in kora_core's `items` registry and are looked up each time an operation runs; the legacy `QBCore.Shared.Items` map is never cached. Definitions can therefore be registered, updated or removed at runtime, and the built-in weapon and ammunition handlers pick up changes without a restart.

## Fields kora_inventory reads

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

## ox item data

On the `ox_inventory` identity, `Items()`, `Items(name)` and `ItemList` (server and client) return ox-format definitions translated from the registry; they are copies. `exports.kora_inventory:ImportOxItems(definitions, { overwrite = false })` registers ox `data/items.lua` entries (a name-keyed map or an array) into the registry: `stack = false` becomes `unique`, `close` becomes `shouldClose`, `client.image` becomes `image`, and ox `client`, `server`, `consume`, `degrade` and `decay` are preserved. Existing items are skipped unless `overwrite`. It returns `registered, errors`.

## Artwork

Artwork is resolved as an ordered list and walked on `onError`:

1. the item's own `imageUrl`, if it is `https://` and `ui.images.allowRemote` is not false
2. `<localPath>/<item.image>` when the legacy `image` field has an extension
3. `<localPath>/<item.name>.<ext>` for each extension in `ui.images.extensions` (`webp`, `png`, `gif`, `jpg`)
4. the first letter of the label

`preferLocal` (default `true`) moves a remote URL to the end of the list; `allowRemote = false` drops remote URLs entirely. Only `https://` is accepted and a local name must be a plain identifier. Local files live in `images/` (served as `nui://kora_inventory/images/<file>`), outside `web/` so rebuilding the NUI cannot delete them. `html/images/` is shipped for legacy consumers that embed that path in their own NUI. Animated WebP and GIF work in CEF without extra handling.
