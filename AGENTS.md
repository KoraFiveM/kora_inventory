# kora_inventory agent guide

## Boundary

`kora_inventory` ships its own NUI, but its inventory engine remains headless in
the architectural sense: `server.lua` is the sole authority and never calls
NUI APIs. `client.lua` owns the server transport; `client/ui.lua` owns the
NUI/focus bridge and may only forward restricted intent envelopes back to
`qbinventory:client:submitIntent`. Do not let browser state mutate inventory
data directly.

## Player data

Player items remain exclusively in kora_core's `PlayerData.items` and its
`players.inventory` persistence column. Never create a kora_inventory player-item
table and never mutate a player inventory other than through kora_core exports.
Resolve item definitions through kora_core's getter at use time; never cache or
index the legacy `QBCore.Shared.Items` map. Registry-driven built-in use
handlers must subscribe to runtime add/update/remove changes.

## Security

Every client mutation must validate an active lease, both revisions, access,
routing bucket, and distance before touching state. Client data is intent only:
never trust item records, labels, weights, prices, item definitions, or IDs
outside the inventory IDs granted by that session.

An inventory's trusted `coords` may be one point or an array of fixture points.
Both forms must stay behind the single `withinCoordinates` check in `canAccess`;
an empty or malformed non-nil policy denies access, while nil means unbounded.
List entries may carry a trusted `distance` override; do not collapse different
fixture radii into one wider boundary that applies to every point.

Durable secondary items may carry trusted top-level `serverData` for server
integrations. It must be removed by `view`, never copied into purchased item
metadata, and may reach integrations only through post-commit server events.

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

## Visible weapon carry

`server/weaponcarry.lua` builds the carried-weapon list from qbcore-owned
`PlayerData` and publishes it on the replicated player state bag
`qbinventory:weaponCarry`. `client/weaponcarry.lua` only RENDERS that bag. Do
not add a client event, NUI callback or export that lets a client submit,
extend or edit a carried list -- that would make the bag a channel for
advertising items a player does not own, or hiding ones they do. Clear the bag
with an explicit `false`, never a nil deletion.

The one client->server message in this domain
(`qbinventory:server:weaponToggled`) may only confirm a pending draw/holster
this server itself issued, and is re-resolved against the real slot before it
is believed. Keep it that way: no item record, name, duration or equipped
state may be accepted from the client. `qbinventory:server:weaponUnequipped`
is payload-free on purpose -- it can only ever put a weapon back on its own
player's body, never take one off.

## Tests

Keep the plain-Lua smoke tests deterministic and do not require a running
FXServer. Add a test whenever shared item/slot rules or public exports change.
After changing `web/`, run `pnpm install --frozen-lockfile && pnpm typecheck &&
pnpm build` in that folder and commit the regenerated `web/build/` artifacts.
