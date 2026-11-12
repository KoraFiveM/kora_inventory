---
title: Troubleshooting
sidebar_position: 22
---

# Troubleshooting

**The resource refuses to start with "provider conflict".** A real `qb-inventory`, `ox_inventory` or `qb-weapons` resource is started. Stop it; kora_inventory already provides those names.

**Inventory does not open.** Check, in order: the player is downed or cuffed (`blockWhenDowned`, `blockWhenCuffed`), an item is in use or a progress bar is active (`blockWhileBusy`), another resource set `koraUiBlocked`, the pause menu or another NUI has focus, a `kora_lib` zone or placement creator is active (TAB is shared).

**Another player's inventory will not open.** This is denied until `playerInspection.access` or a `registerInspectionAccess` policy returns `true`.

**A stash or shop will not open from a distance, or in another bucket.** Sessions need the player within `distance` of one registered point and in the same routing bucket. Re-registering a stash updates its boundary.

**Trunk does not open.** Check `vehicles.enabled`, `trunkEnabled`, `respectLocks` (the vehicle may be locked), `trunkDistance`, and that the vehicle class has a trunk in `vehicles.classes` (cycles, motorcycles and trains are disabled).

**A drag feels late.** Set `slowRequestMs` (default 250); the server logs `slow <action> request from player <id>`. No such line means the delay is network or client side.

**Shop prices change after editing config.** A shop restored from the database keeps its persisted stock and prices. Change live stock with `shopSet`.

**A weapon cannot load ammo.** The weapon must be drawn, and the magazine's `ammoType` must match the weapon's `ammotype`.

**Item art is missing.** Put `<item name>.webp` (or `png`, `gif`, `jpg`) in `images/`, restart the resource, and check `ui.images`. Remote art needs an `https://` `imageUrl`.

**`kora_inventory-migrate` says permission denied.** See [Commands and keybinds](./commands.md); a player needs both ACEs. Use the server console otherwise.
