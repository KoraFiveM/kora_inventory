-- ox_inventory item-data compatibility: Items() returns ox-format definitions
-- translated from kora's registry (registry untouched), the createItem hook
-- fires on item creation with ox metadata-replace semantics, and the kora-only
-- ImportOxItems export registers ox data/items.lua entries into kora_core.
local H = dofile('test/harness.lua')

NOTIFIED = {}
Config = { kora_inventory = {} }
dofile('config.lua')
dofile('config/shops/ammunation.lua')
dofile('shared.lua')

local KoraCallbacks = {}
Kora = {
    util = { deepClone = function(value)
        local seen = {}
        local function clone(v)
            if type(v) ~= "table" then return v end
            if seen[v] then return seen[v] end
            local copy = {}
            seen[v] = copy
            for k, vv in pairs(v) do copy[clone(k)] = clone(vv) end
            return copy
        end
        return clone(value)
    end },
    resources = { serverRegistry = function() return { track = function() end, untrack = function() end } end },
    callback = { register = function(name, fn) KoraCallbacks[name] = fn end },
    sql = {},
    notify = { send = function(_, payload) NOTIFIED[#NOTIFIED + 1] = payload end },
    lang = function(key) return key end,
}
GetCurrentResourceName = function() return 'kora_inventory' end
GetInvokingResource = function() return nil end
CreateThread = function() end
RegisterCommand = function() end
AddEventHandler = function() end
RegisterNetEvent = function() end
TriggerClientEvent = function() end
TriggerEvent = function() end
NOW = 12345
GetGameTimer = function() return NOW end

REGISTERED = {}
local ITEMS = {
    bandage = { name = 'bandage', label = 'Bandage', weight = 100, useable = true },
    map = { name = 'map', label = 'Map', weight = 10, useable = true, preventClose = true },
    -- Legacy item definition: no native preventClose, but the qb-core
    -- `shouldClose = false` convention meant "leave the inventory open".
    oldflare = { name = 'oldflare', label = 'Old Flare', weight = 50, useable = true, shouldClose = false },
    potion = { name = 'potion', label = 'Potion', weight = 20, useable = true, useTime = 2500.9 },
}
local WEAPONS = {
    weapon_pistol = { name = 'weapon_pistol', label = 'Pistol', type = 'weapon', useable = false, weight = 1000 },
}

local playersData = { [7] = { citizenid = 'CID-7' } }
-- Populated below, once buildItem is available, exactly the way every real
-- player item is created (addPlayer/addTo/setItems all route through it) --
-- a hand-authored raw item table would skip the preventClose/useTime
-- derivation entirely and defeat the point of this test.
local playersItems = { [7] = {} }
playersMetadata = { [7] = {} }

local registered = {}
exports = setmetatable({}, {
    __call = function(_, name, fn) registered[name] = fn end,
    __index = function(_, resourceName)
        return setmetatable({}, {
            __index = function(_, exportName)
                return function(_, ...)
                    if resourceName == 'kora_core' then
                        if exportName == 'allShared' then
                            local list = {}
                            for _, def in pairs(ITEMS) do list[#list + 1] = def end
                            return list
                        end
                        if exportName == 'registerShared' then
                            local registry, key, record = ...
                            REGISTERED[#REGISTERED + 1] = { registry = registry, key = key, record = record }
                            if key == 'broken' then return false, 'nope' end
                            ITEMS[key] = record
                            return true
                        end
                        if exportName == 'getShared' then
                            local registry, itemName = ...
                            if registry == 'weapons' then return WEAPONS[itemName] end
                            return registry == 'items' and ITEMS[itemName] or nil
                        end
                        if exportName == 'getPlayerData' then
                            local src, fields = ...
                            if fields and fields[1] == 'items' then return playersItems[src] end
                            if fields and fields[1] == 'metadata' then return playersMetadata[src] end
                            return playersData[src]
                        end
                        if exportName == 'setPath' then
                            local src, path, value = ...
                            if path[1] ~= 'items' then return false, 'unsupported path' end
                            playersItems[src] = playersItems[src] or {}
                            if path[2] then playersItems[src][path[2]] = value
                            else playersItems[src] = value end
                            return true
                        end
                    end
                    local fn = registered[exportName]
                    if fn then return fn(...) end
                    return nil
                end
            end,
        })
    end,
})

dofile('server/persistence.lua')
dofile('server.lua')
dofile('server/compat/ox.lua')

local Q = KoraInventory
local ox = Q.compat.ox

-- Items(): ox shape, kora registry untouched
local before = Q.copy(ITEMS.bandage)
local def = ox.Items('Bandage')
H.equal(def.name, 'bandage', 'Items(name) is case-insensitive')
H.equal(def.label, 'Bandage', 'label carried')
H.equal(def.weight, 100, 'weight carried')
H.equal(def.stack, true, 'ordinary item stacks')
H.equal(def.close, true, 'close defaults true')
H.equal(def.consume, 1, 'consume defaults to 1')
H.equal(type(def.client), 'table', 'client table exists')
H.equal(def.client.image, 'bandage.png', 'image defaults to <name>.png')
H.equal(type(def.server), 'table', 'server table exists')
H.equal(def.useable, true, 'kora fields kept as extra keys')
for key, value in pairs(before) do H.equal(ITEMS.bandage[key], value, 'registry record unchanged: ' .. key) end
H.equal(ITEMS.bandage.client, nil, 'registry record gained no client table')
H.equal(ox.Items('oldflare').close, false, 'shouldClose=false maps to close=false')
H.equal(ox.Items('nothing'), nil, 'unknown item is nil')
local all = ox.Items()
H.equal(all.map.name, 'map', 'Items() is name-keyed')
H.equal(type(all.map.client), 'table', 'Items() entries are ox-shaped')
H.equal(ox.ItemList('map').client.image, 'map.png', 'ItemList alias translates')
local uniq = Q.toOxItemDef({ name = 'phone', unique = true, image = 'p.png' })
H.equal(uniq.stack, false, 'unique item does not stack')
H.equal(uniq.client.image, 'p.png', 'kora image becomes client.image')
H.equal(Q.toOxItemDef({ name = 'w', type = 'weapon' }).weapon, true, 'weapon flag')

-- createItem hook
playersItems[7] = {}
local seen
local id = Q.api.registerHook('createItem', function(payload, src)
    seen = { payload = payload, src = src, incoming = payload.metadata.quality }
    return { quality = 77 }
end, { itemFilter = { bandage = true } })
H.ok(Q.api.addItem(7, 'bandage', 1, nil, { quality = 1 }), 'addItem succeeds with a hook')
H.equal(seen.src, 7, 'hook receives source')
H.equal(seen.payload.inventoryId, 'player:7', 'payload.inventoryId')
H.equal(seen.payload.count, 1, 'payload.count')
H.equal(seen.payload.item.name, 'bandage', 'payload.item is the ox item definition')
H.equal(type(seen.payload.item.client), 'table', 'payload.item is ox-shaped')
H.equal(seen.incoming, 1, 'payload.metadata is the incoming metadata')
H.equal(playersItems[7][1].info.quality, 77, 'returned table replaces metadata')

seen = nil
H.ok(Q.api.addItem(7, 'map', 1), 'unfiltered item still adds')
H.equal(seen, nil, 'itemFilter excludes other items')

Q.api.removeHooks(id)
seen = nil
Q.api.addItem(7, 'bandage', 1)
H.equal(seen, nil, 'removeHooks detaches createItem')

local deny = Q.api.registerHook('createItem', function() return false end)
local denied = Q.api.addItem(7, 'potion', 1)
H.ok(denied, 'a false return does NOT cancel creation (ox semantics)')
Q.api.removeHooks(deny)

-- ox AddItem export fires the hook too
local oxSeen
local oxId = Q.api.registerHook('createItem', function(payload) oxSeen = { a = payload.metadata.a }; return { via = 'ox' } end,
    { inventoryFilter = { '^7$' } })
local added = ox.AddItem(7, 'potion', 1, { a = 1 })
H.ok(added, 'ox.AddItem succeeds')
H.equal(oxSeen.a, 1, 'ox.AddItem passes metadata')
local found
for _, item in pairs(playersItems[7]) do if item.name == 'potion' then found = item end end
H.equal(found.info.via, 'ox', 'ox.AddItem honours replaced metadata')
Q.api.removeHooks(oxId)

-- moves never count as creation
local moved
local moveId = Q.api.registerHook('createItem', function() moved = true end)
Q.internal.addTo('player:7', 'map', 1, nil, {}, 'transfer')
H.equal(moved, nil, 'internal addTo (moves/rollbacks) does not fire createItem')
Q.api.removeHooks(moveId)

-- ImportOxItems
local count, errors = Q.api.ImportOxItems({
    burger = { label = 'Burger', weight = 220, client = { image = 'burger.png', status = { hunger = 200000 } } },
    pistolclip = { label = 'Clip', weight = 5, stack = false, close = false, description = 'x' },
    bandage = { label = 'Dup' },
    broken = { label = 'Broken' },
})
H.equal(count, 2, 'two new items registered')
H.equal(errors.bandage, 'already_registered', 'existing kora item is not overwritten')
H.equal(errors.broken, 'nope', 'registry errors are reported')
H.equal(ITEMS.bandage.label, 'Bandage', 'existing record untouched')
H.equal(ITEMS.burger.image, 'burger.png', 'client.image becomes kora image')
H.equal(ITEMS.burger.useable, true, 'consumable status makes it useable')
H.equal(ITEMS.pistolclip.unique, true, 'stack=false maps to unique')
H.equal(ITEMS.pistolclip.shouldClose, false, 'close=false maps to shouldClose=false')
H.equal(ox.Items('burger').client.status.hunger, 200000, 'imported client data round-trips through Items()')
H.equal(Q.api.importOxItems ~= nil, true, 'lowercase alias exists')
local _, bad = Q.api.ImportOxItems('nope')
H.equal(bad['*'], 'invalid_definitions', 'non-table rejected')
local overwritten = Q.api.ImportOxItems({ bandage = { label = 'New' } }, { overwrite = true })
H.equal(overwritten, 1, 'overwrite opt-in replaces')

H.finish()
