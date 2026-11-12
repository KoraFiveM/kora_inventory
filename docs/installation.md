---
title: Installation
sidebar_position: 2
---

# Installation

## Dependencies

Declared with `dependency` in `fxmanifest.lua`:

| Resource | Used for |
| --- | --- |
| `kora_theme` | NUI theme bridge (`@kora_theme/client/bridge.lua`) |
| `kora_lib` | Shared init, `Kora.callback`, `Kora.keybind`, `Kora.notify`, `Kora.progressbar`, `Kora.blips`, locales, config |
| `kora_sql` | Table creation and checked transactions for secondary inventories |
| `kora_core` | Player data and the `items` registry, money, jobs, the persistence fences |
| `kora_target` | Shop counters, clerk peds, vending machine models, trunk/hood targets, give-target selection |

Used when present but not declared as dependencies: `kora_hud` (the client registers the window with its `/ui` editor, guarded by `GetResourceState`), and the state flags other resources publish: `kora_vehiclekeys` (`kora_vehiclekeys:locked` entity state), `kora_police` (`ishandcuffed` metadata and `koraCuffed` bag), `kora_ambulance` (`isdead` / `inlaststand` metadata). `kora_mdt` is only checked by name for the Legion Square Ammu-Nation clerk (see [Shops](./shops.md)). `kora_drugs` is the default entry of `Config.kora_inventory.exchangeCallers` (see [Player exchanges](./exchanges.md)).

## Start order

```cfg
set mysql_connection_string "mysql://user:pass@localhost/kora_core?charset=utf8mb4"
ensure kora_sql
ensure kora_lib
ensure kora_core
ensure kora_inventory
```

Start `kora_inventory` after `kora_core`. Do not run a real `qb-inventory`, `ox_inventory` or `qb-weapons` at the same time: `server/compat/providers.lua` raises an error at start when a physically named resource with one of those names is started.

No SQL needs importing. The tables are created and extended at start from `server/schema.lua` (see [Database](./database.md)).

## Migrating from qb-inventory or ox_inventory

After `kora_inventory` has booted, run from the server console (or as a player holding the ACE permissions in [Commands and keybinds](./commands.md)):

```text
kora_inventory-migrate dry-run
kora_inventory-migrate run
kora_inventory-migrate verify
kora_inventory-migrate retry
```

See [Database](./database.md) for what each action reads and writes. Legacy rows are copied, never deleted or updated.

## Replacing artwork

Item artwork lives in `images/` and is served as `nui://kora_inventory/images/<file>`. See [Items](./items.md).

## Optional FFT hooks

Only if you run the companion `fft` resource: see [FFT hooks](./fft.md).
