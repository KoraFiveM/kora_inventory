---
title: Commands and keybinds
sidebar_position: 4
---

# Commands and keybinds

## Server console command

`kora_inventory-migrate <action>` imports legacy qb-inventory/ox_inventory secondary data. Defined in `server/persistence.lua`.

| Action | Effect |
| --- | --- |
| `dry-run` | Reports what would be imported, skipped or quarantined without writing. |
| `run` | Idempotently imports eligible legacy rows. |
| `verify` | Validates stored item JSON and prints record and malformed counts. |
| `retry` | Revisits only previously failed or quarantined rows. |

Any other action prints the usage line. Results are written to the server console.

### Permissions (ACE)

The command is registered as restricted. From the console (source 0) it always runs. A player needs the engine's restricted-command ACE `command.kora_inventory-migrate` and, because the handler also checks it, `command.kora_inventory`; without the second one the player gets a chat message `Permission denied.` Example:

```cfg
add_ace group.admin command.kora_inventory-migrate allow
add_ace group.admin command.kora_inventory allow
```

## Client commands

| Command | Effect |
| --- | --- |
| `/inventory` | Opens the inventory. While seated it opens the glovebox, on foot at a vehicle boot it opens the trunk, otherwise the player inventory. Refused while the pause menu or NUI is focused, while downed or cuffed, or while a zone/placement creator is active. |
| `/openInv` | Alias that runs `/inventory`. |
| `/closeInv` | Closes the open inventory session. |
| `/trunk`, `/hood` | Toggle the lid from the driver seat. Names come from `vehicles.doors.commandNames` and are read once at start; `commands = false` registers neither. |

## Keybinds

Registered through `Kora.keybind`, so players can rebind them in Settings > Key Bindings > FiveM.

| Binding | Default | Effect |
| --- | --- | --- |
| `openInv` | `TAB` | Same as `/inventory`. |
| `kora_inventory:hotbar1` ... `hotbarN` | `1` ... `5` | Use the item in that slot (`N` is `Config.kora_inventory.hotbarSlots`). Ignored while the NUI is focused or the pause menu is open. |
| `kora_inventory:hotbarshow` | `U` | Show the on-screen hotbar for `ui.hotbarSeconds` seconds (`0` disables the key). |
