# qbinventory

`qbinventory` is the server-authoritative inventory provider. Its direct API is
production work in progress; it deliberately does **not** yet advertise the
`qb-inventory` or `ox_inventory` provider identities because their exact
upstream contracts are not complete or contract-tested.

## Ownership and startup

Player inventory ownership never moves: qbcore owns the slot-keyed
`PlayerData.items` object and the `players.inventory` database column.
qbinventory makes player mutations only through qbcore's `setPath` funnel, so
replication and persistence remain single-writer. qbinventory owns secondary
inventory state (stashes, temporary stashes, drops, and shops), sessions,
revisions, locks, hook registration, and audit events.

## Durable secondary storage and migration

`server/persistence.lua` owns durable storage exclusively for secondary
inventories: stashes, trunks, gloveboxes, containers, shops and optional drops.
It never reads or writes `PlayerData.items` or `players.inventory`; those remain
qbcore's canonical player store.

The qbsql migration creates `qbinventory_inventories` (items, properties and
revision), `qbinventory_shop_stock`, audit, migration-state/row and quarantine
tables. Legacy rows are copied, never deleted or updated. An already imported
row with the same checksum is skipped; a changed legacy row is reported rather
than overwriting a possibly-live qbinventory record. Malformed JSON/item slots
are retained in `qbinventory_quarantine` for operator review.

Run these from the server console (or grant `command.qbinventory`):

- `qbinventory-migrate dry-run` — inspect import eligibility without writing.
- `qbinventory-migrate run` — idempotently import eligible legacy data.
- `qbinventory-migrate verify` — validate stored item JSON and print migration state.
- `qbinventory-migrate retry` — revisit only previously failed/quarantined rows.

The importer inspects, when present, `inventories`, `stashitems`, `trunkitems`,
and `gloveboxitems`. It accepts common identifier/slot/weight column spellings
and preserves original item metadata.

Start it after `qbcore`. The bundled `web/` NUI starts with qbinventory, while
the server API and client session transport remain usable by another renderer.

## Server API

The lower-camel exports are the qbcore gateway surface:

- `getWeight`, `canCarry`, `addItem`, `removeItem`, `getItemByName`,
  `getItemsByName`, `getItemBySlot`, `getItemCount`, `hasItem`, `getFreeSlot`,
  `moveItem`, `clearInventory`, `setItems`, `createUseable`, `useItem`
- `stashGet`, `stashSet`, `stashOpen`, `dropCreate`, `dropTake`

qb-style aliases are also exported (`AddItem`, `RemoveItem`, `OpenInventory`,
`GetStashItems`, `RegisterStash`, and so on), alongside ox-style constructors
`RegisterStash`, `CreateTemporaryStash`, `RegisterShop`, `BuyItem`,
`RegisterHook`, and `RemoveHooks`. The same aliases are explicitly registered
under both provided resource identities.

## Client and renderer contract

`openInventory(type, data)`, `closeInventory()`, and `submitIntent(intent)` are
the client exports. Their server transport emits local presentation events:

- `qbinventory:ui:sessionOpened({ token, primary, secondary, expires })`
- `qbinventory:ui:sessionPatched({ token, patch })`
- `qbinventory:ui:sessionClosed({ token, reason })`
- `qbinventory:ui:rejected({ reason })`

The client receives a short-lived token only after the server resolves and
authorises the target inventory. Every transfer checks the token, both current
revisions, slots, amount, server item data, routing bucket, access policy, and
distance immediately before mutation. Viewers of a shared inventory receive a
revisioned replacement view after each committed change; stale actions are
rejected rather than merged.

## Security guardrails

There is deliberately no client event, callback, or NUI endpoint that accepts
a complete inventory table for replacement. Browser and client payloads are
limited to an action intent plus slots and amounts; qbinventory resolves item
records, inventory identifiers, prices, permissions, and revisions again on
the server.

Shops are read-only in the generic transfer path. A shop item can only leave
through the dedicated `buy` intent, which revalidates the open session, shop
type, stock, both revisions, access/distance, and server-side payment before
adding the server-resolved item to the qbcore-owned player inventory. A failed
add after payment is refunded by the server.

The NUI bridge is separated from the inventory transport: only `client/ui.lua`
uses browser callbacks, focus, or `SendNUIMessage`; it hands a restricted
envelope to the local `qbinventory:client:submitIntent` event. `client.lua`
then attaches the current server-issued token and revisions before forwarding
an allowed action. `server.lua` contains no NUI calls or callbacks.

## Headless boundary

`server.lua` must not gain a NUI callback, `SendNUIMessage`, or focus call.
The bundled `client/ui.lua` bridge owns the NUI page and translates its
restricted intent envelope back to the headless client API. Browser state is
never treated as authoritative.
