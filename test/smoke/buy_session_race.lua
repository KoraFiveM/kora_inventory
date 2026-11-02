-- Spam-buying while the inventory is closed/reopened must not produce stale
-- "invalid session" notices, a second error for one refused action, or two
-- buys racing each other on the wire.
local H = dofile("test/harness.lua")

local clientNet, clientEvents, serverCalls, rejected = {}, {}, {}, {}
local env = setmetatable({}, { __index = _G })
env.Config = { qbinventory = { ui = {} } }
env.QbInventory = {}
env.exports = setmetatable({}, { __call = function() end, __index = function()
    return setmetatable({}, { __index = function() return function() return nil end end })
end })
env.Kora = {
    callback = { trigger = function() return true end },
    compat = { provideExport = function() end },
    progressbar = { isActive = function() return false end, start = function() return true end },
    notify = { send = function() end },
    lang = function(key) return key end,
}
env.CreateThread, env.Wait = function() end, function() end
env.GetInvokingResource = function() return nil end
env.GetCurrentResourceName = function() return "kora_inventory" end
env.GetGameTimer = function() return 0 end
env.RegisterNetEvent = function(name, fn) clientNet[name] = fn end
env.AddEventHandler = function(name, fn) clientEvents[name] = fn end
env.TriggerEvent = function(name, payload)
    if name == "qbinventory:ui:rejected" then rejected[#rejected + 1] = payload.reason end
end
env.TriggerServerEvent = function(name, ...) serverCalls[#serverCalls + 1] = { name = name, args = { ... } } end
env.SetTimeout = function() end
env.promise = { new = function()
    local p = {}
    function p:resolve(value) self.value, self.done = value, true if self.waiter then coroutine.resume(self.waiter) end end
    return p
end }
env.Citizen = { Await = function(p)
    if not p.done then p.waiter = coroutine.running() coroutine.yield() end
    return p.value
end }
assert(loadfile("client.lua", "t", env))()

local function open(token)
    clientNet["qbinventory:client:sessionOpened"]({
        token = token,
        primary = { key = "player:1", items = {}, revision = 3 },
        secondary = { key = "shop:ammunation", items = {}, revision = 5 },
    })
end
local submit = env.QbInventory.clientApi.submitIntent
local function run(intent)
    local result
    local routine = coroutine.create(function() result = table.pack(submit(intent)) end)
    assert(coroutine.resume(routine))
    return function() return result end
end
local function buy(token, announce)
    return { sessionId = token, token = token, intent = "buy", announce = announce,
        payload = { inventory = "shop:ammunation", slot = 1, amount = 1 } }
end

-- One refusal, one verdict: the UI path reports it itself, so no toast too.
open("A")
local result = run(buy("A", false))
clientNet["qbinventory:client:callResult"](serverCalls[1].args[1], false, "insufficient funds")
H.equal(result()[2], "insufficient funds", "the refusal is returned to the UI")
H.equal(#rejected, 0, "and not announced a second time as a notification")

-- Third-party renderers (no announce flag) keep the notification.
serverCalls = {}
result = run(buy("A"))
clientNet["qbinventory:client:callResult"](serverCalls[1].args[1], false, "insufficient funds")
H.equal(rejected[1], "insufficient funds", "a renderer that does not announce itself still gets the notice")

-- Reopen while a buy is in flight: the late "invalid session" is not reported.
rejected, serverCalls = {}, {}
result = run(buy("A", false))
open("B")
clientNet["qbinventory:client:callResult"](serverCalls[1].args[1], false, "invalid session")
H.equal(result()[1], false, "the buy of the closed session fails")
H.equal(result()[2], "stale session", "as a stale session, not the invalid session of the server")
H.equal(#rejected, 0, "with no notification")

-- Closed while in flight, even for a renderer that announces.
rejected, serverCalls = {}, {}
result = run(buy("B"))
clientNet["qbinventory:client:sessionClosed"]("B", "requested")
clientNet["qbinventory:client:callResult"](serverCalls[1].args[1], false, "invalid session")
H.equal(#rejected, 0, "a verdict for a closed session raises nothing")

-- Buys go out one at a time; the second waits for the first verdict.
open("C")
serverCalls = {}
local first = run(buy("C", false))
local second = run(buy("C", false))
H.equal(#serverCalls, 1, "a second buy waits while one is in flight")
clientNet["qbinventory:client:callResult"](serverCalls[1].args[1], true, {})
H.equal(first()[1], true, "the first buy completes")
H.equal(#serverCalls, 2, "then the second is sent")
clientNet["qbinventory:client:callResult"](serverCalls[2].args[1], true, {})
H.equal(second()[1], true, "and completes")

-- A buy that waited behind a session change is dropped, not sent.
serverCalls = {}
first = run(buy("C", false))
second = run(buy("C", false))
open("D")
clientNet["qbinventory:client:callResult"](serverCalls[1].args[1], true, {})
H.equal(second()[2], "stale session", "a waiting buy of a replaced session is dropped")
H.equal(#serverCalls, 1, "without being sent")

H.finish()
