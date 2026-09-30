-- Run from qbinventory with sibling qbcore: lua5.4 test/smoke/confiscation.lua [server-source]
-- Actual authority, compatibility providers, shared rules and qbcore player
-- funnel. Only host transport/registration is mocked; no SQL or live server.
local core = '../qbcore/'
local H = dofile('test/harness.lua')
dofile(core .. 'test/mocks.lua').install()
for _, path in ipairs({
    'config.lua', 'shared/items.lua', 'shared/jobs.lua', 'shared/gangs.lua',
    'shared/vehicles.lua', 'shared/weapons.lua', 'shared/locations.lua',
    'modules/util/shared.lua', 'modules/registry/shared.lua', 'modules/registry/server.lua',
    'modules/player/shared.lua', 'modules/replication/server.lua',
    'modules/persistence/server.lua', 'modules/player/server.lua',
}) do dofile(core .. path) end
local victim, other = 12, 13
for _, src in ipairs({ victim, other }) do
    local cid = 'CONFISCATION_' .. src
    local data = CoreInternal.player.freshData(cid, 'license:' .. cid, 1, { firstname = cid, lastname = 'Test' })
    assert(Core.player.login(src, cid, data))
end

local env = {}
for name, value in pairs(_G) do env[name] = value end
env.Config, env.QbInventory = {}, nil
local net, callbacks, aliases, events, handlers = {}, {}, {}, {}, {}
env.QB = {
    resources = { serverRegistry = function() return { track = function() end, untrack = function() end } end },
    callback = { register = function(name, fn) callbacks[name] = fn end },
    compat = { provideExport = function(identity, name, fn) aliases[identity .. ':' .. name] = fn end },
    sql = {},
}
env.GetCurrentResourceName = function() return 'qbinventory' end
env.GetInvokingResource = function() return nil end
env.CreateThread, env.RegisterCommand = function() end, function() end
env.RegisterNetEvent = function(name, fn) net[name] = fn end
env.AddEventHandler = function(name, fn) handlers[name] = handlers[name] or {}; table.insert(handlers[name], fn) end
env.TriggerEvent = function() end
env.TriggerClientEvent = function(name, src, ...) events[#events + 1] = { name = name, source = src, args = { ... } } end
env.GetGameTimer = function() return 12345 end
local resourceExports = { qbcore = {} }
resourceExports.qbcore.getPlayerData = function(_, ...) return Core.player.getPlayerData(...) end
resourceExports.qbcore.getShared = function(_, ...) return Core.registry.getShared(...) end
resourceExports.qbcore.allShared = function(_, ...) return Core.registry.allShared(...) end
resourceExports.qbcore.setPath = function(_, ...) return Core.player.setPath(...) end
setmetatable(resourceExports, { __call = function() end })
env.exports = resourceExports
local function load(path) assert(loadfile(path, 't', env))() end
load('config.lua'); load('config/shops/ammunation.lua'); load('shared.lua')
load('server/persistence.lua'); load(arg[1] or 'server.lua')
load('server/compat/qb.lua'); load('server/compat/ox.lua'); load('server/compat/providers.lua')
local I = env.QbInventory
local confiscate = assert(aliases['ox_inventory:ConfiscateInventory'])
local restore = assert(aliases['ox_inventory:ReturnInventory'])
local function argc(...) return select('#', ...) end

local original = {
    [1] = assert(I.internal.buildItem('water_bottle', 4, 1, { serial = 'PRIVATE', quality = 83 })),
    [3] = assert(I.internal.buildItem('water_bottle', 2, 3, { serial = 'SECOND' })),
}
original[1].serverData = { case = 'trusted-only' }
original[1].quality = 83
assert(Core.player.setPath(victim, { 'items' }, original))
local expected = json.encode(Core.player.getPlayerData(victim, { 'items' }))
H.equal(argc(confiscate(victim)), 0, 'ConfiscateInventory keeps its no-return contract')
H.equal(next(Core.player.getPlayerData(victim, { 'items' })), nil, 'trusted confiscation clears qbcore-owned player items')
local _, confiscated = I.internal.resolveInventory('confiscation:' .. victim)
H.ok(confiscated, 'confiscated storage exists')
H.equal(json.encode(confiscated.items), expected, 'storage retains exact contents and metadata')
H.equal(I.persistence.shouldPersist(confiscated), false, 'existing volatile-storage policy is unchanged')

for _, src in ipairs({ victim, other }) do
    for _, data in ipairs({ tostring(victim), { key = confiscated.key }, { id = tostring(victim) } }) do
        local ok, err = callbacks['qbinventory:server:open'](src, 'confiscation', data)
        H.equal(ok, false, 'generic callback cannot open confiscated storage for source ' .. src)
        H.equal(err, 'access denied', 'callback uses normal access-denial return')
        H.equal(I.internal.sessionOf(src), nil, 'denied open creates no lease')
        env.source = src
        net['qbinventory:server:open']('confiscation', data)
        H.equal(events[#events].name, 'qbinventory:client:rejected', 'generic event rejects private storage')
        H.equal(I.internal.sessionOf(src), nil, 'event rejection creates no lease')
    end
end
H.equal(callbacks['qbinventory:server:open'](other, 'stash', { key = confiscated.key, owner = other, access = true }), false,
    'client type/policy fields cannot disguise the resolved confiscation record')
H.equal(I.internal.open(other, confiscated.key), false, 'trusted ordinary open follows the same policy')
H.equal(aliases['ox_inventory:forceOpenInventory'](other, 'confiscation', tostring(victim)), false, 'forceOpen alias retains authority gating')
H.equal(argc(aliases['ox_inventory:InspectInventory'](other, confiscated.key)), 0, 'InspectInventory retains its no-return contract')
H.equal(I.internal.sessionOf(other), nil, 'inspection alias cannot create a private-storage lease')
H.equal(aliases['qb-inventory:OpenInventory'](other, confiscated.key, { type = 'confiscation', id = victim }), false,
    'qb alias cannot open internal confiscation storage')

-- Existing records ignore newly supplied constructor options. Protection must
-- therefore hold even with no callback or with an old permissive callback.
confiscated.access = function() return true end
local reused = I.internal.createSecondary('confiscation', tostring(victim), { access = function() return false end })
H.equal(reused, confiscated, 'constructor reuses an existing record')
H.equal(I.internal.canAccess(other, reused), false, 'existing permissive record still denies access')

-- Establish a real lease with the common open path, then make its secondary
-- record private. This controlled policy-change fixture exercises transfer
-- revalidation; it is not a claim about a live FiveM hot-reload mechanism.
confiscated.type = 'stash'
local ok, session = callbacks['qbinventory:server:open'](other, 'stash', { key = confiscated.key })
H.equal(ok, true, 'controlled pre-policy lease exists')
confiscated.type = 'confiscation'
local returned, denied, denial = pcall(callbacks['qbinventory:server:transfer'], other, {
    token = session.token, fromInventory = session.secondary.key, toInventory = session.primary.key,
    fromSlot = 1, toSlot = 1, amount = 1,
    fromRevision = session.secondary.revision, toRevision = session.primary.revision,
})
H.equal(returned, true, 'revoked access returns normally')
H.equal(denied, false, 'revoked access rejects the transfer')
H.equal(denial, 'access denied', 'revoked access keeps the failure reason')
H.equal(I.internal.sessionOf(other), nil, 'revoked lease is closed')
H.equal(next(Core.player.getPlayerData(other, { 'items' })), nil, 'denied transfer adds no items')
H.equal(json.encode(confiscated.items), expected, 'denied transfer leaves exact storage contents')

-- The real bootstrap handler accepts restored secondary records directly.
-- Confiscation is currently NOT durable; inject its typed record only to pin
-- that missing runtime callbacks cannot reopen this private kind if restored.
I.persistence.restoreAll = function()
    local restored = I.copy(confiscated)
    restored.access = nil
    return { restored }, {}
end
for _, fn in ipairs(handlers['qbinventory:server:persistenceReady'] or {}) do fn() end
H.equal(callbacks['qbinventory:server:open'](other, 'confiscation', tostring(victim)), false,
    'a bootstrap-restored typed record without a callback still denies access')
H.equal(argc(restore(victim)), 0, 'ReturnInventory keeps its no-return contract')
H.equal(json.encode(Core.player.getPlayerData(victim, { 'items' })), expected, 'trusted ReturnInventory restores exact original items')
H.equal(select(2, I.internal.resolveInventory(confiscated.key)), nil, 'trusted return removes private storage')
H.equal(argc(restore(victim)), 0, 'missing confiscation return stays a no-op')
H.equal(argc(confiscate('invalid')), 0, 'invalid confiscation source stays a no-op')
-- Rejections must leave inventory values nil to every validator consumer.
local clock = 12345
env.GetGameTimer = function() return clock end
env.GetPlayerPed = function(src) return src end
env.GetEntityCoords = function() return { x = 0, y = 0, z = 0 } end
env.GetPlayerRoutingBucket = function() return 0 end
env.QB.distance = { player = function() return true end }
local stash = I.internal.createSecondary('stash', 'session-rejection', {
    items = { [1] = assert(I.internal.buildItem('water_bottle', 2, 1, {})) },
})
for _, rejection in ipairs({ 'token', 'key', 'fromRevision', 'toRevision', 'expiry' }) do
    clock = 12345
    local opened, lease = callbacks['qbinventory:server:open'](other, 'stash', stash.id)
    H.equal(opened, true, 'rejection fixture opens a real lease')
    local request = { token = lease.token, fromInventory = stash.key, toInventory = lease.primary.key,
        fromSlot = 1, amount = 1, fromRevision = lease.secondary.revision, toRevision = lease.primary.revision }
    local expectedReason
    if rejection == 'token' then request.token = 'invalid'; expectedReason = 'invalid session'
    elseif rejection == 'key' then request.fromInventory = 'stash:outside'; expectedReason = 'inventory not in session'
    elseif rejection == 'fromRevision' then request.fromRevision = request.fromRevision + 1; expectedReason = 'stale source inventory'
    elseif rejection == 'toRevision' then request.toRevision = request.toRevision + 1; expectedReason = 'stale target inventory'
    else clock = clock + env.Config.qbinventory.sessionTtl + 1; expectedReason = 'session expired' end
    local normal, accepted, reason = pcall(callbacks['qbinventory:server:transfer'], other, request)
    H.equal(normal, true, rejection .. ' returns normally')
    H.equal(accepted, false, rejection .. ' rejects')
    H.equal(reason, expectedReason, rejection .. ' keeps the reason')
    H.equal(stash.items[1].amount, 2, rejection .. ' removes no stash items')
    H.equal(next(Core.player.getPlayerData(other, { 'items' })), nil, rejection .. ' adds no player items')
end
clock = 12345
for _, action in ipairs({ 'use', 'drop', 'give' }) do
    local _, lease = callbacks['qbinventory:server:open'](victim, 'player', victim)
    local normal, accepted, reason = pcall(callbacks['qbinventory:server:intent'], victim, {
        token = lease.token, action = action, primaryRevision = lease.primary.revision + 1,
        payload = { slot = 1, amount = 1, target = other },
    })
    H.equal(normal, true, action .. ' stale validation returns normally')
    H.equal(accepted, false, action .. ' stale validation rejects')
    H.equal(reason, 'stale inventory', action .. ' retains its existing rejection text')
    H.equal(json.encode(Core.player.getPlayerData(victim, { 'items' })), expected, action .. ' changes no items')
end
local shop = I.internal.createSecondary('shop', 'session-rejection', { stock = stash.items })
local _, lease = callbacks['qbinventory:server:open'](victim, 'shop', shop.id)
local normal, accepted, reason = pcall(callbacks['qbinventory:server:intent'], victim, {
    token = lease.token, action = 'buy', primaryRevision = lease.primary.revision,
    secondaryRevision = lease.secondary.revision + 1, payload = { slot = 1, amount = 1 },
})
H.equal(normal, true, 'buy stale validation returns normally')
H.equal(accepted, false, 'buy stale validation rejects')
H.equal(reason, 'stale source inventory', 'buy retains the validator failure reason')
H.equal(shop.stock[1].amount, 2, 'rejected buy changes no stock')
H.equal(json.encode(Core.player.getPlayerData(victim, { 'items' })), expected, 'rejected buy changes no player items')
H.finish()
