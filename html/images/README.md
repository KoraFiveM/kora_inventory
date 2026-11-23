# Local item artwork

The canonical PNG set from `qbcore-framework/qb-inventory` is bundled here at
commit `dc3d07fc60139de569df38c5ac178ed4cada4577`. kora_inventory resolves the
definition's `image` filename from this folder; `info.image` can override it with
a different filename or a full `https://` or `nui://` URL.

Drop item images in here and kora_inventory's UI finds them by configured image
filename, with no code change and no outbound request:

```
images/water_bottle.webp
images/pistol_ammo.png
images/lockpick.gif
```

The filename should match the item's `image` in the inventory catalogue (or
the item name when its definition has no image), not its label. Extensions are
tried in the order set by
`Config.kora_inventory.ui.images.extensions` -- `webp`, `png`, `gif`, `jpg` by
default -- so a `.webp` wins over a `.png` of the same item.

**Animated WebP and GIF work as-is.** CEF animates both in a plain `<img>`, so
there is nothing to enable; the format just has to be in `extensions`. An
animated item in a full grid of 41 slots does cost frames, so use motion for the
handful of items where it earns its place rather than as a default.

The built-in renderer does not use `imageUrl` or fetch remote artwork. A full
URL is honored only when it is set as an instance's `info.image` value.

Files here are served to the browser as `nui://kora_inventory/images/<file>`, which
is why `images/**/*` is listed in `fxmanifest.lua`. It sits outside `web/` on
purpose: a Vite build owns everything under `web/build`, and artwork a server
owner added must not be something `pnpm build` can delete.

Legacy consumers use `nui://qb-inventory/html/images/<file>`. The manifest also
packs `html/images/**/*` through the relative `html/images -> ../images` link,
so both paths share the same artwork, including server-owner additions. Preserve
that link when packaging/deploying the resource. Real FXServer file loading is
checked separately from connected-client NUI rendering.
