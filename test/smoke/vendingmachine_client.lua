local H = dofile('test/harness.lua')
Config = { kora_inventory = {} }
dofile('config/shops/vendingmachine.lua')

local handlers, active, calls, targetState = {}, {}, 0, 'started'
AddEventHandler = function(name, callback)
    handlers[name] = handlers[name] or {}
    table.insert(handlers[name], callback)
end
GetResourceState = function() return targetState end
exports = { kora_target = { addModel = function(_, models, options)
    calls = calls + 1
    active[calls] = { models = models, options = options }
    return calls
end } }
local function emit(event, resource)
    for _, callback in ipairs(handlers[event] or {}) do callback(resource) end
end
local function count()
    local n = 0
    for _ in pairs(active) do n = n + 1 end
    return n
end

dofile('client/shops/vendingmachine.lua')
H.equal(count(), 1, 'one vending registration on startup')
emit('onClientResourceStart', 'kora_target')
emit('onClientResourceStart', 'kora_target')
H.equal(count(), 1, 'repeated start events do not duplicate vending registrations')
emit('onClientResourceStop', 'kora_target')
active = {} -- Target registrations disappear when kora_target stops.
targetState = 'stopped'
emit('onClientResourceStart', 'kora_target')
H.equal(count(), 0, 'does not register while target is stopped')
targetState = 'started'
emit('onClientResourceStart', 'kora_target')
H.equal(count(), 1, 'registers again when target restarts')
H.equal(active[calls].options[1].label, 'Browse Vending Machine', 'preserves the normal target option')
H.finish()
