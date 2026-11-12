---
title: Development
sidebar_position: 10
---

# Development

## Tests

Plain-Lua smoke tests in `test/smoke/` run without a FiveM server. Run them all with:

```bash
bash test/run.sh
```

Contract names for the qb and ox identities are pinned in `test/contracts/upstream.lua`. `python3 test/exchange_database.py` is an optional database check for player exchanges (it starts a disposable socket-only MariaDB). `tests/*.feature` are kora_qa Gherkin scenarios (`qa_feature` in the manifest). Add a test whenever shared item or slot rules or public exports change.

`test/smoke/access_policy.lua` reads the root `docs.md`, a legacy long-form page that is kept so that test keeps passing. The maintained documentation is this `docs/` folder.

## NUI

After changing `web/`:

```bash
cd web
pnpm install --frozen-lockfile && pnpm typecheck && pnpm build
```

Commit the regenerated `web/build/` files, which are what the manifest serves.

## Layout

- `server.lua` - authority: sessions, revisions, transfers, stashes, shops, drops, hooks, exports.
- `server/` - `schema.lua`, `persistence.lua`, `recovery.lua`, `exchange.lua`, `crafting.lua` (and weapon metadata), `useables.lua`, `vehicles.lua`, `containers.lua`, `weaponcarry.lua`, `shops/`, `compat/`.
- `client.lua`, `client/` - transport, NUI bridge, hotbar, drops, vehicles, shops, weapon carry, compat.
- `shared.lua`, `config.lua`, `config/shops/` - shared rules and configuration.
- `web/`, `html/`, `images/`, `locales/` - NUI source and build, legacy images, artwork, strings.
