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

`RegisterStash(..., owner = true, ...)` is a private-stash template. It does
not create a shared stash with a boolean owner flag: on open, qbinventory
derives the caller's citizen id server-side and uses a separate durable
`stash:<template>:<citizenid>` record. A caller cannot choose another owner's
identifier through the client transport.

## Crafting and weapons (server-only foundation)

`server/crafting.lua` is a headless, server-only foundation. It deliberately
registers no network event or NUI callback. A gameplay resource must complete
its own server-resolved station, job, proximity, routing-bucket and progression
checks, then call `CraftItem(source, recipeId, trustedContext)`. Do not forward
a client recipe, output, item metadata, count or `trustedContext` to this API.

Register a static recipe from its owning server resource:

```lua
exports.qbinventory:RegisterCraftRecipe('repair_board', {
  ingredients = { { name = 'wood', amount = 2, metadata = { grade = 'oak' } } },
  output = { name = 'board', amount = 1, metadata = { quality = 100 } },
  access = function(source, recipe, context)
    -- `context` is server-owned station state, never a raw client payload.
    return true
  end,
})
```

Crafting locks the qbcore-owned player inventory, makes a detached plan,
validates all recipe ingredients/weight/slots, then commits through
`qbcore:setPath` via qbinventory's authority seam. A failed recipe changes no
slots. Hooks can approve/reject a craft but cannot mutate its planned state.

Weapon helpers are also server-only: `PrepareWeaponMetadata`, `GetWeaponState`,
`SetWeaponState`, `ConsumeWeaponDurability`, `SetWeaponAmmo`, and
`SetWeaponComponents`. New weapon metadata receives a server serial, bounded
durability and ammo, and only configured components in
`Config.qbinventory.weapons.components` are accepted. Gameplay weapon-use code
must invoke durability/ammo changes from validated server actions; do not add a
generic client event for these exports.

This foundation does not yet supply a crafting UI, station discovery, progress
timers, GTA weapon-native synchronisation, or ammo-item conversion. Those
require an explicit server-authoritative integration layer.

Opening another player's inventory is also denied by default: distance and
routing-bucket checks are necessary but never sufficient. Configure the trusted
`Config.qbinventory.playerInspection.access(source, target, sourceData,
targetData)` callback, or register a server-only policy through
`RegisterInspectionAccess`, and return `true` only for an authorised
police/admin/consent flow. Policies are removed automatically with their
resource. Returning `false, reason` or raising an error denies; there is no
permissive configuration toggle.

## Vehicles and containers

`server/vehicles.lua` is the isolated trunk/glovebox domain. It derives the
canonical persistent keys `trunk:<NORMALISED_PLATE>` and
`glovebox:<NORMALISED_PLATE>` from a live **server-resolved** entity. A client
open request may contain only a network id; qbinventory never accepts a
client-supplied plate, class, coordinates, capacities, or arbitrary vehicle
inventory key.

Before an inventory is opened—and again during each active-session access—the
module verifies entity existence/type, player entity, routing bucket, server
coordinates/range, native plate, vehicle class and configured capacity. Native
plates are trimmed, uppercased, whitespace-normalised and restricted to the
configured GTA plate alphabet before becoming a storage key. Configure slots
and weight by class in `Config.qbinventory.vehicles.classes`; set a type to
`false` to disable it for that class.

For ownership/keys/faction policy, set `vehicles.ownerCheck` and/or
`vehicles.accessCheck` to trusted server callbacks, or register scoped runtime
checks with `QbInventory.vehicles.registerAccess(callback, options)`. Returning
`false, reason` denies access. Hooks receive only a server-generated vehicle
descriptor and can be cleaned with `cleanupResource(resourceName)`.

`server/vehicles.lua` is loaded after the authority and `openInventory` already
routes trunk/glovebox requests through it. Integrations must pass the network
id only—never a `plate`, `key`, coordinates, or capacity object.

## Item containers, evidence, and confiscation

`server/containers.lua` is a server-only domain module. It registers no NUI
callback or client network event: item records, container IDs, owner IDs,
evidence IDs, target slots, and target players must be resolved by a trusted
server resource before it calls this API.

`QbInventory.containers.create(id, options)` makes a generic secondary
`container:<id>`. IDs are strict, bounded server identifiers; a new container
is rejected unless it has a citizen owner derived from `ownerSource`, a trusted
access/group policy, or a fixed world coordinate. Initial items are checked by
the core's normal slot/item/weight validator. `open(source, id)` is for an
existing container only and still passes the core access/distance checks.

For a portable item container, trusted code calls
`QbInventory.containers.bindItem(source, slot, options)`. The module reads the
actual qbcore-owned slot, derives the caller's citizen ID, generates the
identifier server-side, and writes `info.containerId` through qbcore's mutation
funnel. `openItem(source, slot)` then reads that same current server slot. It
does not accept a browser/client item table, owner, or container identifier.

Evidence and confiscation share `QbInventory.evidence` (also exposed as
`QbInventory.confiscation`):

- `open(source, evidenceId)`
- `seize(source, targetSource, evidenceId, sourceSlot, amount, evidenceSlot?)`
- `release(source, targetSource, evidenceId, evidenceSlot, amount, playerSlot?)`

Evidence is default-deny. Configure a trusted
`Config.qbinventory.containers.evidence.access(source, action, context)` that
returns `true` only for authorised server-side policy (job/ACE/restraint/case
ownership). Seize/release resolve both player inventories on the server and
check target entity existence, routing bucket, range, exact current slot and
amount, capacity, and the policy again while holding deterministic inventory
locks. Metadata is carried only from the server item record. A successful move
emits `qbinventory:server:evidenceMoved` after both revisioned views have been
broadcast. Never forward raw client identifiers or item data into these calls.

### Integration boundary

The bundled manifest loads this module after the authority. Do **not** add a
generic `qbinventory:server:openContainer` or `seizeEvidence` net event; a resource
that wants a player-facing action must first translate its own validated
server-side interaction into one of the functions above. This preserves the
headless core boundary and avoids accepting a client-selected evidence case,
target player, or inventory key.

## Durable secondary storage and migration

`server/persistence.lua` owns durable storage exclusively for secondary
inventories: stashes, trunks, gloveboxes, containers, evidence, shops and
optional drops.
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
`RegisterHook`, and `RemoveHooks`. These are direct `qbinventory` exports
only. Do not enable the `qb-inventory` or `ox_inventory` provider identities
until their upstream contracts have been completed and contract-tested.

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

### qb-inventory client bridge

`client/compat.lua` keeps the conventional client-facing qb-inventory surface
safe during migration. It listens for `qb-inventory:client:openInventory`,
`closeInv`, and `updateInventory` (plus the narrowly equivalent old
`inventory:client:*` aliases), the `inventory`, `openInv`, and `closeInv`
commands, and the default `openInv`/`TAB` key mapping.

Legacy item tables, slot counts, labels, weights and metadata are never read.
An open event contributes only a validated identifier request; qbinventory's
server then resolves the inventory, checks access/distance/bucket rules and
returns its own session snapshot. `updateInventory` re-opens the current
server-issued target to obtain a fresh authoritative snapshot. No vehicle or
entity discovery happens client-side.

`LocalPlayer.state.inv_busy` is set only while a qbinventory UI session is
open, and released on the matching session-close event or resource stop. NUI
focus remains exclusively owned by `client/ui.lua`.

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

### Bundled Ammu-Nation

`config/shops/ammunation.lua` defines one finite-stock `ammunation` shop and
the approved world counters. Its stock is intentionally declarative
`{ name, amount, price }` data: qbinventory must build each canonical item view
from qbcore's registry, rather than accepting labels, images, weights or other
item fields from configuration or a client.

`client/shops/ammunation.lua` creates qblib interaction zones and map blips as
presentation only. Selecting a zone sends the fixed shop identifier through
the normal inventory open request; it does not send a location, price, stock
row or item data. `server/shops/ammunation.lua` registers the shop with an
access callback that independently reads the player's server ped coordinates
and routing bucket, and permits the open only inside a configured counter. A
forged shop-ID request away from a counter or in another bucket is denied.

The initial catalog includes standard qbcore weapons and the registered
`pistol_ammo`, `smg_ammo`, `shotgun_ammo`, `rifle_ammo`, `mg_ammo`, and
`snp_ammo` packs. Load the three Ammu-Nation files after
`config.lua`/`server.lua`/`client.lua` respectively in the manifest; the shop
files do not add a generic client-to-server shop event.

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
