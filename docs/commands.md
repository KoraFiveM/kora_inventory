---
title: "Commands"
sidebar_position: 4
---


# Commands

Kora Inventory registers a handful of player commands and key bindings, and one operator command for importing old inventory tables. It reads no ConVars of its own.

## Built-in commands and key bindings

### `/inventory`

Opens or closes the player's inventory. While seated in a vehicle it opens the glovebox instead; on foot at a vehicle's boot it opens the trunk. The TAB key runs this command.

| Field | Details |
| --- | --- |
| Context | In-game · client command |
| Arguments | No arguments. |
| Access | Anyone. Ignored while the pause menu or another NUI has focus, while a kora_lib zone or placement creator is active, and refused with a notice while downed or cuffed. |

**Example**

```text
/inventory
```

**Result**

A session opens (player inventory, plus glovebox or trunk when applicable). Running it again with a session open closes it.

### `/openInv`

Alias used by the default TAB key mapping. Runs `/inventory`.

| Field | Details |
| --- | --- |
| Context | In-game · client command |
| Arguments | No arguments. |
| Access | Anyone. |

**Example**

```text
/openInv
```

**Result**

Same as `/inventory`.

### `/closeInv`

Closes the open inventory session.

| Field | Details |
| --- | --- |
| Context | In-game · client command |
| Arguments | No arguments. |
| Access | Anyone. |

**Example**

```text
/closeInv
```

**Result**

The session closes and NUI focus is released. Does nothing if no session is open.

### `/trunk`

Toggles the vehicle's trunk lid (the front lid for the models in `vehicles.frontBootModels`).

| Field | Details |
| --- | --- |
| Context | In-game · client command |
| Arguments | No arguments. The name can be changed in `Config.kora_inventory.vehicles.doors.commandNames.trunk`. |
| Access | Driver seat only. Needs `vehicles.doors.enabled` and `vehicles.doors.commands`. A locked vehicle cannot be opened from outside, but you are inside here. |

**Example**

```text
/trunk
```

**Result**

The lid opens or closes for everyone after the client takes network control of the vehicle. Notices come from `locales/en.lua` (`vehicle_doors.*`).

### `/hood`

Toggles the vehicle's hood.

| Field | Details |
| --- | --- |
| Context | In-game · client command |
| Arguments | No arguments. Renameable through `commandNames.hood`; set a name to false or an empty string to disable that command. |
| Access | Driver seat only. Same switches as `/trunk`. |

**Example**

```text
/hood
```

**Result**

The bonnet (or the boot for front-boot models) opens or closes.

### `kora_inventory-migrate <dry-run|run|retry|verify>`

Imports legacy inventory tables into the kora_inventory tables without ever modifying or deleting the legacy data.

| Field | Details |
| --- | --- |
| Context | Server console or restricted command |
| Arguments | dry-run — report what would be imported. run — import eligible rows. retry — revisit rows that previously failed or were quarantined. verify — check stored item JSON and print the migration state. No argument prints usage. |
| Access | Server console, or a player holding the `command.kora_inventory` ACE. |

**Example**

```text
kora_inventory-migrate dry-run
kora_inventory-migrate run
kora_inventory-migrate verify
```

**Result**

Logs `imported: N, skipped: N, quarantined: N`. Reads the tables listed in `Config.kora_inventory.persistence.legacyTables` (`inventories`, `stashitems`, `trunkitems`, `gloveboxitems`). Malformed rows are copied to `kora_inventory_quarantine`.

### `/invaudit`

Opens the admin item-creation audit viewer: a read-only overlay showing which script created which items, so duplication and bad scripts can be found. It is not an inventory session and cannot change anything.

| Field | Details |
| --- | --- |
| Context | In game (opens the overlay) or server console (prints a summary) |
| Arguments | Optional `player=<citizenid or server id>`, `item=<name>`, `resource=<name>`, `range=<1h or 24h or 7d>`, `page=<n>`. In game they pre-fill the filters; in the console they select what is summarised. |
| Access | The ACE `kora_inventory.audit` (name configurable with `audit.ace`), checked when you run the command and again on every data request the overlay makes. The server console always has access. |

**Example**

```text
/invaudit
/invaudit resource=kora_drugs range=1h
```

**Result**

In game: an overlay with filters (player, item, resource, last hour, 24 hours or 7 days), a table of results (newest first, 100 per page) and a "top scripts / top items in the last hour" summary. Press Esc to close. In the console: `Kora.logging.info` lines with the top resources and items of the last hour and the newest entries. Name configurable with `audit.command`.

### `/omnipack`

Opens the admin omnipack: a free, read-only shop listing every registered item and weapon, with a search box. Dragging or buying from it adds the item to your own inventory through the normal add path (weapons get a fresh serial) and records an `omnipack` audit entry.

| Field | Details |
| --- | --- |
| Context | In game |
| Arguments | None. Also available to server code as `exports.kora_inventory:openOmnipack(source)`. |
| Access | The ACE `kora_inventory.omnipack` (name configurable with `omnipack.ace`), checked on open, on every request the open window makes, and again on every take. Revoking the ACE closes the window at the next action. |

**Example**

```text
/omnipack
```

**Result**

A shop window titled Omnipack. Price is 0 and stock is infinite. The largest single take is `omnipack.maxAmount` (default 100). The list is sent once when the window opens; takes only update your own inventory. Name configurable with `omnipack.command`.

### `Key: 1 - 5 (kora_inventory:hotbar1 ... kora_inventory:hotbarN)`

Uses the item in hotbar slot N. The number of bindings is `Config.kora_inventory.hotbarSlots`; 0 disables them.

| Field | Details |
| --- | --- |
| Context | Key binding (rebindable under Settings, Key Bindings, FiveM) |
| Arguments | No arguments. |
| Access | Blocked while the pause menu or NUI is focused, while busy (progress bar active), UI-blocked, cuffed, or downed (unless the item is in `downedAllowedItems`). |

**Example**

```text
Press 2
```

**Result**

The item's `useTime` progress bar runs (if set), then `QBCore:Server:UseItem` is sent with the slot; the server re-reads the slot and uses it.

### `Key: unbound (kora_inventory:quick_<id>)`

Uses the item a quick slot currently points at. One binding exists per entry of `Config.kora_inventory.quickSlots.slots`; the shipped slots give `kora_inventory:quick_weapon`, `kora_inventory:quick_ammo`, `kora_inventory:quick_phone` and `kora_inventory:quick_radio`. They are unbound by default and are listed under Settings, Key Bindings, FiveM as `Quick slot: label`. Set `key` on a slot in the config to give it a default key.

| Field | Details |
| --- | --- |
| Context | Key binding (rebindable) |
| Arguments | No arguments. |
| Access | Exactly the hotbar number keys' guards: blocked while the pause menu or NUI is focused, while busy, UI-blocked, cuffed, or downed (unless the item is in `downedAllowedItems`). Does nothing when the quick slot resolves to no item. |

**Example**

```text
Press the key you bound to Quick slot: Weapon
```

**Result**

The quick slot is resolved to a real inventory slot and that slot is used through the hotbar's own path (progress bar gate, then `QBCore:Server:UseItem`). For the weapon slot that draws or holsters the weapon. For the ammo slot it uses the ammunition item, which the server accepts only if it fits the weapon it has recorded as drawn. No new server event exists.

### `Key: U (kora_inventory:hotbarshow)`

Shows the on-screen hotbar overlay listing the first `hotbarSlots` slots, plus the resolved quick slots when `quickSlots.inHotbarHud` is on.

| Field | Details |
| --- | --- |
| Context | Key binding (rebindable) |
| Arguments | No arguments. |
| Access | Does nothing while `ui.hotbarSeconds` is 0, `hotbarSlots` is 0, the pause menu is active or NUI is focused. |

**Example**

```text
Press U
```

**Result**

The overlay fades after `ui.hotbarSeconds` seconds. Position comes from `Config.Hotbar`.

### `Key: TAB (openInv)`

Default key for `/openInv`, described as "Open inventory (kora_inventory)".

| Field | Details |
| --- | --- |
| Context | Key binding (rebindable) |
| Arguments | No arguments. |
| Access | Anyone. |

**Example**

```text
Press TAB
```

**Result**

Runs `/inventory`.

### `Key: R (kora_inventory_clearjam)`

Hold to clear a jam on the weapon in your hands. Registered through `Kora.keybind`, so it is rebindable under **Settings → Key Bindings → FiveM** ("Clear weapon jam (hold)").

| Field | Details |
| --- | --- |
| Context | Key binding (rebindable) |
| Arguments | No arguments. |
| Access | Only acts while the server has told this client the drawn weapon is jammed (`weapons.jams.enabled`). Hold for about 0.6 seconds; the server then runs the `weapons.jams.clearTime` progress bar. Refused while downed or cuffed. |

**Example**

```text
Hold R while a jammed weapon is drawn
```

**Result**

A progress bar runs and the jam is cleared. The request carries no weapon or slot; the server clears the weapon it recorded as drawn.

## ConVars and ACEs

kora_inventory reads no ConVars. The database connection comes from kora_sql (`mysql_connection_string`). It checks `command.kora_inventory` for `kora_inventory-migrate`, and two ACEs of its own for the admin tools:

| ACE | Allows | Config key |
| --- | --- | --- |
| `kora_inventory.audit` | `/invaudit` and the audit viewer's data requests. | `audit.ace` |
| `kora_inventory.omnipack` | `/omnipack`, the `openOmnipack` export, and taking items from the omnipack. | `omnipack.ace` |

Grant them in `server.cfg`, for example:

```cfg
add_ace group.admin kora_inventory.audit allow
add_ace group.admin kora_inventory.omnipack allow
```

Both are denied to everyone else by default. Give them only to staff you trust to create any item. Evidence, player inspection, vehicle and stash access are decided by Lua callbacks, not ACEs, unless your callback checks one.

## State bags this resource reads or writes

Writes the replicated player bag `kora_inventory:weaponCarry` (server) and the local `inv_busy` bag (client). Reads `koraUiBlocked` (configurable name), `koraCuffed`, the vehicle bag `kora_vehiclekeys:locked`, and kora_core metadata `isdead`, `inlaststand` and `ishandcuffed`.

## Keybinds (summary)

Registered through `Kora.keybind`, so players can rebind them in **Settings → Key Bindings → FiveM**.

| Binding | Default | Effect |
| --- | --- | --- |
| `openInv` | `TAB` | Same as `/inventory`. |
| `kora_inventory:hotbar1` ... `hotbarN` | `1` ... `5` | Use the item in that slot (`N` is `Config.kora_inventory.hotbarSlots`). Ignored while the NUI is focused or the pause menu is open. |
| `kora_inventory:quick_<id>` | unbound | Use the item a quick slot points at, one binding per configured quick slot, under the same guards as the hotbar keys. |
| `kora_inventory_clearjam` | `R` | Hold to clear a jam on the drawn weapon. |
| `kora_inventory:hotbarshow` | `U` | Show the on-screen hotbar for `ui.hotbarSeconds` seconds (`0` disables the key). |

## Migration actions and permissions (from the code)

`kora_inventory-migrate <action>` is defined in `server/persistence.lua`. Any other action prints the usage line `kora_inventory-migrate dry-run|run|retry|verify`; results are written to the server console.

| Action | Effect |
| --- | --- |
| `dry-run` | Reports what would be imported, skipped or quarantined without writing. |
| `run` | Idempotently imports eligible legacy rows. |
| `verify` | Validates stored item JSON and prints record and malformed counts. |
| `retry` | Revisits only previously failed or quarantined rows. |

The command is registered as restricted. From the console (source 0) it always runs. The handler checks `command.kora_inventory` for a player; because the command is also restricted, the engine's own ACE `command.kora_inventory-migrate` may be required as well. Without the permission the player gets the chat message `Permission denied.` Example:

```cfg
add_ace group.admin command.kora_inventory-migrate allow
add_ace group.admin command.kora_inventory allow
```

## Alias commands

`/trunk` and `/hood` names come from `vehicles.doors.commandNames` and are read once at start; `commands = false` registers neither.
