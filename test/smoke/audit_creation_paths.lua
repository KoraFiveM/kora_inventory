-- Regression (L3): items created by a decay conversion and a water-damage
-- conversion are recorded in the item-creation audit log (actions 'decay' and
-- 'water'). Real server.lua, server/decay.lua, server/water_damage.lua and
-- server/audit_log.lua; only natives and kora_core are stubbed.
local H = dofile('test/harness.lua')

Config = { kora_inventory = {} }
dofile('config.lua')
dofile('shared.lua')
dofile('shared/decay.lua')

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

local callbacks, handlers, netEvents = {}, {}, {}
local notified = {}
Kora = {
    util = { deepClone = clone },
    resources = { serverRegistry = function() return { track = function() end, untrack = function() end } end },
    callback = { register = function(name, fn) callbacks[name] = fn end },
    distance = { player = function() return true end },
    sql = {},
    notify = { send = function(_, payload) notified[#notified + 1] = payload end },
    lang = function(key) return key end,
}
NOW = 100000
GetCurrentResourceName = function() return 'kora_inventory' end
GetInvokingResource = function() return nil end
CreateThread = function() end
RegisterCommand = function() end
AddEventHandler = function(name, fn) handlers[name] = handlers[name] or {}; table.insert(handlers[name], fn) end
RegisterNetEvent = function(name, fn) netEvents[name] = fn end
TriggerClientEvent = function() end
TriggerEvent = function(name, ...) for _, fn in ipairs(handlers[name] or {}) do fn(...) end end
GetGameTimer = function() return NOW end
GetPlayerPed = function(source) return source end
GetEntityCoords = function() return { x = 0, y = 0, z = 0 } end
GetPlayerRoutingBucket = function() return 0 end

local ITEMS = {
    phone = { name = 'phone', label = 'Phone', weight = 100, useable = true },
    iphone = { name = 'iphone', label = 'iPhone', weight = 100, useable = true },
    radio = { name = 'radio', label = 'Radio', weight = 200, useable = true },
    electronickit = { name = 'electronickit', label = 'Electronic Kit', weight = 300, useable = true },
    garbage = { name = 'garbage', label = 'Garbage', weight = 50 },
    sandwich = { name = 'sandwich', label = 'Sandwich', weight = 50, useable = true },
    backpack = { name = 'backpack', label = 'Backpack', weight = 500, unique = true },
}
local playerData = { [7] = { citizenid = 'CID-7' }, [8] = { citizenid = 'CID-8' } }
local playersItems = { [7] = {}, [8] = {} }
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

local DAY = 86400
local T0 = 1700000000
local realTime = os.time
local now = T0
os.time = function(t) if t then return realTime(t) end return now end

dofile('server/persistence.lua')
dofile('server.lua')
dofile('server/containers.lua')
dofile('server/decay.lua')
dofile('server/water_damage.lua')
dofile('server/audit_log.lua')

local I, W, log = KoraInventory.internal, KoraInventory.waterDamage, KoraInventory.auditLog
local cfg = Config.kora_inventory
cfg.audit.enabled, cfg.audit.persist = true, false
cfg.decay = {
    enabled = true, defaultAction = 'convert', mergePolicy = 'oldest', sweepSeconds = 0,
    items = { sandwich = { lifetime = DAY, into = 'garbage' } },
    pauseIn = { stash = false, trunk = false, glovebox = false, container = false, drop = false },
}
cfg.waterDamage.enabled = true
cfg.waterDamage.mode = 'convert'
cfg.waterDamage.into = 'garbage'
cfg.waterDamage.items = { phone = { chance = 1.0 } }

local function rows(action)
    log.reset()
    return function()
        local out = {}
        for _, row in ipairs(log.query({ range = '1h' }).rows) do
            if row.action == action then out[#out + 1] = row end
        end
        return out
    end
end

-- Decay: a spoiled sandwich stack converts to garbage -> audited as 'decay'.
local decayRows = rows('decay')
local sandwich = I.buildItem('sandwich', 3, 1, {})
sandwich.info.createdAt = T0 - 5 * DAY
sandwich.info.decayLifetime = DAY
sandwich.metadata = sandwich.info
playersItems[7] = { [1] = sandwich }
H.equal(KoraInventory.decayRuntime.guard('player:7', 1, 7), true, 'the spoiled stack is processed')
H.equal(playersItems[7][1].name, 'garbage', 'it converted to garbage')
local got = decayRows()
H.equal(#got, 1, 'the decay conversion is audited')
H.equal(got[1].item, 'garbage', 'the audited item is the created one')
H.equal(got[1].amount, 3, 'with the created amount')
H.equal(got[1].source, 7, 'for the owning player')
H.equal(got[1].inventory, 'player:7', 'in their inventory')

-- Removal-only decay creates nothing, so nothing is audited.
cfg.decay.items.sandwich.into = nil
decayRows = rows('decay')
local second = I.buildItem('sandwich', 1, 1, {})
second.info.createdAt, second.info.decayLifetime = T0 - 5 * DAY, DAY
second.metadata = second.info
playersItems[7] = { [1] = second }
KoraInventory.decayRuntime.guard('player:7', 1, 7)
H.equal(#decayRows(), 0, 'a spoiled item that is only removed is not an item creation')

-- Water damage convert: phone -> garbage is audited as 'water'.
local waterRows = rows('water')
W.reset()
now = now + 100000
NOW = NOW + 100000
W.setRandom(function() return 0 end)
playersItems[7] = { [1] = I.buildItem('phone', 2, 1, {}) }
H.ok(W.report(7), 'the swim report is accepted')
H.equal(playersItems[7][1].name, 'garbage', 'the phone converted')
got = waterRows()
H.equal(#got, 1, 'the water damage conversion is audited')
H.equal(got[1].item, 'garbage', 'the audited item is the created one')
H.equal(got[1].amount, 2, 'with the created amount')
H.equal(got[1].source, 7, 'for the swimmer')

H.finish()
