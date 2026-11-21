-- Regression (M1): Stack all must apply the decay merge rule (the merged stack
-- keeps its OLDEST stamp) instead of resetting the spoil timer, and behave as
-- before when decay is off.
local H = dofile('test/harness.lua')

Config = { kora_inventory = {} }
dofile('config.lua')
local DAY = 86400
local T0 = 1700000000
dofile('config/shops/ammunation.lua')
dofile('shared.lua')
dofile('shared/decay.lua')
dofile('shared/organize.lua')

local callbacks = {}
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
    callback = { register = function(name, fn) callbacks[name] = fn end },
    sql = {},
    logging = setmetatable({}, { __index = function() return function(_, _, details) if details and details.error then io.stderr:write(tostring(details.error), '\n') end end end }),
}
GetCurrentResourceName = function() return 'kora_inventory' end
GetInvokingResource = function() return nil end
CreateThread = function() end
RegisterCommand = function() end
AddEventHandler = function() end
RegisterNetEvent = function() end
TriggerClientEvent = function() end
TriggerEvent = function() end
local realTime = os.time
os.time = function(t) if t then return realTime(t) end return T0 + 2 * DAY end
local clock = 1000
GetGameTimer = function() return clock end

local ITEMS = {
    sandwich = { name = 'sandwich', label = 'Sandwich', weight = 100, type = 'item', unique = false },
    water_bottle = { name = 'water_bottle', label = 'Water', weight = 500, type = 'item', unique = false },
    bread = { name = 'bread', label = 'Bread', weight = 100, type = 'item', unique = false },
    bandage = { name = 'bandage', label = 'Bandage', weight = 50, type = 'item', unique = false, useable = true },
    weapon_bat = { name = 'weapon_bat', label = 'Bat', weight = 800, type = 'weapon', unique = true },
}

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
dofile('server/decay.lua')

local internal = KoraInventory.internal
local config = Config.kora_inventory
config.decay = {
    enabled = true, defaultAction = 'convert', mergePolicy = 'oldest', sweepSeconds = 0,
    items = { sandwich = { lifetime = 5 * DAY, into = 'garbage' } },
    pauseIn = { stash = false, trunk = false, glovebox = false, container = false, drop = false },
}
internal.createSecondary('stash', 'dec-test', { label = 'Stash', slots = 12, maxWeight = 1000000 })
local key = internal.key('stash', 'dec-test')
local src = 1
local intent = callbacks['kora_inventory:server:intent']
local opened, session = internal.open(src, key)
H.ok(opened, 'sanity: a session on the stash opened')
local clock2 = 0
local function inv() return internal.getInventory(key) end

local function seed(createdOld, createdFresh)
    for slot = 1, 12 do inv().items[slot] = nil end
    local function stamped(slot, createdAt)
        local item = internal.buildItem('sandwich', 2, slot, {})
        item.info = { createdAt = createdAt, decayLifetime = 5 * DAY }
        item.metadata = item.info
        inv().items[slot] = item
    end
    stamped(3, createdFresh) -- the FRESH stack sits first, so it would win a naive merge
    stamped(7, createdOld)
end
local function stack()
    clock = clock + 5000
    return intent(src, {
        token = session.token, action = 'organize',
        payload = { inventory = key, mode = 'stack' },
        secondaryRevision = internal.getInventory(key).revision or 0,
    })
end

-- Decay on: fresh + nearly spoiled stack together and keep the OLDEST stamp.
seed(T0, T0 + 2 * DAY - 60)
local ok, result = stack()
H.ok(ok, 'stack succeeds: ' .. tostring(result))
H.equal(inv().items[3].amount, 4, 'the two sandwich stacks merged')
H.equal(inv().items[7], nil, 'the other slot is emptied')
H.equal(inv().items[3].info.createdAt, T0, 'the merged stack keeps the OLDEST createdAt')
H.equal(inv().items[3].metadata.createdAt, T0, 'metadata mirrors the oldest createdAt')

-- Order independence: old stack first, fresh second.
seed(T0 + 2 * DAY - 60, T0)
ok = stack()
H.ok(ok, 'stack succeeds (reverse order)')
H.equal(inv().items[3].info.createdAt, T0, 'the oldest createdAt wins in either order')

-- Decay off: behaviour unchanged, stamps are left alone (no rewrite).
config.decay.enabled = false
seed(T0, T0 + 2 * DAY - 60)
ok = stack()
H.ok(ok, 'stack succeeds with decay off')
H.equal(inv().items[3].amount, 4, 'stacks still merge with decay off')
H.equal(inv().items[3].info.createdAt, T0 + 2 * DAY - 60, 'with decay off the stamp is not touched')

-- 'separate' policy keeps differently aged stacks apart.
config.decay.enabled = true
config.decay.mergePolicy = 'separate'
seed(T0, T0 + 2 * DAY - 60)
ok = stack()
H.ok(ok, 'stack succeeds with separate policy')
H.equal(inv().items[3].amount, 2, 'differently aged stacks stay separate')
H.equal(inv().items[7].amount, 2, 'both stacks remain')

H.finish()
