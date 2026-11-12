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

The lid opens or closes for everyone after the client takes network control of the vehicle. Notices come from `locales/en.json` (`vehicle_doors.*`).

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

### `Key: U (kora_inventory:hotbarshow)`

Shows the on-screen hotbar overlay listing the first `hotbarSlots` slots.

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

## ConVars and ACEs

kora_inventory reads no ConVars. The database connection comes from kora_sql (`mysql_connection_string`). The only ACE it checks itself is `command.kora_inventory` for `kora_inventory-migrate`. Evidence, player inspection, vehicle and stash access are decided by Lua callbacks, not ACEs, unless your callback checks one.

## State bags this resource reads or writes

Writes the replicated player bag `kora_inventory:weaponCarry` (server) and the local `inv_busy` bag (client). Reads `koraUiBlocked` (configurable name), `koraCuffed`, the vehicle bag `kora_vehiclekeys:locked`, and kora_core metadata `isdead`, `inlaststand` and `ishandcuffed`.

## Keybinds (summary)

Registered through `Kora.keybind`, so players can rebind them in Settings > Key Bindings > FiveM.

| Binding | Default | Effect |
| --- | --- | --- |
| `openInv` | `TAB` | Same as `/inventory`. |
| `kora_inventory:hotbar1` ... `hotbarN` | `1` ... `5` | Use the item in that slot (`N` is `Config.kora_inventory.hotbarSlots`). Ignored while the NUI is focused or the pause menu is open. |
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
