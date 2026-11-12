---
title: kora_inventory
sidebar_position: 1
---

# kora_inventory

`kora_inventory` is the server-authoritative inventory for Kora servers, with a bundled NUI. It owns stashes, temporary stashes, ground drops, shops, vehicle trunks and gloveboxes, item containers, evidence and confiscation, crafting, weapon metadata and visible weapon carry, sessions and audit events. It also publishes `qb-inventory`, `ox_inventory` and `qb-weapons` compatibility identities so existing resources keep working. A real `qb-inventory`, `ox_inventory` or `qb-weapons` resource must not run next to it (the resource refuses to start if one is running).

Current version: see `version` in `fxmanifest.lua`.

Player items are never stored by this resource: `kora_core` owns the slot-keyed `PlayerData.items` and the `players.inventory` column, and `kora_inventory` only changes them through kora_core's mutation funnel (`setPath`). Everything else is stored in this resource's own tables, created automatically at start (see [Database](./database.md)).

## Features

- **Player inventory** - 41 slots and 120 kg by default (`Config.kora_inventory.playerSlots`, `playerMaxWeight`), drag and drop, split, give, drop, use. See [Exports](./exports.md).
- **Stashes** - shared, per-citizen (template) and policy-guarded stashes, plus temporary stashes. See [Stashes and drops](./stashes-and-drops.md).
- **Ground drops** - dropped items become a bag on the floor; nearby drops merge. See [Stashes and drops](./stashes-and-drops.md).
- **Shops** - bundled 24/7, liquor, Ammu-Nation and vending machine shops, plus `RegisterShop` for your own. See [Shops](./shops.md).
- **Vehicle storage** - trunk and glovebox by vehicle class, opened with the inventory key; trunk and hood toggles. See [Vehicles](./vehicles.md).
- **Item containers and evidence** - portable containers (backpack) and an evidence/confiscation domain. See [Containers and evidence](./containers-evidence.md).
- **Crafting API** - a headless recipe and craft API for other resources. See [Crafting](./crafting.md).
- **Weapons** - serials, durability, ammunition, ballistics, visible carry on the body and timed draw/holster. See [Weapons](./weapons.md).
- **Durable exchanges** - idempotent item/cash swaps for trusted resources. See [Player exchanges](./exchanges.md).
- **Hooks** - ox-style `registerHook` and qb-style `AddHook`/`AddListener`. See [Hooks](./hooks.md).
- **Compatibility** - `qb-inventory`, `ox_inventory` and `qb-weapons` identities. See [Compatibility](./compatibility.md).
- **Downed, cuffed and busy blocks** - inventory use is refused while downed or cuffed, while an item is in use, or while another resource blocks the UI. See [Security model](./security.md).

## Pages

- [Installation](./installation.md) - dependencies, start order, legacy import.
- [Configuration](./configuration.md) - every `Config` key.
- [Commands and keybinds](./commands.md) - console command, chat commands, keys, ACE.
- [Exports](./exports.md) - server and client exports.
- [Events](./events.md) - net events, local events, callbacks, state bags.
- [Hooks](./hooks.md) - hook events and payloads.
- [Stashes and drops](./stashes-and-drops.md) - stashes, temporary stashes, drops.
- [Shops](./shops.md) - bundled and custom shops.
- [Vehicles](./vehicles.md) - trunk, glovebox, door toggles.
- [Containers and evidence](./containers-evidence.md) - portable containers, evidence.
- [Crafting](./crafting.md) - recipe API.
- [Weapons](./weapons.md) - metadata, ammo, carry, parachute.
- [Player exchanges](./exchanges.md) - `ExecutePlayerExchange`.
- [Items](./items.md) - item definition fields and artwork.
- [Compatibility](./compatibility.md) - qb/ox/qb-weapons identities.
- [Database](./database.md) - tables and legacy migration.
- [UI](./ui.md) - the NUI and renderer contract.
- [Security model](./security.md) - authority rules.
- [FFT hooks](./fft.md) - optional FFT test integration.
- [Development](./development.md) - tests and rebuilding the NUI.
- [Troubleshooting](./troubleshooting.md) - common problems.
