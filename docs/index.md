---
title: kora_inventory
sidebar_position: 1
---

# kora_inventory

`kora_inventory` is the server-authoritative inventory for Kora servers, with a bundled NUI. It owns stashes, temporary stashes, ground drops, shops, vehicle trunks and gloveboxes, item containers, evidence and confiscation, crafting, weapon metadata and visible weapon carry, sessions and audit events. It also publishes `qb-inventory`, `ox_inventory` and `qb-weapons` compatibility identities so existing resources keep working. A real `qb-inventory`, `ox_inventory` or `qb-weapons` resource must not run next to it (the resource refuses to start if one is running).

Current version: see `version` in `fxmanifest.lua`.

Player items are never stored by this resource: `kora_core` owns the slot-keyed `PlayerData.items` and the `players.inventory` column, and `kora_inventory` only changes them through kora_core's mutation funnel (`setPath`). Everything else is stored in this resource's own tables, created automatically at start (see [Database](./api/persistence.md)).

## Features

- **Player inventory** - 41 slots and 120 kg by default (`Config.kora_inventory.playerSlots`, `playerMaxWeight`), drag and drop, split, give, drop, use. See [Exports](./exports.md).
- **Stashes** - shared, per-citizen (template) and policy-guarded stashes, plus temporary stashes. See [Stashes and drops](./api/stashes.md).
- **Ground drops** - dropped items become a bag on the floor; nearby drops merge. See [Stashes and drops](./api/stashes.md).
- **Shops** - bundled 24/7, liquor, Ammu-Nation and vending machine shops, plus `RegisterShop` for your own. See [Shops](./api/shops.md).
- **Vehicle storage** - trunk and glovebox by vehicle class, opened with the inventory key; trunk and hood toggles. See [Vehicles](./api/vehicles.md).
- **Item containers and evidence** - portable containers (backpack) and an evidence/confiscation domain. See [Containers and evidence](./api/containers.md).
- **Crafting API** - a headless recipe and craft API for other resources. See [Crafting](./api/crafting.md).
- **Weapons** - serials, durability, ammunition, ballistics, visible carry on the body and timed draw/holster. See [Weapons](./api/weapons.md).
- **Durable exchanges** - idempotent item/cash swaps for trusted resources. See [Player exchanges](./api/exchange.md).
- **Hooks** - ox-style `registerHook` and qb-style `AddHook`/`AddListener`. See [Hooks](./api/hooks.md).
- **Compatibility** - `qb-inventory`, `ox_inventory` and `qb-weapons` identities. See [Compatibility](./compatibility.md).
- **Downed, cuffed and busy blocks** - inventory use is refused while downed or cuffed, while an item is in use, or while another resource blocks the UI. See [Security model](./security.md).

## Documentation map

Getting started

- [Installation](./installation.md) - requirements, start order, manifest, dependencies, legacy import, startup troubleshooting.
- [How to use](./how-to-use.md) - day-to-day player and developer workflows.
- [Commands and keybinds](./commands.md) - `/inventory`, `/trunk`, `/hood`, `kora_inventory-migrate`, key bindings, ACE.

API reference

- [API reference](./api/index.md) - module overview with namespaces and realms.
- [Player items](./api/player-items.md) - add, remove and query player items through kora_core.
- [Items and metadata](./api/items.md) - item definition fields, metadata and artwork.
- [Opening inventories and sessions](./api/inventories.md) - open, close and inspect sessions.
- [Stashes](./api/stashes.md) - stashes, policy stashes, temporary stashes, claims.
- [Shops](./api/shops.md) - bundled and custom shops, buying.
- [Drops](./api/drops.md) - ground drops.
- [Usable items](./api/usables.md) - server handlers for item use.
- [Crafting](./api/crafting.md) - recipe and craft API.
- [Hooks](./api/hooks.md) - ox-style and qb-style hooks and payloads.
- [Weapons and weapon carry](./api/weapons.md) - metadata, ammo, ballistics, carry, parachute.
- [Vehicle storage](./api/vehicles.md) - trunk, glovebox, door toggles.
- [Containers and evidence](./api/containers.md) - portable and generic containers.
- [Evidence and confiscation](./api/evidence.md) - evidence cases and seizing.
- [Durable player exchanges](./api/exchange.md) - `ExecutePlayerExchange`.
- [Persistence and migration](./api/persistence.md) - tables, restore and legacy import.
- [Physical cash bridge](./api/cash.md) - cash as an item.
- [Events and callbacks](./api/events.md) - net events, local events, callbacks, state bags.
- [Client API](./api/client-api.md) - client exports.
- [NUI contract](./api/nui.md) - sessions, renderer contract, presentation config.
- [qb-inventory compat](./api/compat-qb.md) - `exports['qb-inventory']` identity.
- [ox_inventory compat](./api/compat-ox.md) - `exports.ox_inventory` identity.
- [qb-weapons compat](./api/compat-qb-weapons.md) - `qb-weapons` identity.
- [Configuration](./api/configuration.md) - every `Config` key.

Topics

- [Exports](./exports.md) - code-derived list of server and client exports.
- [Compatibility](./compatibility.md) - qb/ox/qb-weapons identities and deliberate divergences.
- [Security model](./security.md) - authority rules.
- [FFT hooks](./fft.md) - optional FFT test integration.
- [Development](./development.md) - tests and rebuilding the NUI.
- [Troubleshooting](./troubleshooting.md) - common problems.
