-- Run from kora_inventory with sibling kora_core: lua5.4 test/smoke/session_activity.lua [server-source]
-- A session that is being used must not expire under the player's hands (the
-- drag "lockout" that ended in a forced close), an idle one still does, and the
-- browser's resync request answers politely instead of being ignored.
local core = '../kora_core/'
local H = dofile('test/harness.lua')
dofile(core .. 'test/mocks.lua').install()
for _, path in ipairs({
    'config.lua', 'shared/items.lua', 'shared/jobs.lua', 'shared/gangs.lua',
    'shared/vehicles.lua', 'shared/weapons.lua', 'shared/locations.lua',
    'modules/util/shared.lua', 'modules/registry/shared.lua', 'modules/registry/server.lua',
    'modules/player/shared.lua', 'modules/replication/server.lua',
    'modules/persistence/server.lua', 'modules/player/server.lua',
}) do dofile(core .. path) end
local player = 14
local cid = 'ACTIVITY_' .. player
assert(Core.player.login(player, cid, CoreInternal.player.freshData(cid, 'license:' .. cid, 1, { firstname = cid, lastname = 'Test' })))

local env = {}
for name, value in pairs(_G) do env[name] = value end
env.Config, env.QbInventory = {}, nil
local callbacks, events = {}, {}
-- The framework table is spelled differently across the rename; the code under
-- test only needs it to exist.
local framework = {
    resources = { serverRegistry = function() return { track = function() end, untrack = function() end } end },
    callback = { register = function(name, fn) callbacks[name] = fn end },
    compat = { provideExport = function() end },
    sql = {},
    distance = { player = function() return true end },
}
env.Kora, env.QB = framework, framework
env.GetCurrentResourceName = function() return 'kora_inventory' end
env.GetInvokingResource = function() return nil end
env.CreateThread, env.RegisterCommand = function() end, function() end
env.RegisterNetEvent, env.AddEventHandler, env.TriggerEvent = function() end, function() end, function() end
env.TriggerClientEvent = function(name, src, ...) events[#events + 1] = { name = name, source = src, args = { ... } } end
local clock = 1000
env.GetGameTimer = function() return clock end
env.GetPlayerPed = function(src) return src end
env.GetEntityCoords = function() return { x = 0, y = 0, z = 0 } end
env.GetPlayerRoutingBucket = function() return 0 end
local resourceExports = { kora_core = {} }
resourceExports.kora_core.getPlayerData = function(_, ...) return Core.player.getPlayerData(...) end
resourceExports.kora_core.getShared = function(_, ...) return Core.registry.getShared(...) end
resourceExports.kora_core.allShared = function(_, ...) return Core.registry.allShared(...) end
resourceExports.kora_core.setPath = function(_, ...) return Core.player.setPath(...) end
setmetatable(resourceExports, { __call = function() end })
env.exports = resourceExports
local function load(path) assert(loadfile(path, 't', env))() end
load('config.lua'); load('config/shops/ammunation.lua'); load('shared.lua')
load('server/persistence.lua'); load(arg[1] or 'server.lua')
local I = env.QbInventory
local ttl = env.Config.qbinventory.sessionTtl
H.equal(env.Config.qbinventory.sessionSliding, true, 'a session in use is renewed by default')

local stash = I.internal.createSecondary('stash', 'activity', {
    items = { [1] = assert(I.internal.buildItem('water_bottle', 40, 1, {})) },
})
local function open()
    clock = 1000
    local opened, lease = callbacks['qbinventory:server:open'](player, 'stash', stash.id)
    H.equal(opened, true, 'the session opens')
    return lease
end
-- One drag: take a single bottle out of the stash, with the revisions the last answer reported.
local function drag(lease, revisions)
    local ok, result = callbacks['qbinventory:server:transfer'](player, {
        token = lease.token, fromInventory = stash.key, toInventory = lease.primary.key, fromSlot = 1, amount = 1,
        fromRevision = revisions.from, toRevision = revisions.to,
    })
    if ok then revisions.from, revisions.to = result.fromRevision, result.toRevision end
    return ok, result
end

-- Active use: six drags 90 s apart outlive the 120 s lease several times over.
do
    local lease = open()
    local revisions = { from = lease.secondary.revision, to = lease.primary.revision }
    for step = 1, 6 do
        clock = clock + 90000
        local ok, reason = drag(lease, revisions)
        H.equal(ok, true, 'drag ' .. step .. ' after ' .. step * 90 .. 's of use is accepted (' .. tostring(reason) .. ')')
    end
    H.equal(stash.items[1].amount, 34, 'every drag took effect')
    -- Then it sits idle past the lease and is closed, with a reason rather than silence.
    clock = clock + ttl + 1
    local ok, reason = drag(lease, revisions)
    H.equal(ok, false, 'an idle session still expires')
    H.equal(reason, 'session expired', 'and says why')
end

-- A refused request (stale revision) still counts as use of the session.
do
    local lease = open()
    clock = clock + 100000
    local ok, reason = drag(lease, { from = lease.secondary.revision + 7, to = lease.primary.revision })
    H.equal(ok, false, 'stale revision is refused')
    H.equal(reason, 'stale source inventory', 'with the stale reason')
    clock = clock + 100000
    local synced = callbacks['qbinventory:server:intent'](player, { token = lease.token, action = 'sync' })
    H.equal(synced, true, 'the session survived because the refused request renewed it')
end

-- The hard-limit behaviour is still available.
do
    env.Config.qbinventory.sessionSliding = false
    local lease = open()
    local revisions = { from = lease.secondary.revision, to = lease.primary.revision }
    clock = clock + 90000
    H.equal(drag(lease, revisions), true, 'first drag inside the limit')
    clock = clock + 90000
    local ok, reason = drag(lease, revisions)
    H.equal(ok, false, 'with sliding off the lease ends ' .. ttl / 1000 .. 's after opening even in use')
    H.equal(reason, 'session expired', 'with the expiry reason')
    env.Config.qbinventory.sessionSliding = true
end

-- Resync: the browser asks for the real state after a failed or unanswered move.
do
    local lease = open()
    for i = #events, 1, -1 do events[i] = nil end
    local ok, result = callbacks['qbinventory:server:intent'](player, { token = lease.token, action = 'sync' })
    H.equal(ok, true, 'sync is accepted')
    H.equal(result, nil, 'with nothing but success to report')
    local patched = {}
    for _, event in ipairs(events) do
        if event.name == 'qbinventory:client:sessionPatched' then
            H.equal(event.source, player, 'patches go to the asking player only')
            H.equal(event.args[1], lease.token, 'tagged with the session token')
            patched[event.args[2].key] = event.args[2].revision
        end
    end
    H.equal(patched[lease.primary.key] ~= nil, true, 'the player inventory is re-sent')
    H.equal(patched[stash.key] ~= nil, true, 'and the secondary inventory')
    local before = #events
    callbacks['qbinventory:server:intent'](player, { token = lease.token, action = 'sync' })
    H.equal(#events, before, 'a repeat inside the throttle window re-sends nothing but still succeeds')
    clock = clock + 500
    callbacks['qbinventory:server:intent'](player, { token = lease.token, action = 'sync' })
    H.equal(#events > before, true, 'a later request is served again')

    local bad, reason = callbacks['qbinventory:server:intent'](player, { token = 'wrong', action = 'sync' })
    H.equal(bad, false, 'a wrong token is refused')
    H.equal(type(reason), 'string', 'with a reason, not silence')
    local none, why = callbacks['qbinventory:server:intent'](99, { token = lease.token, action = 'sync' })
    H.equal(none, false, 'a player with no session is refused')
    H.equal(why, 'invalid session', 'politely')
    local mixed, text = callbacks['qbinventory:server:intent'](player, { token = lease.token, action = 'nonsense' })
    H.equal(mixed, false, 'an unknown action is refused')
    H.equal(text, 'unsupported intent', 'with a reason')
end

-- The bridge lets the browser send it and never hands it a blank reason.
local function read(path) local f = assert(io.open(path, 'r')); local s = f:read('*a'); f:close(); return s end
H.ok(read('client/ui.lua'):find('sync = true,', 1, true), 'the NUI bridge allows the sync intent')
local client = read('client.lua')
H.ok(client:find("action == 'sync'", 1, true), 'the client transport forwards the sync intent to the server')
H.ok(select(2, client:gsub("result or 'inventory request failed'", '')) == 2, 'both transport paths give a rejection a reason when the callback returns none')

H.finish()
