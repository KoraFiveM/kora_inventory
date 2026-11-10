---
layout: default
title: kora_inventory
---

Server-authoritative inventory provider for FiveM, with a bundled NUI. It
ships **both** `qb-inventory` and `ox_inventory` compatibility identities
(`provide 'qb-inventory'` / `provide 'ox_inventory'`), pinned to the contract
fixtures in `test/contracts/`, so same-named qb and ox exports keep their own
upstream-specific signatures through separate identity routing. A real
`qb-inventory` or `ox_inventory` resource must not run alongside it.

Ownership never moves: [kora_core](https://qbcore2.github.io/kora_core/) owns the
slot-keyed `PlayerData.items` object and the `players.inventory` database
column, and kora_inventory only mutates player items through kora_core's `setPath`
funnel. kora_inventory owns everything else — stashes, temporary stashes, drops,
shops, item containers, evidence/confiscation, trunks/gloveboxes, crafting,
weapon metadata, sessions, revisions, locks, hooks, and audit events — headless
by default, with its own optional NUI as one renderer among possible others.

## Requirements

- [kora_lib](https://qbcore2.github.io/kora_lib/)
- [kora_sql](https://qbcore2.github.io/kora_sql/)
- [kora_core](https://qbcore2.github.io/kora_core/)

## Installation

`server.cfg`, after kora_core:
```
set mysql_connection_string "mysql://user:pass@localhost/kora_core?charset=utf8mb4"
ensure kora_sql
ensure kora_lib
ensure kora_core
ensure kora_inventory
```
kora_inventory creates its own secondary-inventory tables
(`kora_inventory_inventories`, `kora_inventory_shop_stock`, migration-state/audit tables)
at startup from `server/schema.lua` — no manual schema import needed.

If you're migrating off a real `qb-inventory`/`ox_inventory`, run one of these
from the server console (or grant `command.kora_inventory`) once kora_inventory has
booted:
```
kora_inventory-migrate dry-run   -- inspect import eligibility without writing
kora_inventory-migrate run       -- idempotently import eligible legacy data
kora_inventory-migrate verify    -- validate stored item JSON, print migration state
kora_inventory-migrate retry     -- revisit only previously failed/quarantined rows
```
Legacy rows are copied, never deleted or updated, and malformed rows land in
`kora_inventory_quarantine` for review.

## Usage examples

### Give and remove items
```lua
-- server
exports.kora_inventory:addItem(source, 'water_bottle', 2)
exports.kora_inventory:removeItem(source, 'water_bottle', 1)
```

### Check weight/capacity before granting a reward
```lua
-- server
local weight, maxWeight = exports.kora_inventory:getWeight(source)
local canCarry = exports.kora_inventory:canCarry(source, 'gold_bar', 1)
if canCarry then
    exports.kora_inventory:addItem(source, 'gold_bar', 1, nil, nil, 'mission-reward')
else
    print(('player %d is too full: %d/%d'):format(source, weight, maxWeight))
end
```

### Register and open a private (per-citizen) stash
```lua
-- server, e.g. in a house/garage resource
exports.kora_inventory:RegisterStash('house_stash', 'House Storage', 50, 100000, true)

-- client, when the player interacts with the stash prop
exports.kora_inventory:openInventory('stash', 'house_stash')
```
`owner = true` derives a durable `stash:house_stash:<citizenid>` record from
the caller's own session server-side — a client can never open another
player's copy of the template by supplying a different identifier.

### Resource-owned property storage

`RegisterStashPolicy(id, options, callback)` returns `true, inventoryKey` or
`false, error`. Options use `label`, `slots`, `maxWeight`, `owner`, `groups`,
`coords`, and `distance`. The callback receives `(source, inventory, options)`
and must return `true`. The invoking resource owns the policy. Registration
persists a required-policy marker before opening access, safely refreshes an
existing/restored stash, and closes existing sessions. Every subsequent
transfer checks the current callback. A stopped/missing provider denies access.
The optional fourth callback argument is trusted inventory context. Only
`ClaimStash` sets `{ recovery = true }` there; client open options cannot forge it.

`RebindStashPolicy(id, callback)` only replaces an already persisted policy's
callback for its owning resource. It does not save contents or capacity and is
safe while a recovery outcome is pending. `UnregisterStashPolicy(id)` closes
access and retains the required marker.

`SetStashBlocked(id, boolean)` returns `true` only after the owner acquires the
same stash lock used by transfers and durably saves the block. It closes
sessions. A busy stash returns `false, error`; callers must retry before checking
emptiness or completing a sale. The block survives restart and policy refresh.

`ClaimStash(source, id, operationKey)` moves all stash items to that player and
returns `true, receipt` or `false, error`. This trusted owner-only API commits
the stash, `players.inventory`, and an operation receipt in one checked SQL
transaction, coordinated with kora_core's inventory persistence fence. Reuse the
same key after an uncertain result. A completed key returns its original
receipt without delivering again or touching later deposits. A clean capacity
rejection may retry with the same key after making room. Pending operations
keep affected inventory locked until receipt reconciliation succeeds. These
APIs also have lowercase-first aliases.

### Register a shop and let players buy from it
```lua
-- server, e.g. a 24/7 store resource
exports.kora_inventory:RegisterShop('liquorstore', {
    slots = 5,
    inventory = {
        { slot = 1, name = 'water_bottle', amount = 50, price = 5 },
        { slot = 2, name = 'sandwich', amount = 50, price = 8 },
    },
})

-- client, once the player has the shop's inventory open
exports.kora_inventory:openInventory('shop', 'liquorstore')
```
The buy path itself is client-driven through the panel's `buy` intent; a
gameplay resource only needs to register the shop and open it. To sell
programmatically from server code, call `exports.kora_inventory:buyItem(source,
'liquorstore', slot, count)` after your own payment logic.

### Custom useable item with a progress bar
```lua
-- server
exports.kora_inventory:createUseable('bandage', function(src, item)
    exports.kora_inventory:removeItem(src, 'bandage', 1, item.slot)
    -- heal the player, etc.
end)
```
```lua
-- shared item definition (kora_core's `items` registry)
Kora.shared.register('items', 'bandage', {
    label = 'Bandage', weight = 100, useable = true, useTime = 2500,
})
```
`useTime` runs kora_lib's client progress bar before the use request is ever
sent to the server; a cancelled bar never reaches your handler.

Item definitions are resolved through kora_core's getter when an operation runs;
kora_inventory does not capture the shared Items table at startup. Definitions can
therefore be registered, updated, or removed at runtime. Its built-in weapon and
ammunition handlers also subscribe to those registry changes, so a newly
registered weapon or magazine is usable immediately without restarting either
resource.

### Ground drops
```lua
-- server: drop items at a location (e.g. on player death)
local dropId = exports.kora_inventory:dropCreate(GetEntityCoords(ped), {
    [1] = { name = 'water_bottle', amount = 1, slot = 1 },
})
```
```lua
-- client: listen for drops appearing/disappearing to manage blips/targets
RegisterNetEvent('kora_inventory:client:dropCreated', function(id, coords) end)
RegisterNetEvent('kora_inventory:client:dropRemoved', function(id) end)

-- client: open a known drop by id (server re-validates distance/existence)
exports.kora_inventory:openInventory('drop', dropId)
```

### Register a crafting recipe (server-only foundation)
```lua
-- server, in the resource that owns the crafting station
exports.kora_inventory:RegisterCraftRecipe('repair_board', {
    ingredients = { { name = 'wood', amount = 2, metadata = { grade = 'oak' } } },
    output = { name = 'board', amount = 1, metadata = { quality = 100 } },
    access = function(source, recipe, context) return true end, -- your own station/job/proximity checks
})

-- later, after your resource has resolved station/job/proximity server-side
exports.kora_inventory:CraftItem(source, 'repair_board', trustedContext, amount)
```
`server/crafting.lua` registers no NUI callback or network event on its own —
a gameplay resource supplies the UI and the trusted context.

## API reference

All server-side unless noted. Every name below is reachable in **both**
`camelCase` and `PascalCase` (e.g. `registerStash`/`RegisterStash`) — pick
whichever reads better.

### Player inventory (routes through kora_core's mutation funnel)
```lua
exports.kora_inventory:getWeight(src)                          -- weight, maxWeight
exports.kora_inventory:canCarry(src, name, amount)
exports.kora_inventory:addItem(src, name, amount, slot, info, reason)
exports.kora_inventory:removeItem(src, name, amount, slot, reason)
exports.kora_inventory:getItemByName(src, name)
exports.kora_inventory:getItemsByName(src, name)
exports.kora_inventory:getItemBySlot(src, slot)
exports.kora_inventory:getItemCount(src, names)
exports.kora_inventory:hasItem(src, names, amount)
exports.kora_inventory:getFreeSlot(src)
exports.kora_inventory:moveItem(src, fromSlot, toSlot, amount)
exports.kora_inventory:clearInventory(src, keep)
exports.kora_inventory:setItems(src, newItems)
exports.kora_inventory:createUseable(name, handler)             -- handler(src, item)
exports.kora_inventory:useItem(src, slotOrName)
```
qb-style aliases are also exported: `AddItem`, `RemoveItem`, `GetItemByName`,
`GetItemsByName`, `GetItemBySlot`, `GetItemCount`, `HasItem`, `GetFreeSlot`,
`CanAddItem`, `GetFreeWeight`, `ClearInventory`, `SetInventory`,
`CreateUsableItem`, `OpenInventory`, `CloseInventory`, `GetInventory`,
`GetStashItems`, `SetStashItems`.

### Stashes, temporary stashes, shops
```lua
exports.kora_inventory:stashGet(id)
exports.kora_inventory:stashSet(id, items)
exports.kora_inventory:stashOpen(src, id, opts)
exports.kora_inventory:registerStash(id, label, slots, maxWeight, owner, groups, coords, distance)
exports.kora_inventory:createTemporaryStash(properties)          -- returns an inventory key
exports.kora_inventory:registerShop(id, data)                    -- { slots, inventory/items, prices }
exports.kora_inventory:buyItem(src, shopId, slot, count)
```
`RegisterStash(..., owner = true, ...)` is a **template**, not a single shared
stash: each caller gets their own `stash:<template>:<citizenid>` record,
derived server-side from the caller's own session.

`coords` may be one `{ x, y, z }` point or an array of them. A shop accepts the
same forms in `data.coords`. The server grants and continuously revalidates a
session only while the player is within `distance` of at least one registered
point; re-registering an id moves that boundary without resetting its contents.
A point in a list may carry its own `distance` override.

### Drops
```lua
exports.kora_inventory:dropCreate(coords, items)                 -- returns dropId
exports.kora_inventory:dropTake(src, dropId, slot, amount)
```

### Hooks and inspection access
```lua
exports.kora_inventory:registerHook(eventName, callback, options)  -- returns an ox hook id "resource:event:n"
exports.kora_inventory:removeHooks(id)                              -- caller's own hook; no id removes all of the caller's hooks
exports.kora_inventory:registerInspectionAccess(callback)           -- callback(source, target, sourceData, targetData)
exports.kora_inventory:removeInspectionAccess(id)
```
`registerHook` follows ox_inventory's `modules/hooks/server.lua`. The callback
gets `(payload, source)`; `payload.source` is always set. Events and ox payloads:

| Event | Payload |
|---|---|
| `swapItems` | `action` (`move`/`swap`/`stack`/`give`), `fromInventory`/`toInventory` (ox ids: a player's server id, the bare stash/drop/shop id, `newdrop` for a new ground drop), `fromType`/`toType`, `fromSlot`/`toSlot` (ox slot tables `name, count, metadata, slot, weight`; `toSlot` is a number when the target is empty), `count`, `dropId` (new drops) |
| `buyItem` | `shopType`, `shopId`, `toInventory`, `toSlot`, `fromSlot`, `itemName`, `metadata`, `count`, `price`, `totalPrice`, `currency` |
| `createItem` | `inventoryId`, `item` (ox definition), `metadata`, `count`, `resource` |
| `craftItem` | `benchId`, `benchIndex`, `recipe` (`name, count, ingredients = {item = count}`), `toInventory`, `toSlot` |
| `openInventory` | `inventoryId`, `inventoryType` |
| `openShop` | `shopId`, `shopType`, `label`, `slots`, `items`, `groups`, `coords`, `distance` |
| `usingItem` | `inventoryId`, `item` (slot table), `consume` |

Kora keeps `itemName` and the kora inventory keys (`fromKey`, `toKey`,
`inventoryKey`, e.g. `stash:box`) as extra fields. Gives and ground drops fire
`swapItems` (`give`, and `move` to `newdrop`) after kora's validation and
before anything moves; hooks can observe or cancel but never bypass kora's
checks. `buyItem` fires after validation and the affordability check but before the payment is taken (so it is affordable) and
before delivery; cancelling takes no money. `createItem` is not cancellable: only a
returned table (which replaces the metadata) has an effect, `false` is ignored.
Elsewhere returning `false` cancels. A returned string also cancels (with that reason) only for `kora_*` owners or `koraKeys = true` hooks; for other resources, as in ox, only `false` cancels.

Options: `itemFilter = { item = true }` (checks `fromSlot`/`item`/`itemName`/
`recipe`, then `toSlot`), `inventoryFilter = { '^stash' }` (array of Lua
patterns tested against the from/to/inventory id; a kora exact-key map such as
`{ ['stash:box'] = true }` is also accepted), `typeFilter = { stash = true }`
(`inventoryType`/`shopType`/`fromType`) and `print = true`. After the guarded
action finishes, `TriggerEvent(hookId, success, payload)` fires for every hook
that ran (about 50 ms later), so a hook can be registered without a callback to
listen for outcomes only. First-party `kora_*` resources keep receiving kora
keys in the id fields (and may also match `toType` in `typeFilter`) for
backwards compatibility; pass `koraKeys = true/false` in the options to force
either form.
Opening another player's inventory is default-deny; a registered inspection
policy (or `Config.kora_inventory.playerInspection.access`) must return `true`
for an authorised police/admin/consent flow.

### Crafting (server-only, headless foundation)
```lua
exports.kora_inventory:RegisterCraftRecipe(id, recipe)
exports.kora_inventory:RemoveCraftRecipe(id)
exports.kora_inventory:GetCraftRecipe(id)
exports.kora_inventory:CanCraftRecipe(src, recipeId, amount)
exports.kora_inventory:CraftItem(src, recipeId, trustedContext, amount)
exports.kora_inventory:RegisterCraftHook(callback)
exports.kora_inventory:RemoveCraftHook(id)
```
Ships no station discovery, progress timers, or UI — a gameplay resource
resolves its own server-side station/job/proximity checks before calling
`CraftItem`. The optional amount defaults to one and is bounded by
`Config.kora_inventory.crafting.maxBatchAmount`; a batch remains one atomic
ingredient/output transaction.

### Weapons (server-only)
```lua
exports.kora_inventory:PrepareWeaponMetadata(...)
exports.kora_inventory:GetWeaponState(src, slot)
exports.kora_inventory:SetWeaponState(...)
exports.kora_inventory:ConsumeWeaponDurability(...)
exports.kora_inventory:SetWeaponAmmo(...)
exports.kora_inventory:SetWeaponComponents(...)
exports.kora_inventory:FireWeaponRound(src, slot) -- consumes ammo only; returns true, round
```
New weapon metadata gets a server-generated serial, bounded durability/ammo,
and only components listed in `Config.kora_inventory.weapons.components`.

Native shot reports use `Config.kora_inventory.weapons.ballistics.shotCooldown`
on both client and server. Each accepted shot consumes one server-owned round
and its configured wear in one weapon-slot commit, followed by one final
`kora_inventory:server:weaponStateChanged` and one
`kora_inventory:server:weaponRoundFired` notification. Ammo and durability remain
authoritative immediately; `FireWeaponRound` retains its ammo-only contract.

### Visible weapon carry
```lua
exports.kora_inventory:GetCarriedWeapons(src)  -- read-only, server-built
exports.kora_inventory:GetEquippedWeapon(src)  -- { slot, name, components? } or nil; mapped components from server-owned item metadata
```
`Config.kora_inventory.weaponCarry` renders weapons a player owns but is not
holding onto their body, and makes equipping one a timed, animated draw.
`visibility = 'all'` shows every carryable weapon; `'hotbar'` shows only slots
`1..hotbarSlots` and charges `concealedDrawTime` extra to draw anything stowed
past them. The carried list is built on the server and pushed out on the
replicated `kora_inventory:weaponCarry` player state bag; clients only render it.

### Vehicles (trunk/glovebox)
```lua
KoraInventory.vehicles.registerAccess(callback, options)   -- (in the domain module's realm)
```
Or set `Config.kora_inventory.vehicles.ownerCheck` / `.accessCheck` to trusted
callbacks. Only a network id is ever accepted from the client — plate, class,
coordinates, and capacity are all resolved server-side. Slots/weight per
vehicle class live in `Config.kora_inventory.vehicles.classes`.

### Item containers and evidence/confiscation
```lua
KoraInventory.containers.create(id, options)
KoraInventory.containers.open(src, id)
KoraInventory.containers.bindItem(src, slot, options)      -- portable container bound to a real item
KoraInventory.containers.openItem(src, slot)

KoraInventory.evidence.open(src, evidenceId)                -- alias: KoraInventory.confiscation
KoraInventory.evidence.seize(src, targetSource, evidenceId, sourceSlot, amount, evidenceSlot)
KoraInventory.evidence.release(src, targetSource, evidenceId, evidenceSlot, amount, playerSlot)
```
Both are server-only domain modules with no NUI callback or network event of
their own; a gameplay resource resolves its interaction server-side first.
`Config.kora_inventory.containers.items.backpack` ships as a ready-made 20-slot,
60kg portable container. Evidence is default-deny — configure
`Config.kora_inventory.containers.evidence.access(source, action, context)`.

### Client and renderer contract
```lua
exports.kora_inventory:openInventory(invType, data)   -- client — 'player'|'stash'|'trunk'|'glovebox'|'shop'|'drop'|...
exports.kora_inventory:closeInventory()               -- client
exports.kora_inventory:submitIntent(intent)           -- client — used by the bundled NUI bridge
exports.kora_inventory:getCurrentSession()            -- client
exports.kora_inventory:HasItem(names, amount)         -- client, reads the local session snapshot
```
Local presentation events fired after the server resolves a request:
`kora_inventory:ui:sessionOpened`, `kora_inventory:ui:sessionPatched`,
`kora_inventory:ui:sessionClosed`, `kora_inventory:ui:rejected`.

### Provider identities (qb-inventory / ox_inventory compat)
Both identities are enabled and published under `__cfx_export_<identity>_<name>`
— a separate namespace from kora_inventory's own flat exports, so same-named qb
and ox functions keep different upstream return shapes. Legacy net events like
`qb-inventory:client:openInventory`, `qb-inventory:server:useItem`, and the
`inventory`/`openInv`/`closeInv` commands are bridged transparently. A few
upstream events are deliberately inert no-ops where trusting the client would
break the authority model (`qb-inventory:server:updateDrop`,
`qb-inventory:server:snowball`) — call the real exports from server code
instead.

#### qb-inventory server surface

- `AddItem`/`RemoveItem(identifier, item, amount, slot, info|reason, ...)` take a
  player source or a stash, `trunk-<plate>`, `glovebox-<plate>`, `drop-<id>` or
  temporary identifier and return a boolean. Unknown inventories are refused (stock
  does not create them either); shops, evidence, confiscation and portable
  containers are not reachable. `RemoveItem` without a slot drains matching slots.
- `AddHook`/`RemoveHook`/`AddListener`/`RemoveListener` exist upstream and are
  implemented for `ItemMoved`, `ItemDropped`, `ItemUsed`, `ItemBought`,
  `ItemAdded`, `ItemRemoved`, `InventoryOpened`, `ShopOpened`. Callbacks receive
  `(type, data)` as upstream. Opening the player's own inventory raises no
  `InventoryOpened`.
- `OpenInventory(src)` with no identifier opens the player's own inventory.
  `CreateInventory` on an existing stash refreshes label, slots and maxweight.
- `HasItem` follows stock for string, array and `{ [name] = count }` forms (also on
  the client); counts are summed across slots.
- Legacy `inventory:server:OpenInventory` / `qb-inventory:server:OpenInventory`
  (`type, id`) open only inventories the server already has (stash, shop, drop,
  player), through the normal access/distance checks; the client's capacity or stock
  argument is ignored and trunk/glovebox are refused. `UseItem` aliases read a slot
  from the caller's own inventory. `SetIsOpenState` is a no-op.
- Client `qb-inventory:client:ItemBox` / `inventory:client:ItemBox` draw a receipt
  (label and art from the registry, `itemBoxes` policy applies, de-duplicated against
  the server's own receipt). `requiredItems` shows a text-UI hint from item names.
- Kept deliberately different: give distance is `interactionDistance` (3.0, stock
  5.0); `GetCurrentDrops`/`createDrop` return ids without contents or a networked bag;
  `updateInventory` is a no-op (the session stream keeps the UI current).

The client compatibility helpers also normalize ox-style notifications,
multi-select input rows, and progress scenarios/props onto kora_lib. The ox
`center-left`/`center-right` notification positions retain their horizontal
side but use kora_lib's top edge because kora_lib has no vertically centered toast
stack.

## Config highlights (`config.lua`)

`Config.kora_inventory.playerSlots` (41), `Config.kora_inventory.defaultSlots` (50
for stashes/shops/drops), `Config.kora_inventory.vehicles.classes` (per-class
trunk/glovebox slots and weight, set a type to `false` to disable it),
`Config.kora_inventory.playerInspection.access`, `Config.kora_inventory.weapons.components`,
`Config.kora_inventory.hotbarSlots` (5 -- both the number-key range and what
counts as openly carried), `Config.kora_inventory.weaponCarry`,
`Config.kora_inventory.containers.items` (portable container item definitions,
e.g. `backpack`), `Config.kora_inventory.containers.evidence.access`. Bundled
Ammu-Nation shop data lives in `config/shops/ammunation.lua`.

## Related resources

Part of the [qbcore2](https://github.com/qbcore2) resource set:

- [kora_lib](https://qbcore2.github.io/kora_lib/) — shared helper library
- [kora_sql](https://qbcore2.github.io/kora_sql/) — database driver
- [kora_core](https://qbcore2.github.io/kora_core/) — framework core
- [kora_target](https://qbcore2.github.io/kora_target/) — targeting/interaction
- [kora_clothing](https://qbcore2.github.io/kora_clothing/) — clothing/wardrobe
- [kora_drugs](https://qbcore2.github.io/kora_drugs/) — drug production/economy job
- [full resource list ↗](https://github.com/orgs/qbcore2/repositories)
