# qbinventory agent guide

## Boundary

`qbinventory` ships its own NUI, but its inventory engine remains headless in
the architectural sense: `server.lua` is the sole authority and never calls
NUI APIs. `client.lua` owns the server transport; `client/ui.lua` owns the
NUI/focus bridge and may only forward restricted intent envelopes back to
`qbinventory:client:submitIntent`. Do not let browser state mutate inventory
data directly.

## Player data

Player items remain exclusively in qbcore's `PlayerData.items` and its
`players.inventory` persistence column. Never create a qbinventory player-item
table and never mutate a player inventory other than through qbcore exports.

## Security

Every client mutation must validate an active lease, both revisions, access,
routing bucket, and distance before touching state. Client data is intent only:
never trust item records, labels, weights, prices, item definitions, or IDs
outside the inventory IDs granted by that session.

## Tests

Keep the plain-Lua smoke tests deterministic and do not require a running
FXServer. Add a test whenever shared item/slot rules or public exports change.
After changing `web/`, run `pnpm install --frozen-lockfile && pnpm typecheck &&
pnpm build` in that folder and commit the regenerated `web/build/` artifacts.
