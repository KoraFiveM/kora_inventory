-- removeFrom's return contract, which every one of its call sites depends on.
--
-- `removeFrom` dispatches to removePlayer for a player inventory and
-- removeSecondary for everything else (stash, drop, trunk, glovebox,
-- container, evidence). removePlayer returned `(ok, err, item)`;
-- removeSecondary returned `(ok, item)` -- one value short. Every caller
-- destructures three:
--
--   local removedOK, removedErr, removed = removeFrom(fromKey, fromSlot, amount)
--
-- so a transfer OUT of any secondary inventory bound the item to `removedErr`
-- and left `removed` nil, and the very next line crashed with
--   server.lua:716: attempt to index a nil value (local 'removed')
--
-- Behavioural rather than a source grep: the existing transfer coverage in
-- security.lua asserts on source text, which is exactly why a return-arity
-- mismatch survived it.
local H = dofile('test/harness.lua')

Config = { qbinventory = {} }
dofile('config.lua')
dofile('config/shops/ammunation.lua')
dofile('shared.lua')

Kora = {
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
GetGameTimer = function() return 12345 end

local ITEMS = {
    water_bottle = { name = 'water_bottle', label = 'Water', weight = 500, type = 'item', unique = false },
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

local internal = QbInventory.internal

-- A stash standing in for every secondary type: they all reach removeFrom by
-- the same route.
internal.createSecondary('stash', 'contract-test', { label = 'Stash', slots = 10, maxWeight = 100000 })
local stashKey = internal.key('stash', 'contract-test')
H.ok(internal.addTo(stashKey, 'water_bottle', 4, 1, {}, 'seed'), 'sanity: the stash was seeded')



local ok, err, removed = internal.removeFrom(stashKey, 1, 2)

H.equal(ok, true, 'removing from a secondary succeeds')
H.equal(err, nil, 'the SECOND return is the error slot, and must be nil on success')
H.ok(type(removed) == 'table', 'the THIRD return is the removed item -- every call site reads it there')
H.equal(removed and removed.name, 'water_bottle', 'the removed item carries its name')
H.equal(removed and removed.amount, 2, 'and the amount actually removed, not the whole stack')

-- The refusal shape has to match too, or an error message would arrive as an item.
local badOK, badErr, badItem = internal.removeFrom(stashKey, 9, 1)
H.equal(badOK, false, 'an empty slot refuses')
H.equal(badErr, 'empty slot', 'with the reason in the error slot')
H.equal(badItem, nil, 'and no item')

H.finish()
