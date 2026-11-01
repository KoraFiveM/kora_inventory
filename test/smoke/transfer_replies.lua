-- The transfer callback must answer on EVERY path. An unanswered callback leaves
-- the browser's NUI fetch pending (busy cursor, drags locked) until a timeout.
-- Covers a same-slot no-op, validation failures and an error raised inside the
-- handler: each returns an (ok, result) pair instead of nothing or an error.
local H = dofile('test/harness.lua')

Config = { qbinventory = {} }
dofile('config.lua')
dofile('config/shops/ammunation.lua')
dofile('shared.lua')

local callbacks = {}
Kora = {
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
    radio = { name = 'radio', label = 'Radio', weight = 500, type = 'item', unique = false },
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
internal.createSecondary('stash', 'reply-test', { label = 'Stash', slots = 10, maxWeight = 1000000 })
local stashKey = internal.key('stash', 'reply-test')
local src = 1
local opened, session = internal.open(src, stashKey)
H.ok(opened, 'sanity: a session on the stash opened')
H.ok(internal.addTo(stashKey, 'radio', 1, 1, {}, 'seed'), 'seeded a radio')

local transfer = callbacks['qbinventory:server:transfer']
local function call(request)
    request.token = request.token or session.token
    local packed = table.pack(transfer(src, request))
    H.ok(packed[1] == true or packed[1] == false, 'always answers with a boolean verdict')
    return table.unpack(packed, 1, packed.n)
end

-- Same slot: a no-op that answers ok and changes nothing.
local ok = call({ fromInventory = stashKey, toInventory = stashKey, fromSlot = 1, toSlot = 1 })
H.equal(ok, true, 'a move onto its own slot is answered ok')
H.equal(internal.getInventory(stashKey).items[1].name, 'radio', 'and the item stays put')

-- A normal one-row move of a single non-stackable item.
ok = call({ fromInventory = stashKey, toInventory = stashKey, fromSlot = 1, toSlot = 2 })
H.equal(ok, true, 'a one-slot move is answered ok')
H.equal(internal.getInventory(stashKey).items[2].name, 'radio', 'the radio moved')

-- Validation failures reply false plus a reason.
local failures = {
    ['not a table'] = 'x',
    ['empty slot'] = { fromInventory = stashKey, toInventory = stashKey, fromSlot = 5, toSlot = 6 },
    ['bad target slot'] = { fromInventory = stashKey, toInventory = stashKey, fromSlot = 2, toSlot = 99 },
    ['bad token'] = { token = 'nope', fromInventory = stashKey, toInventory = stashKey, fromSlot = 2, toSlot = 3 },
    ['unknown inventory'] = { fromInventory = 'stash:missing', toInventory = stashKey, fromSlot = 2, toSlot = 3 },
}
for label, request in pairs(failures) do
    local verdict, reason
    if type(request) == 'table' then
        verdict, reason = call(request)
    else
        verdict, reason = transfer(src, request)
    end
    H.equal(verdict, false, 'refused: ' .. label)
    H.equal(type(reason), 'string', 'with a reason: ' .. label)
end

-- An error raised inside the handler still replies { false, reason }.
local safe = QbInventory.replyingTransfer
H.ok(type(safe) == 'function', 'the guarded transfer is exposed')
local verdict, reason = safe(src, setmetatable({}, { __index = function() error('boom') end }))
H.equal(verdict, false, 'an error inside transfer still replies')
H.equal(reason, 'transfer failed', 'with a generic reason')

H.finish()
