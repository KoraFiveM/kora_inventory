-- Behavioural: the give intent moves the full requested amount, validates it
-- strictly, and checks recipient weight/slots for that whole amount.
local H = dofile('test/harness.lua')

Config = { kora_inventory = {} }
dofile('config.lua')
dofile('config/shops/ammunation.lua')
dofile('shared.lua')

local callbacks = {}
Kora = {
    resources = { serverRegistry = function() return { track = function() end, untrack = function() end } end },
    callback = { register = function(name, fn) callbacks[name] = fn end },
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
TriggerClientEvent = function() end
TriggerEvent = function() end
GetGameTimer = function() return 12345 end
GetPlayerRoutingBucket = function() return 0 end
GetPlayerPed = function(src) return 1000 + src end
GetEntityCoords = function() return { x = 0.0, y = 0.0, z = 0.0 } end

local ITEMS = {
    bread = { name = 'bread', label = 'Bread', weight = 100, type = 'item', unique = false },
    gem = { name = 'gem', label = 'Gem', weight = 10, type = 'item', unique = true },
}
local playersData = { [7] = { citizenid = 'CID-7' }, [9] = { citizenid = 'CID-9' } }
local playersItems = { [7] = {}, [9] = {} }

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
                            if fields and fields[1] == 'metadata' then return {} end
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

local internal = KoraInventory.internal
local intent = callbacks['kora_inventory:server:intent']

local function reset(giverItems, recipientItems)
    playersItems[7], playersItems[9] = giverItems, recipientItems or {}
end
local function count(src, name)
    local sum = 0
    for _, item in pairs(playersItems[src]) do
        if item.name == name then sum = sum + item.amount end
    end
    return sum
end
local function slots(src, name)
    local n = 0
    for _, item in pairs(playersItems[src]) do
        if item.name == name then n = n + 1 end
    end
    return n
end
local function give(amount, slot)
    local opened, payload = internal.openSelf(7)
    H.ok(opened, 'inventory opens')
    return intent(7, {
        token = payload.token, action = 'give',
        payload = { slot = slot or 1, amount = amount, target = 9 },
        primaryRevision = payload.primary.revision,
    })
end

-- A multi-unit give moves exactly the requested amount.
reset({ [1] = internal.buildItem('bread', 10, 1, {}) })
local ok = give(4)
H.ok(ok, 'giving 4 of 10 succeeds')
H.equal(count(7, 'bread'), 6, 'giver keeps the remainder')
H.equal(count(9, 'bread'), 4, 'recipient receives the full amount')

-- Omitting the amount keeps the existing whole-stack behaviour; the full stack also works.
reset({ [1] = internal.buildItem('bread', 10, 1, {}) })
H.ok(give(10), 'giving the whole stack succeeds')
H.equal(count(7, 'bread'), 0, 'giver is emptied')
H.equal(count(9, 'bread'), 10, 'recipient gets the whole stack')

-- Rejected amounts leave both inventories untouched.
for label, bad in pairs({
    over = 11, zero = 0, negative = -3, fractional = 2.5, string = 'abc',
    numericString = '2', boolean = true, tbl = {}, nan = 0 / 0, huge = 1e300, inf = math.huge,
}) do
    reset({ [1] = internal.buildItem('bread', 10, 1, {}) })
    local given = give(bad)
    H.equal(given, false, 'amount ' .. label .. ' is rejected')
    H.equal(count(7, 'bread'), 10, label .. ': giver unchanged')
    H.equal(count(9, 'bread'), 0, label .. ': recipient unchanged')
end

-- The weight check covers the whole amount, not one unit.
local max = internal.getInventory(internal.playerKey(9)).maxWeight
local fill = math.floor(max / 100) - 2 -- recipient has room for exactly one more bread
reset({ [1] = internal.buildItem('bread', 10, 1, {}) }, { [2] = internal.buildItem('bread', fill, 2, {}) })
H.ok(give(1), 'one unit fits under the recipient limit')
reset({ [1] = internal.buildItem('bread', 10, 1, {}) }, { [2] = internal.buildItem('bread', fill, 2, {}) })
local ok5, err5 = give(5)
H.equal(ok5, false, 'five units exceed the recipient limit: ' .. tostring(err5))
H.equal(err5, 'recipient is over weight', 'rejected for weight')
H.equal(count(7, 'bread'), 10, 'sender unchanged after the weight rejection')
H.equal(count(9, 'bread'), fill, 'recipient unchanged after the weight rejection')

-- A unique stack of N needs N free slots and lands in N separate slots.
local function crowd(freeSlots)
    local items, total = {}, internal.getInventory(internal.playerKey(9)).slots
    for slot = 1, total - freeSlots do items[slot] = internal.buildItem('bread', 1, slot, {}) end
    return items
end
local stack = internal.buildItem('gem', 3, 1, {})
reset({ [1] = stack }, crowd(2))
local fewer = give(3)
H.equal(fewer, false, 'unique amount 3 is rejected with only 2 free slots')
H.equal(count(7, 'gem'), 3, 'sender keeps the unique stack')
H.equal(count(9, 'gem'), 0, 'recipient got none')

reset({ [1] = internal.buildItem('gem', 3, 1, {}) }, crowd(3))
H.ok(give(3), 'unique amount 3 succeeds with 3 free slots')
H.equal(count(7, 'gem'), 0, 'sender no longer holds the gems')
H.equal(slots(9, 'gem'), 3, 'recipient holds the gems in 3 separate slots')
H.equal(count(9, 'gem'), 3, 'recipient total is 3')

H.finish()
