-- Splitting a stack into an empty slot. Behavioural: runs the real transfer
-- callback against a stash. The bug it guards: an empty target slot fell back
-- to "merge into any matching stack", which found the source stack and put the
-- split amount straight back (10 stayed 10, nothing appeared in the new slot).
local H = dofile('test/harness.lua')

Config = { kora_inventory = {} }
dofile('config.lua')
dofile('config/shops/ammunation.lua')
dofile('shared.lua')

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
}
GetCurrentResourceName = function() return 'kora_inventory' end
GetInvokingResource = function() return nil end
CreateThread = function() end
RegisterCommand = function() end
AddEventHandler = function() end
RegisterNetEvent = function() end
TriggerClientEvent = function() end
TriggerEvent = function() end
GetGameTimer = function() return 12345 end

local ITEMS = {
    water_bottle = { name = 'water_bottle', label = 'Water', weight = 500, type = 'item', unique = false },
    bread = { name = 'bread', label = 'Bread', weight = 100, type = 'item', unique = false },
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

local internal = KoraInventory.internal
internal.createSecondary('stash', 'split-test', { label = 'Stash', slots = 10, maxWeight = 1000000 })
local stashKey = internal.key('stash', 'split-test')
local src = 1
local opened, session = internal.open(src, stashKey)
H.ok(opened, 'sanity: a session on the stash opened')

local function slotAmount(slot)
    local item = internal.getInventory(stashKey).items[slot]
    return item and item.amount or 0
end

local function total()
    local sum = 0
    for _, item in pairs(internal.getInventory(stashKey).items) do sum = sum + item.amount end
    return sum
end

local function move(fromSlot, toSlot, amount)
    return callbacks['kora_inventory:server:transfer'](src, {
        token = session.token, fromInventory = stashKey, toInventory = stashKey,
        fromSlot = fromSlot, toSlot = toSlot, amount = amount,
    })
end

H.ok(internal.addTo(stashKey, 'water_bottle', 10, 1, { quality = 80 }, 'seed'), 'seeded 10 water with metadata')

local ok, err = move(1, 2, 5)
H.ok(ok, 'split 5 of 10 into an empty slot succeeds: ' .. tostring(err))
H.equal(slotAmount(1), 5, 'source keeps 5')
H.equal(slotAmount(2), 5, 'the empty slot receives 5')
H.equal(internal.getInventory(stashKey).items[2].info.quality, 80, 'metadata is preserved on the split stack')
H.equal(total(), 10, 'total is conserved')

-- Odd amount, split as entered rather than rounded.
ok = move(1, 3, 3)
H.ok(ok, 'split an odd amount')
H.equal(slotAmount(1), 2, 'source keeps the remainder')
H.equal(slotAmount(3), 3, 'target gets exactly the entered amount')
H.equal(total(), 10, 'total is conserved after the odd split')

-- Stacking onto a matching stack is unchanged.
ok = move(3, 2, 3)
H.ok(ok, 'moving onto a matching stack still stacks')
H.equal(slotAmount(2), 8, 'stack grew')
H.equal(slotAmount(3), 0, 'emptied source slot is cleared')

-- A different item in the target rejects a partial move and changes nothing.
internal.addTo(stashKey, 'bread', 4, 5, {}, 'seed')
ok, err = move(1, 5, 1)
H.equal(ok, false, 'partial split onto a different item is rejected')
H.equal(slotAmount(1), 2, 'source untouched after rejection')
H.equal(slotAmount(5), 4, 'other item untouched after rejection')

-- Moving a whole stack into an empty slot lands in that slot, not elsewhere.
ok = move(2, 7, 8)
H.ok(ok, 'whole-stack move to an empty slot succeeds')
H.equal(slotAmount(7), 8, 'it lands in the requested slot')
H.equal(slotAmount(2), 0, 'and leaves the old slot empty')

H.finish()
