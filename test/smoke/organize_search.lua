-- Regression (C1): organizing a SEARCHED player's inventory. The plan used to
-- be computed from the target's items and written into the searcher's own
-- inventory (item duplication). It must be refused and change nothing.
local H = dofile('test/harness.lua')

Config = { kora_inventory = {} }
dofile('config.lua')
dofile('shared.lua')
dofile('shared/organize.lua')

local function clone(value)
    local seen = {}
    local function copy(v)
        if type(v) ~= 'table' then return v end
        if seen[v] then return seen[v] end
        local out = {}
        seen[v] = out
        for k, vv in pairs(v) do out[copy(k)] = copy(vv) end
        return out
    end
    return copy(value)
end

local callbacks, handlers, netEvents, sent = {}, {}, {}, {}
Kora = {
    util = { deepClone = clone },
    resources = { serverRegistry = function() return { track = function() end, untrack = function() end } end },
    callback = { register = function(name, fn) callbacks[name] = fn end },
    distance = { player = function(source, point, distance)
        return math.abs(point.x - GetEntityCoords(GetPlayerPed(source)).x) <= distance
    end },
    sql = {},
    notify = { send = function() end },
    logging = setmetatable({}, { __index = function() return function(_, _, d) if d and d.error then io.stderr:write(tostring(d.error), '\n') end end end }),
    lang = function(key) return key end,
}
local positions = { [7] = 0, [9] = 1, [11] = 1 }
GetCurrentResourceName = function() return 'kora_inventory' end
GetInvokingResource = function() return nil end
CreateThread = function() end
RegisterCommand = function() end
AddEventHandler = function(name, fn) handlers[name] = handlers[name] or {}; table.insert(handlers[name], fn) end
RegisterNetEvent = function(name, fn) netEvents[name] = fn end
TriggerClientEvent = function(name, src, ...) sent[#sent + 1] = { name = name, src = src, args = { ... } } end
TriggerEvent = function(name, ...) for _, fn in ipairs(handlers[name] or {}) do fn(...) end end
GetGameTimer = function() return 5000 end
GetPlayerPed = function(source) return source end
GetEntityCoords = function(ped) return { x = positions[ped], y = 0, z = 0 } end
GetPlayerRoutingBucket = function() return 0 end

local ITEMS = {
    phone = { name = 'phone', label = 'Phone', weight = 100, useable = true },
    backpack = { name = 'backpack', label = 'Backpack', weight = 500, unique = true },
    weed = { name = 'weed', label = 'Weed', weight = 10 },
}
local playerData = { [7] = { citizenid = 'CID-7' }, [9] = { citizenid = 'CID-9' }, [11] = { citizenid = 'CID-11' } }
local playersItems = { [7] = {}, [9] = {}, [11] = {} }
playersMetadata = {}
local registered = {}
exports = setmetatable({}, {
    __call = function(_, name, fn) registered[name] = fn end,
    __index = function(_, resource)
        return setmetatable({}, { __index = function(_, name)
            return function(_, ...)
                if resource == 'kora_core' then
                    if name == 'allShared' then return {} end
                    if name == 'getShared' then
                        local registry, item = ...
                        return registry == 'items' and ITEMS[item] or nil
                    end
                    if name == 'getPlayerData' then
                        local src, fields = ...
                        if not playerData[src] then return nil end
                        if fields and fields[1] == 'items' then
                            if fields[2] then return playersItems[src][fields[2]] end
                            return playersItems[src]
                        end
                        if fields and fields[1] == 'metadata' then return playersMetadata[src] end
                        return playerData[src]
                    end
                    if name == 'setPath' then
                        local src, path, value = ...
                        if path[1] ~= 'items' then return false, 'unsupported path' end
                        if path[2] then playersItems[src][path[2]] = value else playersItems[src] = value end
                        return true
                    end
                end
                local fn = registered[name]
                if fn then return fn(...) end
            end
        end })
    end,
})

dofile('server/persistence.lua')
dofile('server.lua')
dofile('server/containers.lua')

local I = KoraInventory.internal
local intent = callbacks['kora_inventory:server:intent']
H.ok(type(intent) == 'function', 'the intent callback is registered')

local I = KoraInventory.internal
local intent = callbacks['kora_inventory:server:intent']
Config.kora_inventory.playerInspection.access = function() return true end

local function snapshot(items)
    local out = {}
    for slot, item in pairs(items) do out[slot] = item.name .. 'x' .. item.amount end
    return out
end
local function same(a, b)
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k, v in pairs(b) do if a[k] ~= v then return false end end
    return true
end

-- Searcher 7 holds a phone; victim 9 holds scattered weed stacks.
playersItems[7][4] = I.buildItem('phone', 1, 4, {})
playersItems[9][2] = I.buildItem('weed', 5, 2, {})
playersItems[9][8] = I.buildItem('weed', 5, 8, {})
playersItems[9][9] = I.buildItem('phone', 2, 9, {})

positions[7], positions[9] = 0, 1
local opened = I.openInventory(7, 'player', 9)
H.ok(opened, 'the searcher opens the victim inventory')
local session = I.sessionOf(7)
H.equal(session.secondary, 'player:9', 'the victim is the secondary panel')

local ownBefore, victimBefore = snapshot(playersItems[7]), snapshot(playersItems[9])
for _, mode in ipairs({ 'stack', 'sort' }) do
    local ok, err = intent(7, {
        token = session.token, action = 'organize',
        payload = { inventory = 'player:9', mode = mode },
        primaryRevision = I.getRevision('player:7'), secondaryRevision = I.getRevision('player:9'),
    })
    H.equal(ok, false, mode .. ' on a searched player inventory is refused')
    H.equal(err, "cannot organize another player's inventory", mode .. ' refusal names the reason')
    H.ok(same(snapshot(playersItems[7]), ownBefore), mode .. ' leaves the searcher inventory untouched')
    H.ok(same(snapshot(playersItems[9]), victimBefore), mode .. ' leaves the victim inventory untouched')
end

-- The searcher's own panel (primary) can still be organized.
local ok, ownErr = intent(7, {
    token = session.token, action = 'organize',
    payload = { inventory = 'player:7', mode = 'sort' },
    primaryRevision = I.getRevision('player:7'), secondaryRevision = I.getRevision('player:9'),
})
H.ok(ok, 'the searcher can still organize their own inventory during a search: ' .. tostring(ownErr))
H.ok(same(snapshot(playersItems[9]), victimBefore), 'and the victim inventory is still untouched')

H.finish()
