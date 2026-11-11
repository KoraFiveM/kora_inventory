-- Run from kora_inventory: lua test/smoke/drops_client.lua [client-source]
-- Actual client code; model/callback waits and all host effects are controlled.
local H = dofile('test/harness.lua')
local function setup()
    local f = { events = {}, threads = {}, zones = {}, entities = {}, removedZones = {}, removedEntities = {}, opened = {} }
    local env = {}
    for key, value in pairs(_G) do env[key] = value end
    env.Config = { kora_inventory = { drops = { placeOnGround = false } } }
    env.GetCurrentResourceName = function() return 'kora_inventory' end
    env.GetInvokingResource = function() return f.invoker end
    env.NetworkIsSessionStarted = function() return true end
    env.Wait = function(ms) return coroutine.yield(ms) end
    env.CreateThread = function(fn) f.threads[#f.threads + 1] = coroutine.create(fn) end
    env.RegisterNetEvent = function(name, cb) f.events[name] = cb end
    env.AddEventHandler = function(name, cb) f.events[name] = cb end
    local nextZone, nextEntity = 0, 0
    env.exports = {
        kora_target = {
            addSphereZone = function(_, options)
                nextZone = nextZone + 1; f.zones[nextZone] = options; return nextZone
            end,
            removeZone = function(_, id)
                H.ok(f.zones[id], 'removed zone is live')
                f.zones[id] = nil; f.removedZones[#f.removedZones + 1] = id
            end,
        },
        kora_inventory = { openInventory = function(_, kind, id) f.opened[#f.opened + 1] = { kind = kind, id = id } end },
    }
    env.Kora = {
        entities = {
            create = function(model, coords, options)
                H.equal(model, 'prop_med_bag_01b'); H.equal(options.freeze, true)
                if f.holdModels then coroutine.yield('model') end
                nextEntity = nextEntity + 1; f.entities[nextEntity] = coords; return nextEntity
            end,
            remove = function(id)
                H.ok(f.entities[id], 'removed entity is live')
                f.entities[id] = nil; f.removedEntities[#f.removedEntities + 1] = id
            end,
        },
        callback = { trigger = function(name)
            H.equal(name, 'kora_inventory:server:drops')
            return coroutine.yield('hydrate')
        end },
    }
    assert(loadfile(arg[1] or 'client/drops.lua', 't', env))()
    function f.resume(co, value)
        local ok, result = coroutine.resume(co, value); assert(ok, result); return result
    end
    function f.emit(name, ...)
        local callback = assert(f.events['kora_inventory:client:' .. name], 'missing ' .. name .. ' handler')
        local args = { ... }
        local co = coroutine.create(function() callback(table.unpack(args)) end)
        f.resume(co)
        H.equal(coroutine.status(co), 'dead', 'drop event reconciliation does not await models')
    end
    function f.models()
        for index = 2, #f.threads do
            if coroutine.status(f.threads[index]) ~= 'dead' then
                f.resume(f.threads[index])
                H.equal(coroutine.status(f.threads[index]), 'dead', 'unblocked model completes once')
            end
        end
    end
    function f.hydrate()
        H.equal(f.resume(f.threads[1]), 1000, 'existing startup handshake delay remains')
        H.equal(f.resume(f.threads[1]), 'hydrate', 'callback response held')
        return f.threads[1]
    end
    return f
end
local function count(values) local n = 0; for _ in pairs(values) do n = n + 1 end; return n end
local a, b, c = { x = 1, y = 2, z = 3 }, { x = 4, y = 5, z = 6 }, { x = 7, y = 8, z = 9 }

-- Full snapshots add/remove bags, clean props+targets, and tolerate duplicates.
do
    local f = setup()
    f.holdModels = true
    f.emit('dropsUpdated', { { id = 1, coords = a }, { id = 2, coords = b } })
    H.equal(count(f.zones), 2, 'snapshot registers all targets before model waits')
    H.equal(count(f.entities), 0, 'entity creation is deferred')
    f.holdModels = false; f.models()
    H.equal(count(f.entities), 2)
    local threadCount = #f.threads
    f.emit('dropCreated', '1', a)
    f.emit('dropsUpdated', { { id = '1', coords = a }, { id = 2, coords = b } })
    H.equal(#f.threads, threadCount, 'duplicate events schedule no extra props')
    H.equal(count(f.zones), 2)
    f.emit('dropsUpdated', { { id = 2, coords = b }, { id = 3, coords = c } })
    H.equal(#f.removedZones, 1); H.equal(#f.removedEntities, 1)
    f.models(); H.equal(count(f.entities), 2); H.equal(count(f.zones), 2)
    for _, zone in pairs(f.zones) do
        if zone.coords == c then zone.options[1].onSelect() end
    end
    H.equal(f.opened[1].kind, 'drop'); H.equal(f.opened[1].id, '3', 'target uses server drop id')
    f.emit('dropsUpdated', {})
    H.equal(count(f.zones), 0); H.equal(count(f.entities), 0)
    H.equal(#f.removedZones, 3); H.equal(#f.removedEntities, 3)
    f.emit('dropRemoved', 1); f.emit('dropsUpdated', {})
    H.equal(#f.removedZones, 3); H.equal(#f.removedEntities, 3, 'duplicate cleanup removes nothing twice')
end

-- An old model completion must not attach to a replacement with the same id.
do
    local f = setup(); f.holdModels = true
    f.emit('dropCreated', 'race', a)
    H.equal(f.resume(f.threads[2]), 'model')
    f.emit('dropRemoved', 'race')
    f.emit('dropCreated', 'race', b)
    H.equal(f.resume(f.threads[3]), 'model')
    f.resume(f.threads[3])
    H.equal(count(f.entities), 1)
    f.resume(f.threads[2])
    H.equal(count(f.entities), 1, 'old completion deletes its own orphan prop')
    H.equal(#f.removedEntities, 1)
    for _, coords in pairs(f.entities) do H.equal(coords, b, 'replacement prop survives') end
    f.emit('dropRemoved', 'race')
    H.equal(count(f.entities), 0); H.equal(count(f.zones), 0)
    H.equal(#f.removedEntities, 2, 'replacement record owns the correct prop')
end

-- A newer bucket snapshot (including empty) invalidates an older hydration.
for _, visible in ipairs({ {}, { { id = 'current', coords = b } } }) do
    local f = setup(); local hydrate = f.hydrate()
    f.emit('dropsUpdated', visible); f.models()
    f.resume(hydrate, { { id = 'old-bucket', coords = a } }); f.models()
    H.equal(count(f.zones), #visible, 'stale hydration cannot restore prior-bucket targets')
    H.equal(count(f.entities), #visible, 'stale hydration cannot restore prior-bucket props')
    for _, zone in pairs(f.zones) do H.equal(zone.coords, b) end
end

-- Hydration is add-only: a delayed response cannot delete a newer live bag.
do
    local f = setup(); local hydrate = f.hydrate()
    f.emit('dropCreated', 'new-live', b); f.models()
    f.resume(hydrate, { { id = 'existing', coords = a } }); f.models()
    H.equal(count(f.zones), 2, 'hydration keeps live additions outside its earlier list')
    H.equal(count(f.entities), 2)
    f.emit('dropRemoved', 'new-live'); f.emit('dropRemoved', 'existing')
    H.equal(count(f.zones), 0); H.equal(count(f.entities), 0)
end

-- Preserve the local-invocation guard on every presentation event.
do
    local f = setup(); f.emit('dropCreated', 1, a); f.models()
    f.invoker = 'other-resource'
    f.emit('dropCreated', 2, b); f.emit('dropRemoved', 1); f.emit('dropsUpdated', {})
    H.equal(count(f.zones), 1); H.equal(count(f.entities), 1)
    f.invoker = nil; f.emit('dropRemoved', 1)
    H.equal(count(f.zones), 0); H.equal(count(f.entities), 0)
end
H.finish()
