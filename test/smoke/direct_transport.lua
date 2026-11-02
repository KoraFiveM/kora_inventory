-- The bundled UI's direct request transport: one net event in, one out, the same
-- handlers as the kora_lib callbacks, and an answer on every path.
local H = dofile('test/harness.lua')

Config = { qbinventory = {} }
dofile('config.lua')
dofile('config/shops/ammunation.lua')
dofile('shared.lua')

H.equal(Config.qbinventory.ui.directTransport, true, 'the direct transport is on by default')
H.equal(Config.qbinventory.ui.moveTimeoutMs, 6000, 'the move deadline is generous when nothing blocks while it waits')
H.equal(Config.qbinventory.ui.optimisticMoves, true, 'optimistic moves stay on by default')
H.equal(Config.qbinventory.slowRequestMs, 250, 'slow requests are logged from 250 ms')

-- Server half -----------------------------------------------------------------

local callbacks, netHandlers, sent = {}, {}, {}
Kora = {
    resources = { serverRegistry = function() return { track = function() end, untrack = function() end } end },
    callback = { register = function(name, fn) callbacks[name] = fn end },
    sql = {},
}
GetCurrentResourceName = function() return 'kora_inventory' end
local invoking
GetInvokingResource = function() return invoking end
CreateThread = function() end
RegisterCommand = function() end
AddEventHandler = function() end
RegisterNetEvent = function(name, fn) netHandlers[name] = fn end
TriggerClientEvent = function(name, target, ...) sent[#sent + 1] = { name = name, target = target, args = { ... } } end
TriggerEvent = function() end
local clock, step = 1000, 0
GetGameTimer = function() clock = clock + step return clock end

local ITEMS = {
    water = { name = 'water', label = 'Water', weight = 100, type = 'item', unique = false },
    bread = { name = 'bread', label = 'Bread', weight = 100, type = 'item', unique = false },
}
local definitionLookups = 0
local playersData = { [1] = { citizenid = 'CID-1', name = 'One' } }
local playersItems = { [1] = {} }
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
                            if registry == 'items' then definitionLookups = definitionLookups + 1 end
                            return registry == 'items' and ITEMS[itemName] or nil
                        end
                        if exportName == 'getPlayerData' then
                            local who, fields = ...
                            if fields and fields[1] == 'items' then return playersItems[who] end
                            if fields and fields[1] == 'metadata' then return {} end
                            return playersData[who]
                        end
                        if exportName == 'setPath' then
                            local who, path, value = ...
                            if path[1] ~= 'items' then return false, 'unsupported path' end
                            if path[2] then playersItems[who][path[2]] = value else playersItems[who] = value end
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

local internal = QbInventory.internal
internal.createSecondary('stash', 'direct', { label = 'Stash', slots = 40, maxWeight = 10000000 })
local stashKey = internal.key('stash', 'direct')
local src = 1
local opened, session = internal.open(src, stashKey)
H.ok(opened, 'sanity: a session on the stash opened')
for slot = 1, 30 do
    H.ok(internal.addTo(stashKey, slot % 2 == 0 and 'water' or 'bread', 3, slot, {}, 'seed'), 'seeded slot ' .. slot)
end

local call = netHandlers['qbinventory:server:call']
H.ok(type(call) == 'function', 'the server listens for direct requests')
local function reply(requestId)
    for i = #sent, 1, -1 do
        if sent[i].name == 'qbinventory:client:callResult' and sent[i].args[1] == requestId then return sent[i], i end
    end
end
_G.source = src

-- A move answers once, to the asking player, after the patches it produced.
sent = {}
local playerKey = internal.key('player', src)
call(7, 'transfer', {
    token = session.token, fromInventory = stashKey, toInventory = playerKey, fromSlot = 1, toSlot = 35, amount = 1,
})
local answer, index = reply(7)
H.ok(answer ~= nil, 'a transfer is answered')
H.equal(answer.target, src, 'the answer goes to the asking player')
H.equal(answer.args[2], true, 'the move succeeded')
H.equal(type(answer.args[3]), 'table', 'with the new revisions')
local firstPatch
for i, event in ipairs(sent) do
    if event.name == 'qbinventory:client:sessionPatched' then firstPatch = firstPatch or i end
end
H.ok(firstPatch and firstPatch < index, 'the patches reach the client before the verdict')
H.equal(internal.getInventory(playerKey).items[35].name, 'bread', 'the server did apply the move')

-- A refusal is an answer with a reason.
sent = {}
call(8, 'transfer', { token = 'wrong', fromInventory = stashKey, toInventory = stashKey, fromSlot = 2, toSlot = 36, amount = 1 })
answer = reply(8)
H.equal(answer.args[2], false, 'a bad token is refused')
H.equal(type(answer.args[3]), 'string', 'with a reason')

-- Intents go through the same handler as the callback.
sent = {}
call(9, 'intent', { token = session.token, action = 'sync' })
H.equal(reply(9).args[2], true, "a sync intent is answered ok: " .. tostring(reply(9).args[3]))
local patches = 0
for _, event in ipairs(sent) do
    if event.name == 'qbinventory:client:sessionPatched' then patches = patches + 1 end
end
H.equal(patches, 2, 'and re-sends both inventories')

-- Unknown actions and malformed ids.
sent = {}
call(10, 'teleport', {})
H.equal(reply(10).args[2], false, 'an unknown action is refused')
H.equal(reply(10).args[3], 'unsupported request', 'with a reason')
sent = {}
for _, id in ipairs({ 0, -1, 1.5, 'x', 2 ^ 40 }) do call(id, 'transfer', {}) end
H.equal(#sent, 0, 'a malformed request id gets no answer to correlate')
invoking = 'other_resource'
call(11, 'transfer', {})
invoking = nil
H.equal(#sent, 0, 'another resource cannot call the net event')

-- An error inside a handler still answers.
sent = {}
call(12, 'intent', setmetatable({}, { __index = function() error('boom') end }))
answer = reply(12)
H.ok(answer ~= nil, 'a raising handler is still answered')
H.equal(answer.args[2], false, 'as a failure')

-- Slow requests are logged with the time the server spent.
local lines, realPrint = {}, print
print = function(...) lines[#lines + 1] = table.concat({ ... }, ' ') end
step = 400
call(13, 'intent', { token = session.token, action = 'sync' })
step = 0
print = realPrint
local slow
for _, line in ipairs(lines) do slow = slow or line:find('slow intent request', 1, true) end
H.ok(slow, 'a request slower than slowRequestMs is logged')
lines = {}
print = function(...) lines[#lines + 1] = table.concat({ ... }, ' ') end
call(14, 'intent', { token = session.token, action = 'sync' })
print = realPrint
H.equal(#lines, 0, 'a fast request logs nothing')

-- The callbacks stay registered for third-party renderers.
H.ok(callbacks['qbinventory:server:transfer'] and callbacks['qbinventory:server:intent'], 'kora_lib callbacks remain')
local ok = callbacks['qbinventory:server:transfer'](src, {
    token = session.token, fromInventory = playerKey, toInventory = playerKey, fromSlot = 35, toSlot = 36, amount = 1,
})
H.equal(ok, true, 'a callback transfer still works')

-- Building a view looks each item up once per distinct name, not once per slot.
definitionLookups = 0
callbacks['qbinventory:server:intent'](src, { token = session.token, action = 'sync' })
H.ok(definitionLookups <= 8, ('a sync of 30 stacked slots made %d definition lookups'):format(definitionLookups))

-- Client half -----------------------------------------------------------------

local function read(path) local f = assert(io.open(path, 'r')); local s = f:read('*a'); f:close(); return s end
local clientNet, clientEvents, serverCalls, timers, legacyCalls = {}, {}, {}, {}, {}
local env = setmetatable({}, { __index = _G })
env.Config = { qbinventory = { ui = {} } }
env.QbInventory = {}
env.exports = setmetatable({}, { __call = function() end, __index = function()
    return setmetatable({}, { __index = function() return function() return nil end end })
end })
env.Kora = {
    callback = { trigger = function(name, request) legacyCalls[#legacyCalls + 1] = { name = name, request = request } return true, 'legacy' end },
    compat = { provideExport = function() end },
    progressbar = { isActive = function() return false end, start = function() return true end },
    notify = { send = function() end },
    lang = function(key) return key end,
}
env.CreateThread, env.Wait = function() end, function() end
env.GetInvokingResource = function() return nil end
env.GetCurrentResourceName = function() return 'kora_inventory' end
env.GetGameTimer = function() return 0 end
env.RegisterNetEvent = function(name, fn) clientNet[name] = fn end
env.AddEventHandler = function(name, fn) clientEvents[name] = fn end
env.TriggerEvent = function(name, ...) end
env.TriggerServerEvent = function(name, ...) serverCalls[#serverCalls + 1] = { name = name, args = { ... } } end
env.SetTimeout = function(ms, fn) timers[#timers + 1] = { ms = ms, fn = fn } end
env.promise = { new = function()
    local p = {}
    function p:resolve(value) self.value, self.done = value, true if self.waiter then coroutine.resume(self.waiter) end end
    return p
end }
env.Citizen = { Await = function(p)
    if not p.done then p.waiter = coroutine.running() coroutine.yield() end
    return p.value
end }
assert(loadfile('client.lua', 't', env))()

clientNet['qbinventory:client:sessionOpened']({
    token = 'T',
    primary = { key = 'player:1', items = {}, revision = 3 },
    secondary = { key = 'stash:a', items = {}, revision = 5 },
})
local submit = env.QbInventory.clientApi.submitIntent
local function run(intent)
    local result
    local routine = coroutine.create(function() result = table.pack(submit(intent)) end)
    assert(coroutine.resume(routine))
    return routine, function() return result end
end
local move = { sessionId = 'T', token = 'T', intent = 'move', payload = { fromInventory = 'stash:a', toInventory = 'player:1', fromSlot = 1, toSlot = 2, amount = 1 } }

local routine, result = run(move)
H.equal(#serverCalls, 1, 'a move is sent as one net event')
H.equal(serverCalls[1].name, 'qbinventory:server:call', 'on the direct event')
H.equal(serverCalls[1].args[2], 'transfer', 'as a transfer')
H.equal(serverCalls[1].args[3].fromRevision, 5, 'carrying the source revision from the client mirror')
H.equal(serverCalls[1].args[3].toRevision, 3, 'and the destination revision')
H.equal(#legacyCalls, 0, 'kora_lib callbacks are not involved')
H.equal(result(), nil, 'the caller waits for the verdict')
clientNet['qbinventory:client:callResult'](serverCalls[1].args[1], true, { fromRevision = 6 })
H.equal(result()[1], true, 'the verdict resumes the caller')
H.equal(result()[2].fromRevision, 6, 'with the server result')

serverCalls = {}
routine, result = run(move)
clientNet['qbinventory:client:callResult'](serverCalls[1].args[1], false, 'over weight')
H.equal(result()[1], false, 'a refusal comes back as false')
H.equal(result()[2], 'over weight', 'with the reason')

-- A verdict for a request nobody waits on, or answered twice, is ignored.
clientNet['qbinventory:client:callResult'](999, true)
clientNet['qbinventory:client:callResult'](serverCalls[1].args[1], true)
H.equal(result()[1], false, 'a repeated verdict does not rewrite the first')

-- No verdict at all: the deadline resolves the wait.
serverCalls, timers = {}, {}
routine, result = run(move)
H.equal(timers[#timers].ms, 30000, 'a request that is never answered gives up after 30 s')
timers[#timers].fn()
H.equal(result()[1], false, 'a silent server resolves as a failure')
H.equal(result()[2], 'timeout', 'a timeout')

-- Intents (sync) take the intent action.
serverCalls = {}
routine, result = run({ sessionId = 'T', token = 'T', intent = 'sync', payload = {} })
H.equal(serverCalls[1].args[2], 'intent', 'sync travels as an intent')
H.equal(serverCalls[1].args[3].action, 'sync', 'with its action')
clientNet['qbinventory:client:callResult'](serverCalls[1].args[1], true)

-- The fallback.
env.Config.qbinventory.ui.directTransport = false
serverCalls = {}
routine, result = run(move)
H.equal(#serverCalls, 0, 'with the option off nothing is sent on the direct event')
H.equal(legacyCalls[1].name, 'qbinventory:server:transfer', 'the kora_lib callback carries the request instead')
H.equal(result()[2], 'legacy', 'and its answer is returned unchanged')

H.finish()
