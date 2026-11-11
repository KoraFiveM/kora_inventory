-- Pre-release audit fixes: a downed player cannot keep moving items through an
-- open session, AddItem refuses an out-of-range slot, a swap cannot put a
-- backpack into its own container, the qb createDrop/giveItem callbacks honour
-- the mid-use lock, and a new drop never reuses the id of a live one.
local H = dofile('test/harness.lua')

Config = { kora_inventory = {} }
dofile('config.lua')
dofile('config/shops/ammunation.lua')
dofile('shared.lua')

local KoraCallbacks = {}
local CLIENT = {}
Kora = {
    resources = { serverRegistry = function() return { track = function() end, untrack = function() end } end },
    callback = { register = function(name, fn) KoraCallbacks[name] = fn end },
    sql = {},
    notify = { send = function() end },
    lang = function(key) return key end,
    distance = { player = function() return true end },
}
GetCurrentResourceName = function() return 'kora_inventory' end
GetInvokingResource = function() return nil end
CreateThread = function() end
RegisterCommand = function() end
AddEventHandler = function() end
RegisterNetEvent = function() end
TriggerClientEvent = function(name, src, ...) CLIENT[#CLIENT + 1] = { name = name, src = src, args = { ... } } end
TriggerEvent = function() end
GetGameTimer = function() return 1000 end
GetPlayerPed = function(src) return 100 + src end
GetEntityCoords = function() return { x = 0.0, y = 0.0, z = 0.0 } end
GetPlayerRoutingBucket = function() return 0 end
GetPlayers = function() return { '7' } end

local ITEMS = {
    bandage = { name = 'bandage', label = 'Bandage', weight = 100, useable = true },
    water = { name = 'water', label = 'Water', weight = 10 },
    backpack = { name = 'backpack', label = 'Backpack', weight = 1, unique = true },
}
local playersData = { [7] = { citizenid = 'CID-7', name = 'Seven' } }
local playersItems = { [7] = {} }
local playersMetadata = { [7] = {} }

local registered = {}
exports = setmetatable({}, {
    __call = function(_, name, fn) registered[name] = fn end,
    __index = function(_, resourceName)
        return setmetatable({}, {
            __index = function(_, exportName)
                return function(_, ...)
                    if resourceName == 'kora_core' then
                        if exportName == 'allShared' then return {} end
                        if exportName == 'getShared' then
                            local registry, itemName = ...
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
                            if path[2] then playersItems[src][path[2]] = value else playersItems[src] = value end
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
dofile('server/containers.lua')
dofile('server/compat/qb_callbacks.lua')

local internal, api = KoraInventory.internal, KoraInventory.api
local buildItem = internal.buildItem
local transfer = KoraCallbacks['kora_inventory:server:transfer']

local function reset()
    playersItems[7] = { [1] = buildItem('bandage', 2, 1, {}), [2] = buildItem('water', 3, 2, {}) }
    playersMetadata[7] = {}
end

local function selfMove(payload, from, to, amount)
    return transfer(7, {
        token = payload.token, fromInventory = 'player:7', toInventory = 'player:7',
        fromSlot = from, toSlot = to, amount = amount or 1,
        fromRevision = payload.primary.revision, toRevision = payload.primary.revision,
    })
end

-- Downed with the panel still open: refused, and the session is closed.
reset()
local _, payload = internal.openSelf(7)
playersMetadata[7].inlaststand = true
local ok, why = selfMove(payload, 2, 5)
H.equal(ok, false, 'a downed player cannot move items in an open session')
H.equal(why, 'you cannot use inventories while downed', 'the refusal says why')
H.equal(internal.sessionOf(7), nil, 'the session is closed when the player is down')
H.equal(playersItems[7][2].amount, 3, 'nothing moved')
playersMetadata[7] = {}

-- AddItem with a slot outside 1..playerSlots stores nothing invisible.
reset()
H.equal((api.addItem(7, 'water', 1, Config.kora_inventory.playerSlots + 50)), false, 'an out-of-range slot is refused')
H.equal((api.addItem(7, 'water', 1, 0.5)), false, 'a fractional slot is refused')
H.ok(api.addItem(7, 'water', 1, 9), 'an in-range slot still works')
H.equal(playersItems[7][Config.kora_inventory.playerSlots + 50], nil, 'nothing was stored past the last slot')
H.ok(api.addItem(7, 'water', 1, false), 'slot = false still means "anywhere"')

-- A swap must not put a backpack into its own open container.
reset()
playersItems[7][3] = buildItem('backpack', 1, 3, { containerId = 'bp1' })
internal.createSecondary('container', 'bp1', { slots = 5, maxWeight = 1000, items = { [1] = buildItem('water', 1, 1, {}) } })
local opened, session = internal.open(7, 'container:bp1')
H.ok(opened, 'the backpack container opens')
ok, why = transfer(7, {
    token = session.token, fromInventory = 'container:bp1', toInventory = 'player:7',
    fromSlot = 1, toSlot = 3, amount = 1,
    fromRevision = session.secondary.revision, toRevision = session.primary.revision,
})
H.equal(ok, false, 'swapping onto the backpack slot is refused')
H.equal(why, 'a container cannot be stored inside itself', 'with the container reason')
H.equal(playersItems[7][3].name, 'backpack', 'the backpack stays in the player inventory')

-- The qb createDrop / giveItem callbacks respect the mid-use lock.
reset()
local _, fresh = internal.openSelf(7)
local results
api.createUseable('bandage', function(src)
    results = {
        drop = KoraCallbacks['qb-inventory:server:createDrop'](src, { fromSlot = 1, amount = 1 }),
        give = KoraCallbacks['qb-inventory:server:giveItem'](src, 8, 'bandage', 1, 1),
    }
    return true
end)
playersData[8] = { citizenid = 'CID-8' }
playersItems[8], playersMetadata[8] = {}, {}
H.ok(fresh and api.useItem(7, 1), 'the use completes')
H.equal(results.drop, false, 'createDrop mid-use is refused')
H.equal(results.give, false, 'giveItem mid-use is refused')
H.equal(playersItems[7][1].amount, 2, 'the item being used stayed in its slot')
H.equal(next(playersItems[8]), nil, 'nothing reached the other player')

-- A new drop never reuses the id of a drop that is already live.
reset()
internal.createSecondary('drop', 1, { coords = { x = 50.0, y = 0.0, z = 0.0 }, items = { [1] = buildItem('water', 1, 1, {}) }, temporary = true })
local _, dropSession = internal.openSelf(7)
local intent = KoraCallbacks['kora_inventory:server:intent']
local dropped, dropId = intent(7, { token = dropSession.token, action = 'drop', payload = { slot = 2, amount = 1 }, primaryRevision = dropSession.primary.revision })
H.ok(dropped, 'the drop succeeds')
H.ok(dropId ~= 1, 'the new drop takes a free id')
H.equal(internal.getInventory('drop:1').items[1].amount, 1, 'the existing drop is untouched')
H.equal(internal.getInventory('drop:' .. tostring(dropId)).items[1].name, 'water', 'the dropped item is in the new drop')

H.finish()
