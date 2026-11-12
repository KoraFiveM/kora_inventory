---
title: "How to use"
sidebar_position: 3
---


# How to use

Kora Inventory is a set of server exports plus a client session layer. Your resources call the exports to add items, register stashes and shops, create usable items and craft; the client only ever sends a small intent (open this, move that slot, use that slot) and the server decides.

## How the pieces fit together

- **Player items live in kora_core.** A player's slots are `PlayerData.items` and the `players.inventory` column. kora_inventory never keeps its own copy: every player write goes through `exports.kora_core:setPath`, so kora_core's dirty-column saves and live replication still work.
- **kora_inventory owns everything else.** Stashes, shops, ground drops, containers, evidence, trunks and gloveboxes are "secondary inventories" held in memory and saved to `kora_inventory_inventories` (shops also in `kora_inventory_shop_stock`).
- **Item definitions live in kora_core's shared registry** (`items` and `weapons`). kora_inventory looks a definition up every time it needs one (`exports.kora_core:getShared('items', name)`), so items you register at runtime work immediately.
- **The NUI is only a renderer.** The bundled page sends intents through `client/ui.lua`; `server.lua` validates the session token, both inventory revisions, access, routing bucket and distance before changing anything.
- **Weights are in grams.** The default player limit `120000` is 120 kg. `slots` are counted per inventory. Slots `1..hotbarSlots` (5 by default) double as the hotbar.

## Inventory types

Every inventory has a key of the form `kind:id`. The kinds that exist in code are listed here. Clients can only ask to open a key; whether it opens is decided on the server.

- `player:<serverId>` — a player's own inventory (`Config.kora_inventory.playerSlots` / `playerMaxWeight`). Opening another player's is denied unless a trusted inspection policy allows it.
- `stash:<id>` — persistent storage registered with `RegisterStash`, or created on demand by `stashOpen`/`OpenInventory`. Per-citizen stashes are stored as `stash:<id>:<citizenid>`.
- `shop:<id>` — a read-only catalogue with finite stock and prices (`RegisterShop`). Items leave it only through a purchase.
- `drop:<id>` — a ground bag. Created when a player drops an item or by `dropCreate`; deleted when emptied; not persisted unless `persistence.persistDrops` is on.
- `container:<id>` — an item-bound or standalone container. A configured portable item (the shipped `backpack`) binds one generated container to each unique item.
- `evidence:<id>` — police evidence storage. Default deny; opened only through the evidence policy callback.
- `trunk:<PLATE>` and `glovebox:<PLATE>` — vehicle storage derived on the server from a live vehicle's plate and class.
- `temporary:<id>` — a short-lived stash (`CreateTemporaryStash`); not persisted by default.
- `confiscation:<source>` — created by the ox compat `ConfiscateInventory`; clients can never open it.
- Not inventories but part of the same resource: crafting recipes (`RegisterCraftRecipe`), durable player exchanges (`ExecutePlayerExchange`), weapon state and visible weapon carry.

## Calling the exports

Many server exports exist under both a capitalised name and a lower-case alias (`AddItem` and `addItem`, `RegisterStash` and `registerStash`) and both resolve to the same function; others exist in one form only (`OpenInventory`, `CraftItem`, `getWeight`). Each function entry shows its exact name and aliases. Client exports are lower-case apart from `HasItem`. Call them like any export:

```text title="server.lua (any resource)"
local added, reason = exports.kora_inventory:AddItem(source, 'water_bottle', 2, nil, nil, 'shop-reward')
if not added then
    print(('could not give water: %s'):format(reason))
end

-- Functions passed to an export (access callbacks, handlers) arrive as callable
-- references; kora_inventory checks them with inventory.isCallable, so plain
-- functions and cross-resource references both work.
```

## Reward items safely from a server event

Never let a client name the item or the amount. The server starts the job, remembers what it is worth, and only pays out when the matching completion arrives. Check capacity first so nothing is half-granted, and always handle the failure reason.

```lua title="server.lua"
local jobs = {} -- [source] = { token, item, amount, expires }

RegisterNetEvent('scrapjob:server:start', function()
    local src = source
    -- decide the reward here, on the server
    jobs[src] = { token = tostring(math.random(100000, 999999)), item = 'metalscrap', amount = 3, expires = GetGameTimer() + 120000 }
    TriggerClientEvent('scrapjob:client:begin', src, jobs[src].token)
end)

RegisterNetEvent('scrapjob:server:finish', function(token)
    local src = source
    local job = jobs[src]
    jobs[src] = nil                                  -- one-use
    if not job or job.token ~= token or GetGameTimer() > job.expires then return end

    local ok, why = exports.kora_inventory:canCarry(src, job.item, job.amount)
    if not ok then
        Kora.notify.send(src, { title = 'Scrap job', message = 'You cannot carry that: ' .. tostring(why), type = 'error' })
        return
    end
    local added, err = exports.kora_inventory:AddItem(src, job.item, job.amount, nil, { source = 'scrapjob' }, 'scrapjob-reward')
    if not added then
        print(('scrapjob: AddItem failed for %s: %s'):format(src, tostring(err)))
    end
end)
```

## Register a custom item

Items are plain records in kora_core's `items` registry. Register them from a server script; kora_inventory sees them at once. The record is owned by the registering resource and removed again when that resource stops, so register at every start.

```lua title="server.lua"
local ok, err = exports.kora_core:registerShared('items', 'lockpick_adv', {
    name = 'lockpick_adv',          -- lower-case, must equal the key
    label = 'Advanced Lockpick',
    weight = 200,                   -- grams
    type = 'item',
    unique = false,                 -- true: never stacks, one instance per slot
    useable = true,                 -- shows the Use button
    shouldClose = true,             -- close the panel after use
    useTime = 3000,                 -- optional: progress bar (ms) before the use is sent
    image = 'lockpick_adv.png',     -- file in kora_inventory/images
    description = 'Opens most locks quietly.',
})
if not ok then print('item registration failed: ' .. tostring(err)) end
```

## Register a usable item

The handler runs on the server with the player source and a detached copy of the item. Return false to refuse the use (nothing is reported as used). The slot is locked against dropping, giving and moving while the handler runs.

```lua title="server.lua"
exports.kora_inventory:createUseable('lockpick_adv', function(src, item)
    -- item.slot is the live slot; item.info is the instance metadata
    local removed, reason = exports.kora_inventory:removeItem(src, item.name, 1, item.slot, 'used')
    if not removed then return false end
    TriggerClientEvent('scrapjob:client:pickLock', src)
    return true
end)
```

## Create a shop

A shop is registered once on the server. Give it `coords` (one point or a list) or an `access` callback, otherwise a client can request it from anywhere. Stock rows need a real item name, an amount and a price.

```lua title="server.lua"
exports.kora_inventory:RegisterShop('hardware', {
    label = 'Hardware Store',
    slots = 12,
    maxWeight = 60000,
    currency = 'cash',                          -- kora_core account; 'money' also means cash
    coords = vector3(2747.7, 3472.9, 55.7),
    distance = 2.5,
    inventory = {
        { name = 'lockpick',     amount = 25, price = 150 },
        { name = 'water_bottle', amount = 60, price = 8 },
    },
})
```

A client then opens it with `exports.kora_inventory:openInventory('shop', 'hardware')`. The server re-checks distance on every purchase.

## Create a stash restricted to a job

`groups` maps a job or gang name to the minimum grade level. The check reads the player's kora_core job on the server every time the stash is opened or used.

```lua title="server.lua"
-- RegisterStash(id, label, slots, maxWeight, owner, groups, coords, distance)
exports.kora_inventory:RegisterStash('pd_armoury', 'PD Armoury', 60, 250000,
    nil,                      -- owner: nil = shared, true = one stash per citizen
    { police = 2 },           -- police grade 2 or higher
    vector3(452.6, -980.0, 30.7), 2.0)
```

Players open it with `exports.kora_inventory:openInventory('stash', 'pd_armoury')` from the client. For a per-citizen stash (apartment storage) pass `true` as the owner and open it from the server with `exports.kora_inventory:OpenInventory(src, id)`.

## Failure results and what they mean

Most server functions return `ok, reason`. The reason is a short string; branch on `ok`, not on the text, except for the vocabularies called out in the compat modules.

- `unknown item` — the name is not in kora_core's `items` or `weapons` registry (names are matched lower-case).
- `over weight` / `no free slot` — the inventory cannot hold it. `canCarry` returns the same two reasons without changing anything.
- `inventory not found`, `no such player` — the key or source does not resolve.
- `not enough of item`, `empty slot`, `item not in slot` — removal shortfalls.
- `inventory busy` — another transaction holds the lock on that inventory; retry shortly.
- `transaction failed` — an error was raised inside a locked section and printed to the console.
- `you cannot use inventories while downed` / `while cuffed`, `item is currently being used` — the blocking rules in Configuration.
- `shop inventory is read only`, `shop items must be purchased` — shop stock cannot be moved with transfers.

## Security model

- The client sends intent only: an inventory key, a slot, an amount. Item names, metadata, prices, weights and definitions are always re-read on the server.
- Every UI request carries a session token issued by the server when the inventory opened, plus the revision of each inventory. A stale revision, wrong token, expired session, wrong routing bucket or distance failure rejects the request.
- Server exports are for trusted server code only. A server resource that forwards a raw client value into `AddItem` or `RegisterShop` reintroduces the exploit this resource removes; validate first, then call.
- Net events that an export or another resource triggers locally are ignored (`GetInvokingResource()` guard), so only a real client packet reaches them.
- Player inspection, evidence, vehicle storage and stash policies are default-deny callbacks supplied by trusted resources.
- A busy slot (use handler running or progress bar active) cannot be dropped, given or moved, so an item cannot be used and kept.

## Limitations worth knowing

- The container, evidence and vehicle-storage modules are Lua tables inside the resource (`KoraInventory.containers`, `KoraInventory.evidence`, `KoraInventory.vehicles`). They are not exported; other resources reach them through configuration callbacks and the exports listed under their modules.
- The audit trail is an in-memory ring (`Config.kora_inventory.auditLimit`) plus the `kora_inventory:server:audit` event. The `kora_inventory_audit` table is created but nothing in the resource writes to it.
- Player inventory size and weight come from config only; the ox compat `SetSlotCount` / `SetMaxWeight` refuse player inventories.
- Shop stock changed with `SetShopItems` is not price-validated; rows without a `price` sell for the shop's `prices[name]` or for free.
- Access callbacks can only deny with a generic `access denied` for stashes and shops; the reason string they return is not shown to the player.
