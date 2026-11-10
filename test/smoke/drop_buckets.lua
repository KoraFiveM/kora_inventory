-- Run from kora_inventory: lua test/smoke/drop_buckets.lua [inventory-resource]
-- Actual authority, adapters and Core writes; inert buckets, positions and transport.
local root = '../'
local resource = arg[1] or '.'
local env = {}
for name, value in pairs(_G) do env[name] = value end
local checks, writes = 0, 0
local function check(value, reason) assert(value, reason); checks = checks + 1 end
local callbacks, handlers, registered, clientEvents, threads = {}, {}, {}, {}, {}
local buckets = { [7] = 11, [8] = 22, [10] = 55 }
local positions = { [7] = { x = 0, y = 0, z = 0 }, [8] = { x = 0, y = 0, z = 0 }, [10] = { x = 0, y = 0, z = 0 } }
local function noop() end
env.Kora = {
    util = {}, compat = { isCallable = function(value) return type(value) == 'function' end },
    resources = { serverRegistry = function() return { track = noop, untrack = noop } end },
    callback = { register = function(name, callback) callbacks[name] = callback end },
    distance = { player = function(src, point, distance)
        local position = positions[src]
        return position and ((position.x - point.x)^2 + (position.y - point.y)^2 + (position.z - point.z)^2) <= distance^2
    end },
    sql = {},
}
env.Core = {
    util = {}, player = {}, money = {}, compat = {},
    persistence = { _markDirty = function() writes = writes + 1 end },
    replication = { _queueOp = noop },
}
env.CoreInternal = { player = { COLUMN_FOR = { items = 'inventory' } } }
env.GetCurrentResourceName = function() return 'kora_inventory' end
env.GetInvokingResource = function() return nil end
env.GetGameTimer = function() return 1000 end
env.GetPlayerRoutingBucket = function(src) return assert(buckets[tonumber(src)], 'unknown source bucket') end
env.GetPlayers = function() return { '7', '8', '10' } end
env.GetPlayerPed = function(src) return positions[src] and src or 0 end
env.GetEntityCoords = function(ped) return positions[ped] end
env.CreateThread = function(callback) threads[#threads + 1] = callback end
env.Wait = function(ms) return coroutine.yield(ms) end
env.RegisterCommand = noop
env.vector3 = function(x, y, z) return { x = x, y = y, z = z } end
env.AddEventHandler = function(name, callback)
    handlers[name] = handlers[name] or {}
    handlers[name][#handlers[name] + 1] = callback
end
env.RegisterNetEvent = env.AddEventHandler
env.TriggerEvent = function(name, ...)
    for _, callback in ipairs(handlers[name] or {}) do callback(...) end
end
env.TriggerClientEvent = function(name, target, ...)
    clientEvents[#clientEvents + 1] = { name = name, target = target, args = table.pack(...) }
end
assert(loadfile(root .. 'kora_lib/modules/util/shared.lua', 't', env))()
assert(loadfile(root .. 'kora_core/modules/util/shared.lua', 't', env))()
assert(loadfile(root .. 'kora_core/modules/player/server.lua', 't', env))()
assert(loadfile(resource .. '/config.lua', 't', env))()
assert(loadfile(resource .. '/shared.lua', 't', env))()
local water = { name = 'water_bottle', label = 'Water', weight = 500, type = 'item' }
local coreExports = {
    getShared = function(_, kind, name) return kind == 'items' and name == 'water_bottle' and water or nil end,
    allShared = function() return {} end,
    getPlayerData = function(_, ...) return env.Core.player.getPlayerData(...) end,
    setPath = function(_, ...) return env.Core.player.setPath(...) end,
}
env.exports = setmetatable({ kora_core = coreExports }, { __call = function(_, name, callback) registered[name] = callback end })
assert(loadfile(resource .. '/server.lua', 't', env))()
assert(loadfile(resource .. '/server/compat/qb_callbacks.lua', 't', env))()
assert(loadfile(resource .. '/server/compat/ox.lua', 't', env))()
local inventory, internal = env.KoraInventory, env.KoraInventory.internal
for _, src in ipairs({ 7, 8, 10 }) do
    env.CoreInternal.player.bySource[src] = {
        citizenid = 'CID' .. src,
        PlayerData = { citizenid = 'CID' .. src, name = 'Player ' .. src, items = {}, metadata = {} },
    }
end
local function seed(src, amount)
    check(inventory.api.AddItem(src, 'water_bottle', amount, 1, { origin = 'server', batch = src }), 'seed player items')
end
local function nativeDrop(src, amount)
    local ok, lease = callbacks['kora_inventory:server:open'](src, 'player', src)
    check(ok and lease.primary.key == 'player:' .. src, 'actual self lease opens')
    return callbacks['kora_inventory:server:intent'](src, {
        action = 'drop', token = lease.token, primaryRevision = lease.primary.revision,
        payload = { slot = 1, amount = amount, bucket = 22, coords = { x = 9999, y = 9999, z = 9999 } },
    })
end
local function includes(list, id)
    for _, entry in ipairs(list) do
        if tostring(entry.id) == tostring(id) then return true end
    end
    return false
end
local function eventSince(first, name, target, predicate)
    for index = first + 1, #clientEvents do
        local event = clientEvents[index]
        if event.name == name and event.target == target and (not predicate or predicate(event.args)) then
            return event
        end
    end
end
local function moveRequest(src, drop, amount)
    local session = assert(internal.sessionOf(src))
    return { token = session.token, fromInventory = drop.key, toInventory = 'player:' .. src,
        fromSlot = 1, amount = amount, fromRevision = internal.getRevision(drop.key),
        toRevision = internal.getRevision('player:' .. src) }
end
seed(7, 10)
local first = #clientEvents
local ok, id = nativeDrop(7, 4)
check(ok, 'native drop succeeds')
local drop = assert(internal.getInventory('drop:' .. id))
check(drop.bucket == 11 and drop.coords == positions[7], 'native drop uses server bucket/position')
check(drop.items[1].amount == 4 and drop.items[1].info.origin == 'server', 'contents remain server-owned')
check(env.Core.player.getPlayerData(7, { 'items', 1, 'amount' }) == 6, 'Core funnel removes the source quantity')
check(eventSince(first, 'kora_inventory:client:dropCreated', 7), 'matching player receives live create')
check(not eventSince(first, 'kora_inventory:client:dropCreated', -1)
    and not eventSince(first, 'kora_inventory:client:dropCreated', 8), 'scoped drop is not published to other buckets')
local access, reason = internal.canAccess(8, drop)
check(access == false and reason == 'different routing bucket', 'foreign bucket fails shared access')
check(not includes(callbacks['kora_inventory:server:drops'](8), id), 'native list omits foreign drops')
check(includes(callbacks['kora_inventory:server:drops'](7), id), 'native list includes matching drops')
local before = writes
check(not callbacks['kora_inventory:server:open'](8, 'drop', id), 'foreign open is refused')
check(not inventory.api.dropTake(8, id, 1, 1), 'foreign direct take is refused')
check(writes == before and drop.items[1].amount == 4, 'refused paths change no inventory')
check(inventory.api.dropTake(7, id, 1, 1), 'matching take still succeeds')
check(drop.items[1].amount == 3, 'matching take moves exactly one item')

-- A viewer's current bucket, rather than the lease's original one, is decisive.
buckets[8] = 11
check(callbacks['kora_inventory:server:open'](8, 'drop', id), 'new matching bucket can open')
local request = moveRequest(8, drop, 1)
buckets[8] = 22
before = writes
check(not callbacks['kora_inventory:server:transfer'](8, request), 'old lease cannot take after changing bucket')
check(writes == before and drop.items[1].amount == 3, 'old-lease refusal changes no inventory')
seed(8, 2)
buckets[8] = 11
local _, lease = callbacks['kora_inventory:server:open'](8, 'drop', id)
local deposit = { token = lease.token, fromInventory = 'player:8', toInventory = drop.key,
    fromSlot = 1, amount = 1, fromRevision = internal.getRevision('player:8'),
    toRevision = internal.getRevision(drop.key) }
buckets[8] = 22
before = writes
check(not callbacks['kora_inventory:server:transfer'](8, deposit), 'old lease cannot deposit after changing bucket')
check(writes == before and drop.items[1].amount == 3
    and env.Core.player.getPlayerData(8, { 'items', 1, 'amount' }) == 2, 'deposit refusal preserves both inventories')
check(callbacks['kora_inventory:server:open'](7, 'drop', id), 'owner bucket viewer opens')
buckets[7] = 44
first = #clientEvents
buckets[8] = 11
check(inventory.api.dropTake(8, id, 1, 1), 'other matching viewer takes normally')
check(not eventSince(first, 'kora_inventory:client:sessionPatched', 7, function(args)
    return args[2].key == drop.key
end), 'moved viewer receives no drop-content patches')

-- The existing cleanup thread refreshes bags and closes a moved viewer's lease.
callbacks['kora_inventory:server:drops'](8)
buckets[8] = 22
local cleanup = coroutine.create(threads[#threads])
local function tick()
    local resumed, wait = coroutine.resume(cleanup)
    check(resumed and wait == 5000, 'existing cleanup keeps its five-second interval')
end
tick()
first = #clientEvents
tick()
check(internal.sessionOf(8) == nil, 'cleanup closes moved drop viewer')
local refresh = eventSince(first, 'kora_inventory:client:dropsUpdated', 8)
check(refresh and not includes(refresh.args[1], id), 'bucket change sends filtered bag replacement')
check(eventSince(first, 'kora_inventory:client:dropsUpdated', 7), 'live-create recipient is tracked before hydration')
first = #clientEvents
tick()
check(#clientEvents == first, 'unchanged buckets generate no refresh traffic')

check(callbacks['kora_inventory:server:open'](7, 'player', 7), 'legacy caller has a normal own lease')
local legacyId = callbacks['qb-inventory:server:createDrop'](7, { fromSlot = 1, amount = 1, instance = 22 })
check(legacyId and internal.getInventory('drop:' .. legacyId).bucket == 44, 'legacy drop ignores forged instance')
check(callbacks['qb-inventory:server:GetCurrentDrops'](8)[tostring(legacyId)] == nil, 'legacy list filters foreign drops')
check(callbacks['qb-inventory:server:GetCurrentDrops'](7)[tostring(legacyId)] ~= nil, 'foreign listing does not prune valid drops')
check(not inventory.api.OpenInventory(8, legacyId, { type = 'drop', id = legacyId }), 'legacy open uses the same bucket guard')

seed(10, 2)
local copiedId = inventory.compat.ox.CreateDropFromPlayer(10)
local copied = assert(internal.getInventory('drop:' .. copiedId))
check(copied.bucket == 55 and not internal.canAccess(8, copied), 'adapter player drop is bucket-bound')
check(env.Core.player.getPlayerData(10, { 'items', 1 }) == nil and copied.items[1].amount == 2,
    'adapter still copies and clears exactly once')
local customId = inventory.compat.ox.CustomDrop('loot', {}, positions[7], 5, 10000, 11)
local custom = assert(internal.getInventory('drop:' .. customId))
check(custom.bucket == 11 and custom.slots == 5 and custom.maxWeight == 10000, 'trusted instance and dimensions retained')
check(not internal.canAccess(8, custom), 'CustomDrop instance restricts access')
buckets[8] = 11
check(internal.canAccess(8, custom), 'matching CustomDrop instance permits access')

-- Trusted two-argument calls, bucket zero, and the existing opt-out stay compatible.
first = #clientEvents
local globalId = inventory.api.dropCreate(positions[7], {})
check(internal.canAccess(10, internal.getInventory('drop:' .. globalId)), 'two-argument trusted drops stay global')
check(eventSince(first, 'kora_inventory:client:dropCreated', -1), 'global trusted drop keeps global live event')
local falseId = inventory.api.dropCreate(positions[7], {}, false)
check(internal.getInventory('drop:' .. falseId).bucket == nil, 'false preserves unscoped trusted calls')
local falseCustom = inventory.compat.ox.CustomDrop('loot', {}, positions[7], 5, 10000, false)
check(internal.canAccess(10, internal.getInventory('drop:' .. falseCustom)), 'false CustomDrop instance stays unscoped')
buckets[10] = 0
local zeroId = inventory.api.dropCreate(positions[7], {}, 0)
check(internal.canAccess(10, internal.getInventory('drop:' .. zeroId))
    and not internal.canAccess(8, internal.getInventory('drop:' .. zeroId)), 'bucket zero is a real boundary')
-- A live bag before first hydration must be removed if that player already moved.
first = #clientEvents
buckets[10] = 99
local list = callbacks['kora_inventory:server:drops'](10)
check(not includes(list, zeroId) and eventSince(first, 'kora_inventory:client:dropsUpdated', 10),
    'hydration reconciles a bucket change since live creation')
env.Config.kora_inventory.requireSameBucket = false
check(internal.canAccess(10, drop) and includes(callbacks['kora_inventory:server:drops'](10), id), 'existing bucket opt-out is preserved')
first = #clientEvents
inventory.api.dropCreate(positions[7], {}, 11)
check(eventSince(first, 'kora_inventory:client:dropCreated', -1), 'bucket opt-out keeps global presentation')
positions[10] = { x = 100, y = 100, z = 100 }
check(not internal.canAccess(10, drop), 'bucket opt-out does not disable distance')
env.source = 10
handlers.playerDropped[#handlers.playerDropped]()
first = #clientEvents
tick()
check(not eventSince(first, 'kora_inventory:client:dropsUpdated', 10), 'disconnected viewer is no longer refreshed')

-- Returning before cleanup must not retain bags seen during a brief visit.
env.Config.kora_inventory.requireSameBucket = true
buckets[7] = 44
callbacks['kora_inventory:server:drops'](7)
buckets[7] = 77
first = #clientEvents
local briefVisit = inventory.api.dropCreate(positions[7], {}, 77)
check(eventSince(first, 'kora_inventory:client:dropCreated', 7), 'brief visit receives matching live bag')
local anotherVisit = inventory.api.dropCreate(positions[7], {}, 77)
buckets[7] = 44
local returnedBag = inventory.api.dropCreate(positions[7], {}, 44)
first = #clientEvents
tick()
local replacement = eventSince(first, 'kora_inventory:client:dropsUpdated', 7)
check(replacement and not includes(replacement.args[1], briefVisit)
    and not includes(replacement.args[1], anotherVisit) and includes(replacement.args[1], returnedBag),
    'roundtrip cleanup removes brief-visit bags and retains current bags')
first = #clientEvents
tick()
check(#clientEvents == first, 'completed roundtrip refresh does not repeat')

-- Hydration can perform that same pending refresh before the cleanup tick.
buckets[7] = 77
local hydrateVisit = inventory.api.dropCreate(positions[7], {}, 77)
buckets[7] = 44
inventory.api.dropCreate(positions[7], {}, 44)
first = #clientEvents
callbacks['kora_inventory:server:drops'](7)
replacement = eventSince(first, 'kora_inventory:client:dropsUpdated', 7)
check(replacement and not includes(replacement.args[1], hydrateVisit), 'hydration preserves a pending roundtrip refresh')
first = #clientEvents
tick()
check(#clientEvents == first, 'hydration clears the pending refresh once')
print(('drop_buckets: %d actual-source checks passed; Core writes=%d'):format(checks, writes))
