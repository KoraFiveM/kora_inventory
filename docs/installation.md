---
title: "Installation"
sidebar_position: 2
---


# Installation

Kora Inventory is the server-authoritative inventory for the Kora framework. It ships its own NUI (already built into web/build), stores secondary inventories (stashes, shops, trunks, containers) in the database, and keeps player items inside kora_core. Install it after its five dependencies and before any resource that grants, removes or sells items.

## Requirements

- FiveM server artifact with `lua54 'yes'` support (the manifest requires it) and a MySQL/MariaDB database.
- The five resources named in `fxmanifest.lua` as `dependency`: `kora_theme`, `kora_lib`, `kora_sql`, `kora_core` and `kora_target`. FiveM starts them first even if your `server.cfg` lists kora_inventory earlier.
- `kora_sql` needs your database connection string (`set mysql_connection_string ...`). Kora Inventory creates its own tables through kora_sql at startup, so there is no SQL file to import.
- No other inventory resource may be running. `server/compat/providers.lua` raises an error at startup if a separate `qb-inventory`, `ox_inventory` or `qb-weapons` resource is already started, because kora_inventory provides those identities itself.

## Install Kora Inventory

1. **Place the folder** — Put the `kora_inventory` folder in your resources directory and keep its name. Other resources call it as `exports.kora_inventory`, and the NUI asset paths use `nui://kora_inventory/...`.

2. **Start it from server.cfg** — Start the framework resources first, then the inventory, then the resources that use it:

   ```bash title="server.cfg"
   set mysql_connection_string "mysql://user:password@localhost/your_database?charset=utf8mb4"

   ensure kora_theme
   ensure kora_lib
   ensure kora_sql
   ensure kora_core
   ensure kora_target
   ensure kora_inventory
   ensure [kora]
   ```

3. **Let it create its tables** — On the first start `server/schema.lua` declares eight `kora_inventory_*` tables and `Kora.sql.ensureTables` creates any that are missing. Existing installs only gain missing columns or keys. The console prints `[kora_inventory:persistence] secondary-inventory schema ready.` followed by `restored N secondary inventories.` once stored stashes and shops are loaded.

4. **Grant the migration ACE (optional)** — Only needed if you want to run the legacy import command from in-game. The command always works from the server console.

   ```bash title="server.cfg"
   add_ace group.admin command.kora_inventory allow
   ```

   > The command is registered as restricted (`server/persistence.lua:870`), so the engine also checks `command.kora_inventory-migrate` for a player. Grant both; see [Commands](./commands.md).

5. **Restart and check the console** — Look for `secondary-inventory schema ready`, `restored ... secondary inventories` and, if physical cash is enabled, `physical cash enabled for kora_core account cash as item cash`. A `provider conflict` error means another inventory resource is still running.

## What the manifest declares

The manifest is the best map of the resource. These are the parts other resources care about.

```text title="fxmanifest.lua (excerpt)"
name 'kora_inventory'
provide 'qb-inventory'
provide 'ox_inventory'
provide 'qb-weapons'

dependency 'kora_theme'
dependency 'kora_lib'
dependency 'kora_sql'
dependency 'kora_core'
dependency 'kora_target'

shared_scripts { '@kora_lib/init.lua', '@kora_sql/init.lua', 'config.lua',
    'config/shops/ammunation.lua', 'config/shops/vendingmachine.lua',
    'config/shops/liquorstore.lua', 'config/shops/convenience.lua', 'shared.lua' }

ui_page 'web/build/index.html'
```

- `provide` lines make `exports['qb-inventory']`, `exports.ox_inventory` and `exports['qb-weapons']` resolve to this resource. The qb-inventory and ox_inventory identities have their own export tables with upstream return shapes, so `exports['qb-inventory']:GetInventory(...)` and `exports.kora_inventory:GetInventory(...)` return different things. See the two Compat modules.
- Server scripts load in a fixed order: schema, persistence, the authority (`server.lua`), recovery, exchange, crafting, useables, vehicles, containers, weapon carry, qb-weapons adapter, the four bundled shops, then the qb/ox compat modules and `providers.lua`.
- `files` publishes `locales/*.json`, the built NUI (`web/build/...`), item artwork (`images/**/*`, served as `nui://kora_inventory/images/<file>`) and `html/images/**/*` for legacy consumers.
- Item artwork is looked up as `images/<item name>.<ext>`. Drop your own file there; `pnpm build` cannot delete it because the images live outside `web/`.

## Rebuilding the NUI (developers)

The committed `web/build` folder is the runtime artifact. After editing anything under `web/src`, run `pnpm install --frozen-lockfile && pnpm typecheck && pnpm build` inside `web/` and commit the regenerated build. The plain-Lua smoke tests under `test/smoke` run without a FXServer (`test/run.sh`).

## If it does not start

- `provider conflict: qb-inventory is running` — stop the other inventory resource.
- `secondary inventory restore failed` or `schema setup failed` — kora_sql is not ready or the database user cannot create tables. Fix the connection and restart kora_inventory.
- Stashes never open after a restart — check `exports.kora_inventory:getPersistenceStatus()`; a stash whose `RegisterStash` ran before persistence finished is merged with its stored contents once restoration completes.
- Items show a letter instead of artwork — the file is not in `images/`, or `Config.kora_inventory.ui.images.allowRemote` is false and the item has no local file.
- The inventory will not open — the player is downed, cuffed, using a progress bar, or another resource set the `koraUiBlocked` state bag. See Configuration, "Blocking rules".

## Dependencies (from the code)

Declared with `dependency` in `fxmanifest.lua`:

| Resource | Used for |
| --- | --- |
| `kora_theme` | NUI theme bridge (`@kora_theme/client/bridge.lua`) |
| `kora_lib` | Shared init, `Kora.callback`, `Kora.keybind`, `Kora.notify`, `Kora.progressbar`, `Kora.blips`, locales, config |
| `kora_sql` | Table creation and checked transactions for secondary inventories |
| `kora_core` | Player data and the `items` registry, money, jobs, the persistence fences |
| `kora_target` | Shop counters, clerk peds, vending machine models, trunk/hood targets, give-target selection |

Used when present but not declared as dependencies: `kora_hud` (the client registers the window with its `/ui` editor, guarded by `GetResourceState`), and the state flags other resources publish: `kora_vehiclekeys` (`kora_vehiclekeys:locked` entity state), `kora_police` (`ishandcuffed` metadata and `koraCuffed` bag), `kora_ambulance` (`isdead` / `inlaststand` metadata). `kora_mdt` is only checked by name for the Legion Square Ammu-Nation clerk (see [Shops](./api/shops.md)). `kora_drugs` is the default entry of `Config.kora_inventory.exchangeCallers` (see [Durable player exchanges](./api/exchange.md)).

## Migrating from qb-inventory or ox_inventory

After `kora_inventory` has booted, run from the server console (or as a player holding the ACE permission in [Commands](./commands.md)):

```text
kora_inventory-migrate dry-run
kora_inventory-migrate run
kora_inventory-migrate verify
kora_inventory-migrate retry
```

See [Persistence and migration](./api/persistence.md) for what each action reads and writes. Legacy rows are copied, never deleted or updated.

## Optional FFT hooks

Only if you run the companion `fft` resource: see [FFT hooks](./fft.md).
