---
layout: default
title: qbinventory
---

Server-authoritative inventory provider for FiveM, with a bundled NUI. It
ships **both** `qb-inventory` and `ox_inventory` compatibility identities
(`provide 'qb-inventory'` / `provide 'ox_inventory'`), pinned to the contract
fixtures in `test/contracts/`, so same-named qb and ox exports keep their own
upstream-specific signatures through separate identity routing. A real
`qb-inventory` or `ox_inventory` resource must not run alongside it.

Ownership never moves: [qbcore](https://qbcore2.github.io/qbcore/) owns the
slot-keyed `PlayerData.items` object and the `players.inventory` database
column, and qbinventory only mutates player items through qbcore's `setPath`
funnel. qbinventory owns everything else — stashes, temporary stashes, drops,
shops, item containers, evidence/confiscation, trunks/gloveboxes, crafting,
weapon metadata, sessions, revisions, locks, hooks, and audit events — headless
by default, with its own optional NUI as one renderer among possible others.

## Requirements

- [qblib](https://qbcore2.github.io/qblib/)
- [qbsql](https://qbcore2.github.io/qbsql/)
- [qbcore](https://qbcore2.github.io/qbcore/)

## Installation

`server.cfg`, after qbcore:
```
set mysql_connection_string "mysql://user:pass@localhost/qbcore?charset=utf8mb4"
ensure qbsql
ensure qblib
ensure qbcore
ensure qbinventory
```
qbinventory creates its own secondary-inventory tables
(`qbinventory_inventories`, `qbinventory_shop_stock`, migration/audit tables)
on first boot via qbsql's migration runner — no manual schema import needed.

If you're migrating off a real `qb-inventory`/`ox_inventory`, run one of these
from the server console (or grant `command.qbinventory`) once qbinventory has
booted:
```
qbinventory-migrate dry-run   -- inspect import eligibility without writing
qbinventory-migrate run       -- idempotently import eligible legacy data
qbinventory-migrate verify    -- validate stored item JSON, print migration state
qbinventory-migrate retry     -- revisit only previously failed/quarantined rows
```
Legacy rows are copied, never deleted or updated, and malformed rows land in
`qbinventory_quarantine` for review.

## Usage examples

### Give and remove items
```lua
-- server
exports.qbinventory:addItem(source, 'water_bottle', 2)
exports.qbinventory:removeItem(source, 'water_bottle', 1)
```

### Check weight/capacity before granting a reward
```lua
-- server
local weight, maxWeight = exports.qbinventory:getWeight(source)
local canCarry = exports.qbinventory:canCarry(source, 'gold_bar', 1)
if canCarry then
    exports.qbinventory:addItem(source, 'gold_bar', 1, nil, nil, 'mission-reward')
else
    print(('player %d is too full: %d/%d'):format(source, weight, maxWeight))
end
```

### Register and open a private (per-citizen) stash
```lua
-- server, e.g. in a house/garage resource
exports.qbinventory:RegisterStash('house_stash', 'House Storage', 50, 100000, true)

-- client, when the player interacts with the stash prop
exports.qbinventory:openInventory('stash', 'house_stash')
```
`owner = true` derives a durable `stash:house_stash:<citizenid>` record from
the caller's own session server-side — a client can never open another
player's copy of the template by supplying a different identifier.

### Register a shop and let players buy from it
```lua
-- server, e.g. a 24/7 store resource
exports.qbinventory:RegisterShop('liquorstore', {
    slots = 5,
    inventory = {
        { slot = 1, name = 'water_bottle', amount = 50, price = 5 },
        { slot = 2, name = 'sandwich', amount = 50, price = 8 },
    },
})

-- client, once the player has the shop's inventory open
exports.qbinventory:openInventory('shop', 'liquorstore')
```
The buy path itself is client-driven through the panel's `buy` intent; a
gameplay resource only needs to register the shop and open it. To sell
programmatically from server code, call `exports.qbinventory:buyItem(source,
'liquorstore', slot, count)` after your own payment logic.

### Custom useable item with a progress bar
```lua
-- server
exports.qbinventory:createUseable('bandage', function(src, item)
    exports.qbinventory:removeItem(src, 'bandage', 1, item.slot)
    -- heal the player, etc.
end)
```
```lua
-- shared item definition (qbcore's `items` registry)
QB.shared.register('items', 'bandage', {
    label = 'Bandage', weight = 100, useable = true, useTime = 2500,
})
```
`useTime` runs qblib's client progress bar before the use request is ever
sent to the server; a cancelled bar never reaches your handler.

Item definitions are resolved through qbcore's getter when an operation runs;
qbinventory does not capture the shared Items table at startup. Definitions can
therefore be registered, updated, or removed at runtime. Its built-in weapon and
ammunition handlers also subscribe to those registry changes, so a newly
registered weapon or magazine is usable immediately without restarting either
resource.

### Ground drops
```lua
-- server: drop items at a location (e.g. on player death)
local dropId = exports.qbinventory:dropCreate(GetEntityCoords(ped), {
    [1] = { name = 'water_bottle', amount = 1, slot = 1 },
})
```
```lua
-- client: listen for drops appearing/disappearing to manage blips/targets
RegisterNetEvent('qbinventory:client:dropCreated', function(id, coords) end)
RegisterNetEvent('qbinventory:client:dropRemoved', function(id) end)

-- client: open a known drop by id (server re-validates distance/existence)
exports.qbinventory:openInventory('drop', dropId)
```

### Register a crafting recipe (server-only foundation)
```lua
-- server, in the resource that owns the crafting station
exports.qbinventory:RegisterCraftRecipe('repair_board', {
    ingredients = { { name = 'wood', amount = 2, metadata = { grade = 'oak' } } },
    output = { name = 'board', amount = 1, metadata = { quality = 100 } },
    access = function(source, recipe, context) return true end, -- your own station/job/proximity checks
})

-- later, after your resource has resolved station/job/proximity server-side
exports.qbinventory:CraftItem(source, 'repair_board', trustedContext)
```
`server/crafting.lua` registers no NUI callback or network event on its own —
a gameplay resource supplies the UI and the trusted context.

## API reference

All server-side unless noted. Every name below is reachable in **both**
`camelCase` and `PascalCase` (e.g. `registerStash`/`RegisterStash`) — pick
whichever reads better.

### Player inventory (routes through qbcore's mutation funnel)
```lua
exports.qbinventory:getWeight(src)                          -- weight, maxWeight
exports.qbinventory:canCarry(src, name, amount)
exports.qbinventory:addItem(src, name, amount, slot, info, reason)
exports.qbinventory:removeItem(src, name, amount, slot, reason)
exports.qbinventory:getItemByName(src, name)
exports.qbinventory:getItemsByName(src, name)
exports.qbinventory:getItemBySlot(src, slot)
exports.qbinventory:getItemCount(src, names)
exports.qbinventory:hasItem(src, names, amount)
exports.qbinventory:getFreeSlot(src)
exports.qbinventory:moveItem(src, fromSlot, toSlot, amount)
exports.qbinventory:clearInventory(src, keep)
exports.qbinventory:setItems(src, newItems)
exports.qbinventory:createUseable(name, handler)             -- handler(src, item)
exports.qbinventory:useItem(src, slotOrName)
```
qb-style aliases are also exported: `AddItem`, `RemoveItem`, `GetItemByName`,
`GetItemsByName`, `GetItemBySlot`, `GetItemCount`, `HasItem`, `GetFreeSlot`,
`CanAddItem`, `GetFreeWeight`, `ClearInventory`, `SetInventory`,
`CreateUsableItem`, `OpenInventory`, `CloseInventory`, `GetInventory`,
`GetStashItems`, `SetStashItems`.

### Stashes, temporary stashes, shops
```lua
exports.qbinventory:stashGet(id)
exports.qbinventory:stashSet(id, items)
exports.qbinventory:stashOpen(src, id, opts)
exports.qbinventory:registerStash(id, label, slots, maxWeight, owner, groups, coords, distance)
exports.qbinventory:createTemporaryStash(properties)          -- returns an inventory key
exports.qbinventory:registerShop(id, data)                    -- { slots, inventory/items, prices }
exports.qbinventory:buyItem(src, shopId, slot, count)
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
exports.qbinventory:dropCreate(coords, items)                 -- returns dropId
exports.qbinventory:dropTake(src, dropId, slot, amount)
```

### Hooks and inspection access
```lua
exports.qbinventory:registerHook(eventName, callback, options)  -- e.g. 'buyItem'
exports.qbinventory:removeHooks(id)
exports.qbinventory:registerInspectionAccess(callback)           -- callback(source, target, sourceData, targetData)
exports.qbinventory:removeInspectionAccess(id)
```
Opening another player's inventory is default-deny; a registered inspection
policy (or `Config.qbinventory.playerInspection.access`) must return `true`
for an authorised police/admin/consent flow.

### Crafting (server-only, headless foundation)
```lua
exports.qbinventory:RegisterCraftRecipe(id, recipe)
exports.qbinventory:RemoveCraftRecipe(id)
exports.qbinventory:GetCraftRecipe(id)
exports.qbinventory:CraftItem(src, recipeId, trustedContext)
exports.qbinventory:RegisterCraftHook(callback)
exports.qbinventory:RemoveCraftHook(id)
```
Ships no station discovery, progress timers, or UI — a gameplay resource
resolves its own server-side station/job/proximity checks before calling
`CraftItem`.

### Weapons (server-only)
```lua
exports.qbinventory:PrepareWeaponMetadata(...)
exports.qbinventory:GetWeaponState(src, slot)
exports.qbinventory:SetWeaponState(...)
exports.qbinventory:ConsumeWeaponDurability(...)
exports.qbinventory:SetWeaponAmmo(...)
exports.qbinventory:SetWeaponComponents(...)
```
New weapon metadata gets a server-generated serial, bounded durability/ammo,
and only components listed in `Config.qbinventory.weapons.components`.

### Visible weapon carry
```lua
exports.qbinventory:GetCarriedWeapons(src)  -- read-only, server-built
exports.qbinventory:GetEquippedWeapon(src)  -- { slot, name } or nil
```
`Config.qbinventory.weaponCarry` renders weapons a player owns but is not
holding onto their body, and makes equipping one a timed, animated draw.
`visibility = 'all'` shows every carryable weapon; `'hotbar'` shows only slots
`1..hotbarSlots` and charges `concealedDrawTime` extra to draw anything stowed
past them. The carried list is built on the server and pushed out on the
replicated `qbinventory:weaponCarry` player state bag; clients only render it.

### Vehicles (trunk/glovebox)
```lua
QbInventory.vehicles.registerAccess(callback, options)   -- (in the domain module's realm)
```
Or set `Config.qbinventory.vehicles.ownerCheck` / `.accessCheck` to trusted
callbacks. Only a network id is ever accepted from the client — plate, class,
coordinates, and capacity are all resolved server-side. Slots/weight per
vehicle class live in `Config.qbinventory.vehicles.classes`.

### Item containers and evidence/confiscation
```lua
QbInventory.containers.create(id, options)
QbInventory.containers.open(src, id)
QbInventory.containers.bindItem(src, slot, options)      -- portable container bound to a real item
QbInventory.containers.openItem(src, slot)

QbInventory.evidence.open(src, evidenceId)                -- alias: QbInventory.confiscation
QbInventory.evidence.seize(src, targetSource, evidenceId, sourceSlot, amount, evidenceSlot)
QbInventory.evidence.release(src, targetSource, evidenceId, evidenceSlot, amount, playerSlot)
```
Both are server-only domain modules with no NUI callback or network event of
their own; a gameplay resource resolves its interaction server-side first.
`Config.qbinventory.containers.items.backpack` ships as a ready-made 20-slot,
60kg portable container. Evidence is default-deny — configure
`Config.qbinventory.containers.evidence.access(source, action, context)`.

### Client and renderer contract
```lua
exports.qbinventory:openInventory(invType, data)   -- client — 'player'|'stash'|'trunk'|'glovebox'|'shop'|'drop'|...
exports.qbinventory:closeInventory()               -- client
exports.qbinventory:submitIntent(intent)           -- client — used by the bundled NUI bridge
exports.qbinventory:getCurrentSession()            -- client
exports.qbinventory:HasItem(names, amount)         -- client, reads the local session snapshot
```
Local presentation events fired after the server resolves a request:
`qbinventory:ui:sessionOpened`, `qbinventory:ui:sessionPatched`,
`qbinventory:ui:sessionClosed`, `qbinventory:ui:rejected`.

### Provider identities (qb-inventory / ox_inventory compat)
Both identities are enabled and published under `__cfx_export_<identity>_<name>`
— a separate namespace from qbinventory's own flat exports, so same-named qb
and ox functions keep different upstream return shapes. Legacy net events like
`qb-inventory:client:openInventory`, `qb-inventory:server:useItem`, and the
`inventory`/`openInv`/`closeInv` commands are bridged transparently. A few
upstream events are deliberately inert no-ops where trusting the client would
break the authority model (`qb-inventory:server:updateDrop`,
`qb-inventory:server:snowball`) — call the real exports from server code
instead.

The client compatibility helpers also normalize ox-style notifications,
multi-select input rows, and progress scenarios/props onto qblib. The ox
`center-left`/`center-right` notification positions retain their horizontal
side but use qblib's top edge because qblib has no vertically centered toast
stack.

## Config highlights (`config.lua`)

`Config.qbinventory.playerSlots` (41), `Config.qbinventory.defaultSlots` (50
for stashes/shops/drops), `Config.qbinventory.vehicles.classes` (per-class
trunk/glovebox slots and weight, set a type to `false` to disable it),
`Config.qbinventory.playerInspection.access`, `Config.qbinventory.weapons.components`,
`Config.qbinventory.hotbarSlots` (5 -- both the number-key range and what
counts as openly carried), `Config.qbinventory.weaponCarry`,
`Config.qbinventory.containers.items` (portable container item definitions,
e.g. `backpack`), `Config.qbinventory.containers.evidence.access`. Bundled
Ammu-Nation shop data lives in `config/shops/ammunation.lua`.

## Related resources

Part of the [qbcore2](https://github.com/qbcore2) resource set:

- [qblib](https://qbcore2.github.io/qblib/) — shared helper library
- [qbsql](https://qbcore2.github.io/qbsql/) — database driver
- [qbcore](https://qbcore2.github.io/qbcore/) — framework core
- [qbtarget](https://qbcore2.github.io/qbtarget/) — targeting/interaction
- [qbclothing](https://qbcore2.github.io/qbclothing/) — clothing/wardrobe
- [qbdrugs](https://qbcore2.github.io/qbdrugs/) — drug production/economy job
- [full resource list ↗](https://github.com/orgs/qbcore2/repositories)
