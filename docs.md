# kora_inventory

`kora_inventory` is the server-authoritative inventory provider. It provides the
`qb-inventory`, `ox_inventory`, and retired `qb-weapons` compatibility
identities. Same-named qb and ox exports retain their upstream-specific
signatures through separate identity routing. A real qb-inventory, ox_inventory
or qb-weapons resource must not run alongside kora_inventory.

## Ownership and startup

Player inventory ownership never moves: kora_core owns the slot-keyed
`PlayerData.items` object and the `players.inventory` database column.
kora_inventory makes player mutations only through kora_core's `setPath` funnel, so
replication and persistence remain single-writer. kora_inventory owns secondary
inventory state (stashes, temporary stashes, drops, and shops), sessions,
revisions, locks, hook registration, and audit events.

Shared item definitions remain in kora_core's runtime `items` registry and are
looked up when each inventory operation runs; kora_inventory never caches the
legacy `QBCore.Shared.Items` map. Runtime weapon and ammunition additions are
observed through registry subscriptions and receive their built-in use handler
without a resource restart.

`RegisterStash(..., owner = true, ...)` is a private-stash template. It does
not create a shared stash with a boolean owner flag: on open, kora_inventory
derives the caller's citizen id server-side and uses a separate durable
`stash:<template>:<citizenid>` record. A caller cannot choose another owner's
identifier through the client transport.

Registered stash `coords` and shop `data.coords` accept either one `{x,y,z}`
point or a list of allowed points. The same any-point distance rule runs when a
session opens and before every mutation. Re-registering an existing id updates
that live boundary while retaining its durable contents.
Trusted registrations may put a `distance` override on a list entry when
different fixtures sharing one inventory need different interaction radii.

## Crafting and weapons (server-only foundation)

`server/crafting.lua` is a headless, server-only foundation. It deliberately
registers no network event or NUI callback. A gameplay resource must complete
its own server-resolved station, job, proximity, routing-bucket and progression
checks, then call `CraftItem(source, recipeId, trustedContext, amount)`. Do not forward
a client recipe, output, item metadata, count or `trustedContext` to this API.

Register a static recipe from its owning server resource:

```lua
exports.kora_inventory:RegisterCraftRecipe('repair_board', {
  ingredients = { { name = 'wood', amount = 2, metadata = { grade = 'oak' } } },
  outputs = {
    { name = 'board', amount = 1, metadata = { quality = 100 } },
    { name = 'sawdust', amount = 2 },
  },
  access = function(source, recipe, context)
    -- `context` is server-owned station state, never a raw client payload.
    return true
  end,
})
```

The legacy singular `output = { ... }` form remains supported. Use
`CanCraftRecipe(source, recipeId, amount?)` for a read-only feasibility check;
it plans
ingredient removal, all outputs, slots, and weight without running access
callbacks/hooks or changing the inventory.

`CraftItem(source, recipeId, trustedContext, amount?)` accepts a positive batch
amount up to `Config.qbinventory.crafting.maxBatchAmount` (100 by default).
Every ingredient and output is scaled, planned, and committed in the same
locked transaction; the default amount remains one.

Crafting locks the qbcore-owned player inventory, makes a detached plan,
validates all recipe ingredients/weight/slots, then commits through
`qbcore:setPath` via kora_inventory's authority seam. A failed recipe changes no
slots. Hooks can approve/reject a craft but cannot mutate its planned state.

Weapon helpers are also server-only: `PrepareWeaponMetadata`, `GetWeaponState`,
`SetWeaponState`, `ConsumeWeaponDurability`, `SetWeaponAmmo`,
`SetWeaponComponents`, `LoadWeaponRounds`, and `FireWeaponRound`. New weapon
metadata receives a server serial, bounded durability and ammo, and only configured components in
`Config.qbinventory.weapons.components` are accepted. Gameplay weapon-use code
must invoke durability/ammo changes from validated server actions; do not add a
generic client event for these exports.

New weapon serials are `<prefix>-<WEAPON>-<time>-<n>` from one generator
(`weapons.generateSerial`). The prefix is `Config.SerialPrefix` (default `KORA`,
A-Z0-9, max 12; the legacy `Config.qbinventory.weapons.serialPrefix` is still
honoured when set to something other than `QB`). Existing serials are never
rewritten. Stored durability is rounded to 2 decimals, and the item inspector
rounds fractional values to `Config.Inspector.decimals` (default 1).

`Config.ShopHints` draws a small marker and a `[ALT] Shop` hint (locale key
`shop_hints.text`) at every fixed shop point within `drawDistance`, coloured
from kora_theme's primary colour. Set `hint = false` on a shop to opt it out;
vending machines (model targets) have no fixed point and get none.

When `Config.qbinventory.weapons.ballistics.enabled` is set (the default), a
weapon's `info.loadedBullets` contains one generated record for every loaded
round; a 12-round magazine therefore contributes exactly 12 entries. The
client only reports that its native ped fired. The server resolves the equipped
slot, consumes one entry with `FireWeaponRound`, and emits a server-only fired
round event for an evidence resource. Cartridge IDs are not firearm serials:
the serial-to-casing link belongs in protected police storage and is revealed
only after the investigation flow completes.

`Config.qbinventory.weapons.durability` controls normal firing wear. With the
default `perShot = 0.10`, every ten accepted rounds remove one durability
point. Set a per-weapon value in `multipliers` (for example, `1.25` for a
rifle that wears 25% faster), add non-wearing weapons to `excluded`, or set
`enabled = false` to turn firing wear off. The server derives the number of
rounds from its own lower-only ammo record, so a client cannot lower wear by
claiming it fired fewer shots or repair a weapon by claiming extra ammo.

This foundation does not yet supply a crafting UI or station discovery.

### Visible weapon carry and draw pacing

`Config.qbinventory.weaponCarry` turns weapons a player owns but is not
holding into props on their body, and turns equipping one from an instant
snap into a timed, animated draw. Set `enabled = false` to switch the whole
feature off; nothing else about the inventory changes.

`visibility` picks what other players can see:

- `'all'` -- every carryable weapon anywhere in the inventory is rendered.
- `'hotbar'` (default) -- only weapons in slots `1..Config.qbinventory.hotbarSlots`
  are rendered. A weapon stowed past that range is genuinely concealed.

`hotbarSlots` is a single top-level value precisely because two features ask
the same question: `client/hotbar.lua` binds the number keys to exactly that
range, and this is the range that counts as "openly carried". Two constants
would silently disagree about which slots a player can actually see.

Drawing costs `drawTime`; holstering costs `holsterTime`. The animation is
chosen **per weapon class** from `drawAnims`/`holsterAnims`, keyed by the same
`tiers` entry that decides where the weapon is worn -- so where a weapon sits
and how it is produced are one decision rather than two that can disagree. A
rifle coming off the back and a pistol off the hip are different movements, and
playing the hip draw for both was the clearest sign the animation was
decorative. A class with no entry falls back to `drawAnim`/`holsterAnim`; an
entry set to `false` skips the animation for that class while keeping its
timing. The tier is resolved on the server and sent with the toggle, so the
client does not look a weapon's class up just to pick an animation.

Drawing a weapon that was *not* openly carried costs
`concealedDrawTime` on top -- pulling something nobody saw coming takes longer
than unslinging what was already on your back. That surcharge only applies
while `visibility = 'hotbar'`: in `'all'` mode (or with the feature disabled)
a weapon's slot says nothing about whether it was visible, so there is no
concealment to price. Set the durations to `0` for the previous instant
toggle. The bar deliberately cannot be cancelled -- a cancellable draw is a
free way to skip the surcharge by tapping the item repeatedly.

A weapon is classified by its kora_core `weapontype` through `tiers`
(`back` / `sling` / `hip`), and each tier lists ordered attachment positions
in `attachments`. A weapon that finds no free position in its tier is simply
not rendered rather than stacked on top of one that is. `weapons` holds
per-item overrides: `tier = false` excludes an item entirely, `bone`/`pos`/
`rot` re-place one item, and `model` renders a plain prop instead of the
weapon -- which is also how a non-weapon item can be carried, since only
registry weapons are classified automatically. `components` maps a weapon
component *item name* to the GTA component it renders as; it is empty by
default because kora_core's shared registry carries no component-to-native
mapping and guessing one would attach the wrong part.

The carried list is built on the server from qbcore-owned `PlayerData` and
published on the replicated player state bag `qbinventory:weaponCarry`
(cleared with an explicit `false`, never a nil deletion -- a nil write is a
key deletion and does not replicate like a value change). Clients only
*render* that bag. A client never submits, extends or edits its own carried
list, so this can never become a channel for advertising items a player does
not own or hiding ones they do.

The one thing a client may say is "the draw you asked me for finished"
(`qbinventory:server:weaponToggled`), and that is matched against a pending
request this server issued and re-resolved against the real slot before it is
believed -- a client cannot confirm a weapon it does not have, in a slot it
was not asked about. `qbinventory:server:weaponUnequipped` carries no payload
at all and can only ever put a weapon *back* on its own player's body (weapon
wheel, disarm, death), never take one off. Read-only server exports:

```lua
exports.kora_inventory:GetCarriedWeapons(src)  -- the rendered list
exports.kora_inventory:GetEquippedWeapon(src)  -- { slot, name } or nil
```

There is deliberately no setter. A resource that wants a different carried
list changes the player's items, not the render. Equipping still does not
remove the weapon item from its slot (see `server/useables.lua`).

### Retired `qb-weapons` compatibility

`kora_inventory` provides `qb-weapons`, so a resource that only lists it as a
dependency continues to start without a second weapon controller. It accepts
the legacy draw, holster, ammo, durability and read-only ammo callback names
and routes them to the current inventory lifecycle. Legacy client item tables
are reduced to a slot and the real item is read from the player's inventory;
reported ammo can only decrease, and reported quality can only consume
durability. `quality` is retained as a mirror of canonical `durability` for
old weapon metadata and existing database rows.

The legacy client `getConfigWeaponAttachments` export remains available too.
It is derived only from the explicit kora_inventory component allow-lists, so
attachment UIs can read it without gaining a metadata or component mutation
path.

The retired repair-station and attachment-item systems are not recreated:
they depended on `qb-weapons`' resource-local configuration and accepted
client-selected station/item data. The old repair and attachment callbacks are
registered and safely refuse rather than hanging a stale caller. A replacement
gameplay resource must validate its station/role/cost server-side and then use
`SetWeaponState`, `ConsumeWeaponDurability`, `SetWeaponAmmo`, or
`SetWeaponComponents`.

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
open request may contain only a network id; kora_inventory never accepts a
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

### Opening vehicle storage with the inventory key

`client/vehicles.lua` turns the inventory key (TAB) into the network-id intent
above; `client/compat.lua` tries it before the player's own inventory.

- Seated in a vehicle: opens the glovebox next to the player inventory.
- On foot within `bootReach` of a vehicle's boot: opens the trunk. The boot is
  the rear bumper, or the front for the rear/mid-engine models in
  `vehicles.frontBootModels` (adder, zentorno, ...). Classes in
  `vehicles.bootSkipClasses` (motorcycles, cycles, trains) are ignored.
- A locked vehicle (kora_vehiclekeys `qbvehiclekeys:locked` state, else the
  native door lock) refuses the trunk with a "locked" notice; the server
  enforces this too unless `vehicles.respectLocks = false`.

Options (all under `Config.qbinventory.vehicles`): `enabled`, `gloveboxEnabled`,
`trunkEnabled`, `bootReach`, `trunkDistance`, `respectLocks`, `frontBootModels`,
`bootSkipClasses`. Set `enabled = false` if another resource drives vehicle
storage; `exports.kora_inventory:openInventory('trunk', netId)` still works.

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
identifier server-side, and writes `info.containerId` through kora_core's mutation
funnel. `openItem(source, slot)` then reads that same current server slot. It
does not accept a browser/client item table, owner, or container identifier.

`Config.qbinventory.containers.items` promotes named unique items into
first-class portable containers. The shipped `backpack` definition is a 20-slot,
60 kg container: using it from the player's own inventory binds a generated ID
on first use and opens it thereafter. Its access policy proves current
possession of that exact bound item on every open/transfer validation, so giving
the backpack transfers access without exposing a container ID to the client.
Portable containers cannot be stored in another container by default (and can
never be stored inside themselves); set `allowNested = true` only with an
explicit server policy for recursive capacity.

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
kora_core's canonical player store.

The kora_sql migration creates `qbinventory_inventories` (items, properties and
revision), `qbinventory_shop_stock`, audit, migration-state/row and quarantine
tables. Legacy rows are copied, never deleted or updated. An already imported
row with the same checksum is skipped; a changed legacy row is reported rather
than overwriting a possibly-live kora_inventory record. Malformed JSON/item slots
are retained in `qbinventory_quarantine` for operator review.

Run these from the server console (or grant `command.qbinventory`):

- `qbinventory-migrate dry-run` — inspect import eligibility without writing.
- `qbinventory-migrate run` — idempotently import eligible legacy data.
- `qbinventory-migrate verify` — validate stored item JSON and print migration state.
- `qbinventory-migrate retry` — revisit only previously failed/quarantined rows.

The importer inspects, when present, `inventories`, `stashitems`, `trunkitems`,
and `gloveboxitems`. It accepts common identifier/slot/weight column spellings
and preserves original item metadata.

Start it after `kora_core`. The bundled `web/` NUI starts with kora_inventory, while
the server API and client session transport remain usable by another renderer.

## Server API

The lower-camel exports are the kora_core gateway surface:

- `getWeight`, `canCarry`, `addItem`, `removeItem`, `getItemByName`,
  `getItemsByName`, `getItemBySlot`, `getItemCount`, `hasItem`, `getFreeSlot`,
  `moveItem`, `clearInventory`, `setItems`, `createUseable`, `useItem`
- `stashGet`, `stashSet`, `stashOpen`, `shopGet`, `shopSet`, `dropCreate`, `dropTake`

`shopGet(id)` / `shopSet(id, items)` (aliased `GetShopItems` / `SetShopItems`)
are the only way to change a shop's stock or prices after registration:
`RegisterShop` seeds stock only for a shop that was not restored from durable
storage, and the generic transfer path refuses shop inventories outright
("shop items must be purchased"). They go through the same locked write funnel
as `stashSet`, so revision, viewers and persistence stay consistent, and each
slot keeps its own `price` field. Unlike the stash pair they reject an unknown
id instead of lazily creating one -- a shop is a deliberate registration with
prices and an access policy.

qb-style aliases are also exported (`AddItem`, `RemoveItem`, `OpenInventory`,
`GetStashItems`, `RegisterStash`, and so on), alongside ox-style constructors
`RegisterStash`, `CreateTemporaryStash`, `RegisterShop`, `BuyItem`,
`RegisterHook`, and `RemoveHooks`.

Every public name is reachable in **both cases** (`registerStash` and
`RegisterStash`). Half this surface once carried a lowercase alias and half did
not, so a caller had to know which half a name fell in;
`test/smoke/export_collisions.lua` now asserts the pairing and that both cases
resolve to the same function.

### Provider identities

`qb-inventory` and `ox_inventory` are **enabled**. Each compat module builds a
table which `server/compat/providers.lua` publishes as
`__cfx_export_<identity>_<name>` handlers -- a namespace separate from
kora_inventory's own flat export table, which is what lets same-named qb and ox
exports keep their different upstream return shapes.
`test/smoke/provider_contract.lua` loads both realms the way FXServer does and
asserts every name in `test/contracts/upstream.lua` is actually callable on the
right identity **in the right realm**.

A compat module must never call `exports()`. Doing so writes into kora_inventory's
own flat table and silently replaces a native export for every other resource --
`client/compat/ox.lua` did exactly that to `openInventory`/`closeInventory`, and
because its wrappers then re-entered the export, every stash and shop open
recursed until the client hung. `test/smoke/export_collisions.lua` covers both
realms against that.

### Reading kora_core's shared item registry

`exports.kora_core:getShared(name, key)` requires **both** arguments -- it returns
`registries[name].materialised[key]`. Calling it with only a registry name
returns `nil` unconditionally, silently. The registry is named `items`,
lower-case (`kora_core/modules/registry/server.lua:12`), and there is no public
accessor for the whole name-keyed map: `allShared('items')` returns a dense
ARRAY of records, so a map has to be rebuilt from it.

Both ox compat realms previously called `getShared('Items')` -- wrong registry
name *and* no key -- so every item lookup resolved to nil. Anything gated on
such a lookup reports "no such item" for every item in the game.

### Client compat surfaces

- `client/compat.lua` -- the qb-inventory client bridge (net events, commands,
  `inv_busy`). Registers no exports.
- `client/compat/ox.lua` -- the whole `ox_inventory` client identity, including
  its own `openInventory`/`closeInventory` wrappers (which carry the
  `setStashTarget` substitution). Its UI adapters translate ox notification
  positions onto kora_lib's six placements, preserve multi-select input rows, and
  map progress scenarios and props onto kora_lib's supported shapes.
- `client.lua` -- kora_inventory's native client exports, and the `qb-inventory`
  identity only.

**One module owns one identity.** Registering the same name on the same identity
from two files "works" only because the later `AddEventHandler` wins, so
behaviour would change silently if `client_scripts` were reordered.

### Deliberate divergences from upstream

These are intentional and tested; they are the points where upstream's contract
conflicts with this resource's authority model.

| Area | Upstream | Here | Why |
|---|---|---|---|
| Full-inventory replacement | `SetInventoryData` trusts the client's inventory ids | translated onto the validated transfer funnel; can only name the two inventories the caller's own session already holds | a client must never assert what it may touch |
| `Inventories` / `Drops` / `RegisteredShops` | mutable globals other resources write to | not exposed | a mutable global bypasses the lock/bump/broadcast write funnel |
| `qb-inventory:server:updateDrop` | writes drop coords from the client | inert no-op | position gates every distance check |
| `qb-inventory:server:snowball` | grants a weapon on a client event | inert no-op | server code can call `AddItem` directly |
| `SaveInventory(source, offline)` | writes player items | flushes secondary inventories only | kora_core owns player persistence |
| ox `GetInventory` / `Inventory` | a live `OxInventory` instance with methods | a detached snapshot | a live object is a mutation path around the write funnel |
| ox `SetSlotCount` / `SetMaxWeight` | resizes any inventory | refuses player inventories | kora_core owns player dimensions |
| ox `SetMetadata` | accepts `metadata.weight` | rejects it | a caller-supplied weight invalidates capacity checks |
| ox `addCash` / `removeCash` / `getBank` / `getCards` / `giveCard` | operate on `money` / `mastercard` items | routed to kora_core accounts | kora_core owns balances |

## Ammunition

Using an ammo item loads the weapon the player currently has **drawn**.

Which weapon that is, and how many rounds it gets, are both resolved on the
server: the weapon comes from `server/weaponcarry.lua`'s own record of the draw
it asked for (only ever set after the client confirmed a draw the server
initiated, and re-validated against qbcore-owned `PlayerData` at that point),
and the round count comes from the shared item definition's `rounds`. The
client's use request contributes a slot and nothing else -- no weapon name,
hash, ammo type or count crosses the wire inbound.

The magazine's `ammoType` must match the drawn weapon's `ammotype`; a mismatch
refuses the use and consumes nothing. `server/useables.lua` registers a useable
for every registry item that has both `ammoType` and a positive `rounds`, so a
server adding its own magazine gets a working use with no code change. The new
amount is saved on the weapon before the client is instructed to display it;
shot reports may only lower that saved amount, and drawing restores the saved
amount to the GTA weapon.

A weapon must be **drawn**, not merely owned. This keeps magazine use honest:
the server knows exactly which weapon it is loading and the GTA ped has that
weapon ready to receive the synchronised amount. Loading a holstered weapon is
refused and consumes nothing.

## UI presentation config

`Config.qbinventory.ui` is the only config that crosses into the browser,
pushed on `qbinventory:nui:config` at resource start and on every session open.
Nothing in it is authority and the inventory engine never reads it.

| Key | Effect |
| --- | --- |
| `centreWhenSolo` | With no second inventory open, show only a compact centred player grid; selecting an item slides its inspector and actions out in a drawer. |
| `showHotbar` | Outline slots `1..hotbarSlots` on the player's own inventory in the accent colour, so the keys `client/hotbar.lua` already binds are visible rather than folklore. |
| `rightClickSplit` | Right-click on a stack of 2+ opens the split dialog (default `true`); `false` makes right-click do nothing. |
| `optimisticMoves` | Draw a drag-and-drop move (move, stack, swap, split) immediately and undo it if the server refuses or does not answer within `moveTimeout` (default `true`); `false` shows a move only after the server confirms it. The server validates every move either way. |
| `queueMoves` | With `optimisticMoves`, keep the inventory draggable while a move waits for the server: further drags are queued (up to 8) and sent in order; a refused or unanswered move undoes itself, the server is asked to re-send the real state, and the drags queued behind it still go out (default `true`). `false` blocks dragging until the server answers. The busy (wait) cursor is never shown either way. |
| `moveTimeout` | Seconds (2-60, default `10`) the UI waits for the server to answer a move before undoing it. |
| `images` | Item artwork resolution -- see below. |

`hotbarSlots` is sent alongside it because the NUI draws the boundary and cannot
know where it is otherwise. It stays a read of the same single value
`client/hotbar.lua` binds its keys from, so the outline and the keys cannot
disagree.

### Item artwork

Artwork is resolved as an ordered list of candidates, walked on `onError`:

1. the item's own `imageUrl`, if it is `https://` and `allowRemote` is not false
2. `<localPath>/<item.image>`, when the legacy `image` field carries an extension
3. `<localPath>/<item.name>.<ext>` for each configured extension, in order
4. the first letter of the label

Ordered rather than probed: there is no way to ask whether a `nui://` file
exists without requesting it, and an `<img onError>` chain gets that for free
with no HEAD requests and no manifest to keep in sync. Set `preferLocal = true`
to move the remote URL to the end of that list, or `allowRemote = false` to drop
it entirely.

Local files live in `kora_inventory/images/` (see its README) and are served as
`nui://kora_inventory/images/<file>`. That is outside `web/` on purpose: `web/build`
is Vite's output directory, and artwork a server owner added must not be
something `pnpm build` can delete.

**Animated WebP and GIF need no special handling** -- CEF animates both in a
plain `<img>`, so the work is allowing the extension, not a second code path.

The scheme check is an **allowlist**, not decoration. Item definitions come from
shared registries any resource can extend, so `imageUrl` is untrusted text on
its way into an `src`; only `https://` is accepted, and a local name must be a
plain identifier or it is rejected outright rather than escaped.

## Ground drops

Dropping an item creates a temporary `drop` inventory at the player's position
and leaves a bag prop on the floor (`Config.qbinventory.drops`).

The prop is **presentation only**. It is a local, non-networked object created
independently on each client; it carries no inventory identity, and interacting
with it calls the ordinary open path with the drop id the server broadcast. The
server then re-resolves that drop and repeats its access, distance and
routing-bucket checks like any other inventory -- so deleting the prop, moving
it, or fabricating one client-side gains nothing.

Player-created drops belong to the player's server-resolved routing bucket.
Opening, transferring and receiving item updates recheck that bucket.
`qbinventory:server:drops` and the legacy drop list return matching drop ids and
coordinates; **contents are never included**. Live creation reaches matching
players. After a bucket change, the existing five-second session cleanup tick
closes old drop sessions and refreshes the local bags and interaction targets.

Trusted server calls to `dropCreate(coords, items)` retain their global scope.
Its optional third `bucket` argument restricts a drop; ox-compatible
`CustomDrop` uses its existing `instance` argument for that restriction, and
`CreateDropFromPlayer` resolves the source player's bucket. Setting the existing
`requireSameBucket` option to false preserves cross-bucket behavior.

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

### Using items

An item definition (kora_core's shared `items` registry) may set two qbinventory-
native fields on top of the usual `useable`/`weight`/`unique`/etc, both derived
and validated by `buildItem` exactly like those:

- `preventClose` (boolean) -- default `false`. A completed use normally closes
  the panel client-side afterwards (mirroring real qb-inventory's
  `shouldClose`); `preventClose = true` keeps it open. A legacy item that sets
  `shouldClose = false` (kept as pure qb-core compat metadata, see below) is
  honoured as an implicit `preventClose = true` even without the native field.
- `useTime` (integer ms) -- default `0` (today's immediate-use behaviour).
  When set, the client runs kora_lib's progress bar
  (`Kora.progressbar.start`, see `kora_lib/modules/progressbar`) for `useTime` ms
  *before* it ever contacts the server. If the bar is cancelled or never
  starts, the client never sends the use request at all -- there is no
  server-side "was it shown" flag to trust, so not asking is what keeps a
  cancelled bar from ever applying its effect.

Both fields are canonical and, like `weight`/`useable`/`shouldClose`, cannot be
forged onto a stored item through `setItems`/`SetInventory`'s per-field
passthrough.

`intentUse` (the server half of the NUI `use` action) reports
`{ preventClose }` back to the caller on success, and `client.lua`'s
`submitIntent` calls `closeInventory()` unless that came back `true`. The same
gate (`QbInventory.useGate`, defined in `client.lua`) runs before both this NUI
path and the hotbar keybinds below, so there is exactly one place that decides
whether a use is allowed to proceed.

Pressing `1`-`5` uses whatever item currently occupies inventory slots
`1..Config.qbinventory.hotbarSlots`, even with the panel closed -- kora_inventory
has no separate hotbar/quickslot data model (see the
`qb-inventory:client:hotbar` no-op just below), so the first N general
inventory slots double as the hotbar, matching real qb-inventory/ox_inventory.
That same range is what `weaponCarry`'s `'hotbar'` visibility treats as openly
carried, which is why it is one config value rather than a constant in each. `client/hotbar.lua` registers these through
`Kora.keybind`, does nothing while `IsNuiFocused()`/`IsPauseMenuActive()` (so it
never fights the panel's own Use action), and reuses the existing legacy
`QBCore:Server:UseItem` transport -- which already re-resolves the slot from
qbcore-owned `PlayerData` and never trusts the transmitted item record --
instead of adding a second server-side use path.

Double-clicking a slot in the bundled web UI (`web/src/App.tsx`) triggers the
same `activateItem` used by the detail panel's Use/Buy button and the
Enter-key shortcut on a selected item; there is only one place that decides
what "activate this item" means.

### qb-inventory client bridge

`client/compat.lua` keeps the conventional client-facing qb-inventory surface
safe during migration. It listens for `qb-inventory:client:openInventory`,
`closeInv`, and `updateInventory` (plus the narrowly equivalent old
`inventory:client:*` aliases), the `inventory`, `openInv`, and `closeInv`
commands, and the default `openInv`/`TAB` mapping through `Kora.keybind`.

Legacy item tables, slot counts, labels, weights and metadata are never read.
An open event contributes only a validated identifier request; kora_inventory's
server then resolves the inventory, checks access/distance/bucket rules and
returns its own session snapshot. `updateInventory` re-opens the current
server-issued target to obtain a fresh authoritative snapshot. No vehicle or
entity discovery happens client-side.

`LocalPlayer.state.inv_busy` is set only while a kora_inventory UI session is
open, and released on the matching session-close event or resource stop. NUI
focus remains exclusively owned by `client/ui.lua`.

## Security guardrails

There is deliberately no client event, callback, or NUI endpoint that accepts
a complete inventory table for replacement. Browser and client payloads are
limited to an action intent plus slots and amounts; kora_inventory resolves item
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
`{ name, amount, price }` data: kora_inventory must build each canonical item view
from kora_core's registry, rather than accepting labels, local `image` filenames,
remote `imageUrl` fields, weights or other
item fields from configuration or a client.

`client/shops/ammunation.lua` creates kora_lib interaction zones and map blips as
presentation only. Selecting a zone sends the fixed shop identifier through
the normal inventory open request; it does not send a location, price, stock
row or item data. `server/shops/ammunation.lua` registers the shop with an
access callback that independently reads the player's server ped coordinates
and routing bucket, and permits the open only inside a configured counter. A
forged shop-ID request away from a counter or in another bucket is denied.
The blip uses the canonical `Weapons` category and the separate storefront
name `Ammu-Nation`, letting kora_lib render `Weapons: Ammu-Nation` while grouping
it with other weapon shops.

The bundled liquor shop follows the same contract. Each location declares its
own storefront name (`Rob's Liquor`) while all of them use the
canonical `Liquor` category and the same server-validated shop stock.

The bundled convenience store (`Config.qbinventory.shops.convenience`, all 24/7
counters) is a separate shop with the same contract. Its "Open shop" target sits
on the counter, next to kora_robberies registers. Set `enabled = false` to drop
the shop, its targets and blips (default `true`). `blip.category` (default
`Convenience`) must be a `Kora.blips` category (`Kora.blips.getCategories()`);
the same applies to the Ammu-Nation and liquor `blip.category`. An unknown value
logs one warning naming the option and the blip is created without a category.

The initial catalog includes standard kora_core weapons and the registered
`pistol_ammo`, `smg_ammo`, `shotgun_ammo`, `rifle_ammo`, `mg_ammo`, and
`snp_ammo` packs. Load the three Ammu-Nation files after
`config.lua`/`server.lua`/`client.lua` respectively in the manifest; the shop
files do not add a generic client-to-server shop event.

### Bundled vending machines

Unlike Ammu-Nation, `config/shops/vendingmachine.lua` has no curated location
list -- a vending machine is any `models` prop
(`prop_vend_soda_01`/`prop_vend_soda_02`/`prop_vend_water_01`/
`prop_vend_coffe_01`, matching real qb-inventory's default set) a mapper
placed anywhere, and FXServer has no way to independently query a static map
prop's position the way it can a player ped. `client/shops/vendingmachine.lua`
targets those models globally through `exports.kora_target:addModel` (a
persistent, streaming-aware registration -- kora_inventory now `dependency`s
`kora_target` for this), not kora_lib's own `Kora.interact.addTargetModel`, which is
documented as a one-shot snapshot of whatever is streamed in at call time and
would miss every machine outside the player's initial render distance.
Selecting a machine sends its live entity coordinates alongside the fixed
`vendingmachine` shop id.

`server/shops/vendingmachine.lua`'s access callback bounds-checks those
reported coordinates against the source's own live server position (the same
trust boundary real qb-inventory's `OpenShop` accepts -- see its
`server/main.lua`) rather than inventing a stronger guarantee the platform
can't back up. A verified open is cached per-source for
`Config.qbinventory.sessionTtl` so kora_inventory's own in-session revalidation
(`validSession`, which re-runs `access` on every transfer but has no fresh
client data to offer) doesn't kick a player out mid-purchase; a bare open
with no coordinates at all, or coordinates that don't place the source near a
real approval, is always rejected outright and never seeds that cache. This
is a generic capability, not vending-specific: `canAccess`/`open` thread the
raw client open request through as a third `opts` argument to any shop's
`access(source, inventory, opts)` callback, so any future shop with the same
"no fixed location list" shape can reuse the pattern.

Stock reuses this project's own item catalog (`water_bottle`, `soda`) rather
than porting upstream's `kurkakola` name verbatim -- the registry already
departs from upstream naming elsewhere (e.g. `water_bottle` is labelled
"Water", not upstream's "Bottle of Water").

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


## Durable player exchanges

`ExecutePlayerExchange(source, operationKey, request)` is a native server-only export for trusted gameplay domains listed in `Config.qbinventory.exchangeCallers` (default: `kora_drugs`). The calling resource owns its key namespace. The request requires `citizenid` and accepts `take = {{ name, amount }}`, `give = {{ name, amount, info = {} }}`, nonnegative whole `cash`, signed whole `dealerRep`, and `reason`. Inputs are objects with named fields; omitted lists and amounts default empty/zero. Weapon outputs and direct physical-currency item legs are rejected; use `cash` for physical cash. Reputation updates `metadata.rep.dealer`, with negative results clamped to zero. The gameplay caller must authorize the interaction and choose all terms on the server; no client event exposes this API.

The export plans against the current inventory, validates capacity, and uses kora_core's durable inventory/money/metadata fences. One SQL transaction writes the player values and a permanent, resource-scoped receipt. It returns the receipt on success or `(nil, code, message)` on failure. Reusing a key with identical canonical terms and recipient returns the original receipt; changing terms or recipient returns `conflict`. `GetPlayerExchange(operationKey)` retrieves and reconciles the calling resource's receipt, returning `not_found` only after the previous worker has settled and a locking read confirms no receipt. Unknown outcomes remain fenced; callers must retry the same key, not create a new reward key. Native recovery also reconciles pending operations after provider/core restarts, including offline recipients.

Cash rewards honor the configured item-backed cash authority and retain a zero ledger mirror. Nonzero cash transaction tax is currently rejected explicitly because the configurable tax collector has no durable collector transaction contract; equivalent dealer profiles require tax disabled for those rewards. Marked-bill output metadata is preserved, but the item must exist in the authoritative item registry. The receipt includes provider, operation key, citizen ID, cash, reputation delta, canonical request fingerprint and completion time.

Validation: `lua test/smoke/player_exchange.lua` exercises the actual kora_core fences and inventory planners with a controlled SQL transport, including repeated/changed requests, cash items, marked bills, capacity, source reuse, unknown commits, delayed workers, offline restart recovery and ordinary writes blocked by all three fences.

Run `python3 test/exchange_database.py` for the optional database check. It starts a disposable socket-only MariaDB instance, captures the actual exchange planner SQL, and executes it with kora_sql's checked transaction runner. It verifies receipt/player atomicity, duplicate rejection after restart, precondition rollback, missing commit acknowledgements, and recovery reads waiting for older transactions. It does not exercise a connected FiveM player.

## ox_inventory item data and hooks

- `exports.ox_inventory:Items()` / `Items(name)` / `ItemList` (server and
  client) return **ox-format** definitions (`name, label, weight, stack, close,
  description, consume, client = {image, ...}, server = {...}`) translated from
  kora_core's registry by `QbInventory.toOxItemDef`. Kora's own fields stay on
  the table as extra keys; the registry itself is never modified. The returned
  tables are copies.
- Hooks (`registerHook`) follow ox_inventory's hook module: string ids
  (`resource:event:n`), `payload.source`, ox slot tables and ids, `swapItems`
  actions `move`/`swap`/`stack`/`give` (gives and ground drops included),
  full `buyItem`/`craftItem`/`createItem`/`openShop`/`usingItem` payloads,
  pattern-array `inventoryFilter`, `print`, post-events and owner-scoped
  `removeHooks`. `createItem` ignores `false` (only a returned table replaces
  the metadata). Crafted outputs do not fire `createItem`. See
  `docs/index.md` ("Hooks and inspection access") for the payload table.
- Kora-only export (not an ox API): `exports.kora_inventory:ImportOxItems(defs,
  { overwrite = false })` registers ox `data/items.lua` entries (name-keyed map
  or array) into kora_core's item registry. Existing items are skipped unless
  `overwrite`. `stack = false` -> `unique`, `close` -> `shouldClose`,
  `client.image` -> `image`; ox `client`/`server`/`consume`/`degrade`/`decay`
  are preserved on the record. Returns `registered, errors`.

## Parachute

`server/useables.lua` registers a built-in use handler for the `parachute`
item. Using it shows a cancellable kora_lib progress bar with a pack-up
animation, gives the player `GADGET_PARACHUTE`, puts the parachute pack on
their back and consumes one item. The server waits for the client (so the slot
stays locked for the whole bar) and only consumes the item once the parachute
was actually equipped; a cancelled bar, or a player who already has one
equipped, keeps the item.

`Config.qbinventory.builtinUsables`:

- `parachute` (default `true`) - set `false` to leave the item to another
  resource.
- `parachuteTime` (default `2500`) - progress bar length in ms; `0` skips it.
- `parachuteTint` (default `nil`) - optional `SetPedParachuteTintIndex` value.
- `parachuteBag` - `{ enabled = true, male = { drawable = 8, texture = 0 },
  female = { drawable = 8, texture = 0 } }`. Sets the bag component (5) so the
  pack is visible; freemode peds only. The previous bag is restored when the
  parachute is deployed or gone, unless the player changed their bag meanwhile.
  `enabled = false` leaves clothing alone.
