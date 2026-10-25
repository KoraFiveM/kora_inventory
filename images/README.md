# Local item artwork

The canonical PNG set from `qbcore-framework/qb-inventory` is bundled here at
commit `dc3d07fc60139de569df38c5ac178ed4cada4577`. Its filenames match the legacy
`image` fields imported from qb-core shared items and uppercase extensions were
normalised for FiveM's case-sensitive NUI paths. qbinventory resolves these
files directly without a per-item path rewrite.

Drop item images in here and qbinventory's UI finds them by item name, with no
code change and no outbound request:

```
images/water_bottle.webp
images/pistol_ammo.png
images/lockpick.gif
```

The name must match the item's `name` in `qbcore/shared/items.lua` (not its
label). Extensions are tried in the order set by
`Config.qbinventory.ui.images.extensions` -- `webp`, `png`, `gif`, `jpg` by
default -- so a `.webp` wins over a `.png` of the same item.

**Animated WebP and GIF work as-is.** CEF animates both in a plain `<img>`, so
there is nothing to enable; the format just has to be in `extensions`. An
animated item in a full grid of 41 slots does cost frames, so use motion for the
handful of items where it earns its place rather than as a default.

An item's own `imageUrl` (qbcore's remote catalogue) is still used when there is
no local file. Two config switches change that relationship:

- `preferLocal = true` -- try the local file first and use the remote URL only
  as a fallback.
- `allowRemote = false` -- never make an outbound image request; items with no
  local file show the first-letter placeholder instead.

Files here are served to the browser as `nui://qbinventory/images/<file>`, which
is why `images/**/*` is listed in `fxmanifest.lua`. It sits outside `web/` on
purpose: a Vite build owns everything under `web/build`, and artwork a server
owner added must not be something `pnpm build` can delete.

Legacy consumers use `nui://qb-inventory/html/images/<file>`. The manifest also
packs `html/images/**/*` through the relative `html/images -> ../images` link,
so both paths share the same artwork, including server-owner additions. Preserve
that link when packaging/deploying the resource. Real FXServer file loading is
checked separately from connected-client NUI rendering.
