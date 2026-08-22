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

## Item containers and evidence

`server/containers.lua` is a trusted server-only domain with no NUI or net
event entry point. Do not add a generic client event that accepts a container
identifier, evidence case, owner, target player, item record, item metadata,
or slot as authority. A gameplay resource must resolve its interaction on the
server before calling the bounded API.

Generic containers require an owner derived from `ownerSource`, a trusted
access/group policy, or a fixed coordinate boundary. Portable containers bind a
server-generated `info.containerId` to a real qbcore-owned player item through
the mutation funnel. Configured portable item types (`containers.items`) are
opened only through the existing validated `use` intent: resolve the real slot,
item definition, and present-possession policy on the server; never accept a
container ID from the browser. Keep portable containers out of other containers
unless an explicit nesting policy is added. Evidence/confiscation is default-deny and must retain its
server-side access, target entity, range, routing-bucket, slot/amount, capacity
and deterministic-lock checks. Metadata always comes from the source item.

## Tests

Keep the plain-Lua smoke tests deterministic and do not require a running
FXServer. Add a test whenever shared item/slot rules or public exports change.
After changing `web/`, run `pnpm install --frozen-lockfile && pnpm typecheck &&
pnpm build` in that folder and commit the regenerated `web/build/` artifacts.
