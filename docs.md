# qbinventory

`qbinventory` is the headless, server-authoritative inventory provider. It
provides both `qb-inventory` and `ox_inventory` resource identities so a server
can migrate consumers without running either upstream inventory beside it.

## Ownership and startup

Player inventory ownership never moves: qbcore owns the slot-keyed
`PlayerData.items` object and the `players.inventory` database column.
qbinventory makes player mutations only through qbcore's `setPath` funnel, so
replication and persistence remain single-writer. qbinventory owns secondary
inventory state (stashes, temporary stashes, drops, and shops), sessions,
revisions, locks, hook registration, and audit events.

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

## Headless boundary

`server.lua` must not gain a NUI callback, `SendNUIMessage`, or focus call.
The bundled `client/ui.lua` bridge owns the NUI page and translates its
restricted intent envelope back to the headless client API. Browser state is
never treated as authoritative.
