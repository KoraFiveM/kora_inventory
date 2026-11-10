-- Coverage for the secondary-inventory re-key primitive.
--
-- ox_inventory's UpdateVehicle renames a trunk/glovebox inventory when a plate
-- changes. Setting inv.id in place is not enough: `inventories` is keyed by the
-- OLD key, so the inventory stays reachable only under the old name while its
-- own .key field claims the new one. Anything that resolved it afterwards --
-- a viewer's session, a revision check, the durable row -- would disagree about
-- what it was called.
local H = dofile('test/harness.lua')

Config = { kora_inventory = {} }
dofile('config.lua')
dofile('config/shops/ammunation.lua')
dofile('shared.lua')

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
    callback = { register = function() end },
    sql = {},
}
GetCurrentResourceName = function() return 'kora_inventory' end
GetInvokingResource = function() return nil end
CreateThread = function() end
RegisterCommand = function() end
AddEventHandler = function() end
RegisterNetEvent = function() end

local registered = {}
exports = setmetatable({}, {
    __call = function(_, name, fn) registered[name] = fn end,
    __index = function(_, resourceName)
        return setmetatable({}, {
            __index = function(_, exportName)
                return function(_, ...)
                    if resourceName == 'kora_core' and exportName == 'allShared' then return {} end
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

local internal = KoraInventory.internal
H.ok(type(internal.rekeySecondary) == 'function', 'rekeySecondary is on the authority seam')

-- Create a trunk inventory and give it contents.
internal.createSecondary('trunk', 'OLDPLATE', { label = 'Trunk', slots = 10, maxWeight = 1000 })
local oldKey = internal.key('trunk', 'OLDPLATE')
H.ok(select(2, internal.resolveInventory(oldKey)) ~= nil, 'the trunk resolves under its original key')

local newKey, err = internal.rekeySecondary(oldKey, 'trunk', 'NEWPLATE')
H.equal(newKey, internal.key('trunk', 'NEWPLATE'), 'rekey returns the new key (' .. tostring(err) .. ')')

local _, moved = internal.resolveInventory(newKey)
H.ok(moved ~= nil, 'the inventory resolves under the NEW key')
H.equal(moved.key, newKey, 'the record carries the new key')
H.equal(moved.id, 'NEWPLATE', 'the record carries the new id')

local _, stale = internal.resolveInventory(oldKey)
H.ok(stale == nil, 'the OLD key no longer resolves -- the registry actually moved')

-- Re-keying onto an existing inventory would silently merge two inventories.
internal.createSecondary('trunk', 'TAKEN', { label = 'Other', slots = 10, maxWeight = 1000 })
local clash, clashErr = internal.rekeySecondary(newKey, 'trunk', 'TAKEN')
H.equal(clash, nil, 'refuses to rekey onto an existing inventory')
H.ok(clashErr ~= nil, 'and says why')

-- A no-op rename must not destroy the inventory on the way through.
local same = internal.rekeySecondary(newKey, 'trunk', 'NEWPLATE')
H.equal(same, newKey, 'renaming to the same identity is a no-op')
H.ok(select(2, internal.resolveInventory(newKey)) ~= nil, 'the inventory survives a no-op rename')

-- Player inventories are owned by kora_core and are not re-keyable.
local refused, refusedErr = internal.rekeySecondary(internal.playerKey(1), 'trunk', 'NOPE')
H.equal(refused, nil, 'refuses to rekey a player inventory')
H.ok(refusedErr ~= nil, 'and says why')

H.finish()
