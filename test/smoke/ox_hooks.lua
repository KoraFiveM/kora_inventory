-- ox registerHook parity against the real server.lua: payload.source, ox slot
-- tables and ids, swapItems actions (move/swap/stack/give/newdrop), buyItem
-- timing and rollback, createItem/craftItem/openShop/usingItem payloads, filters,
-- post-events and owner-scoped removeHooks.
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
local timers = {}
env.SetTimeout = function(_, fn) timers[#timers + 1] = fn end
local function flush() local run = timers timers = {} for _, fn in ipairs(run) do fn() end end
local invoker = nil
env.GetInvokingResource = function() return invoker end
local money, refunds = 100, 0
local coreExports = {
    removeMoney = function(_, _, _, amount) if money < amount then return false, 'insufficient funds' end money = money - amount return true end,
    getMoney = function() return money end,
    addMoney = function(_, _, _, amount, _, ignoreTax) money = money + amount refunds = refunds + 1 return true end,
    getShared = function(_, kind, name) return kind == 'items' and name == 'water_bottle' and water or nil end,
    allShared = function() return {} end,
    getPlayerData = function(_, ...) return env.Core.player.getPlayerData(...) end,
    setPath = function(_, ...) return env.Core.player.setPath(...) end,
}
env.exports = setmetatable({ kora_core = coreExports }, { __call = function(_, name, callback) registered[name] = callback end })
assert(loadfile(resource .. '/server.lua', 't', env))()
assert(loadfile(resource .. '/server/compat/qb_callbacks.lua', 't', env))()
assert(loadfile(resource .. '/server/compat/ox.lua', 't', env))()
local inventory, internal = env.QbInventory, env.QbInventory.internal
for _, src in ipairs({ 7, 8, 10 }) do
    env.CoreInternal.player.bySource[src] = {
        citizenid = 'CID' .. src,
        PlayerData = { citizenid = 'CID' .. src, name = 'Player ' .. src, items = {}, metadata = {} },
    }
end
for _, src in ipairs({ 7, 8, 10 }) do
    env.CoreInternal.player.bySource[src] = {
        citizenid = 'CID' .. src,
        PlayerData = { citizenid = 'CID' .. src, name = 'Player ' .. src, items = {}, metadata = {} },
    }
end
buckets[8] = 11
local api = inventory.api
local function lease(src, kind, id)
    local ok, l = callbacks['qbinventory:server:open'](src, kind, id)
    check(ok, 'open ' .. kind)
    return l
end

-- registerHook surface
invoker = 'ox_script'
local calls = {}
local function record(tag, verdict)
    return function(payload, src)
        calls[#calls + 1] = { tag = tag, payload = payload, src = src }
        return verdict
    end
end
local id1 = api.registerHook('swapItems', record('all'))
check(id1 == 'ox_script:swapItems:1', 'registerHook returns an ox style id')
check(api.registerHook('swapItems', record('x')) == 'ox_script:swapItems:2', 'ids count up per event')
check(not pcall(api.registerHook, 'swapItems', {}), 'a non-callable is still refused')
invoker = 'other_script'
api.removeHooks('ox_script:swapItems:2')
local _, _, h = internal.runHooks('swapItems', 7, { fromInventory = 7 })
check(#h.ids == 2, 'another resource cannot remove a hook it does not own')
invoker = 'ox_script'
api.removeHooks('ox_script:swapItems:2')
_, _, h = internal.runHooks('swapItems', 7, { fromInventory = 7 })
check(#h.ids == 1, 'the owner removes one hook by id')
api.registerHook('swapItems', record('x'))
api.removeHooks()
_, _, h = internal.runHooks('swapItems', 7, { fromInventory = 7 })
check(#h.ids == 0, 'removeHooks() with no id removes every hook of the caller')
check(h.payload.source == 7, 'runHooks stamps payload.source')

-- transfers: move / stack / swap
check(api.AddItem(7, 'water_bottle', 10, 1, { q = 1 }), 'seed')
check(api.registerStash('box', 'Box', 10, 100000), 'stash registered')
invoker = 'ox_script'
api.registerHook('swapItems', record('swap'))
local l = lease(7, 'stash', 'box')
local function move(fromKey, toKey, fromSlot, toSlot, amount)
    l = internal.sessionOf(7)
    return callbacks['qbinventory:server:transfer'](7, { token = l.token, fromInventory = fromKey, toInventory = toKey,
        fromSlot = fromSlot, toSlot = toSlot, amount = amount,
        fromRevision = internal.getRevision(fromKey), toRevision = internal.getRevision(toKey) })
end
calls = {}
check(move('player:7', 'stash:box', 1, 3, 4), 'move succeeds')
local p = calls[1].payload
check(calls[1].src == 7 and p.source == 7, 'source passed as payload.source and 2nd arg')
check(p.action == 'move', 'empty target is a move')
check(p.fromInventory == 7 and p.fromType == 'player', 'player id is the server id')
check(p.toInventory == 'box' and p.toType == 'stash', 'stash id is the bare name')
check(p.fromSlot.name == 'water_bottle' and p.fromSlot.count == 10 and p.fromSlot.slot == 1, 'fromSlot is an ox slot table')
check(p.fromSlot.metadata.q == 1 and p.fromSlot.weight == 5000, 'ox slot has metadata and weight')
check(p.toSlot == 3 and p.count == 4, 'empty toSlot stays a number')
check(p.fromKey == 'player:7' and p.toKey == 'stash:box', 'kora keys kept as extras')
flush()
calls = {}
check(move('player:7', 'stash:box', 1, 3, 2), 'stack succeeds')
check(calls[1].payload.action == 'stack', 'same item and metadata on the target is a stack')
check(calls[1].payload.toSlot.count == 4, 'occupied toSlot is a slot table')
api.AddItem(7, 'water_bottle', 1, 2, { q = 2 })
calls = {}
check(move('player:7', 'stash:box', 2, 3, 1), 'swap succeeds')
check(calls[1].payload.action == 'swap', 'different metadata onto an occupied slot is a swap')
check(calls[1].payload.toSlot.metadata.q == 1, 'swap toSlot carries the target metadata')

-- cancel: false cancels, nothing moves, post event sees success=false
api.removeHooks()
local posted = {}
local cancelId = api.registerHook('swapItems', function() return false end)
env.AddEventHandler(cancelId, function(success, payload) posted[#posted + 1] = { success = success, payload = payload } end)
local before = #api.GetInventory(7)
check(not move('player:7', 'stash:box', 1, 5, 1), 'a hook returning false cancels the transfer')
check(#api.GetInventory(7) == before, 'cancelled transfer moved nothing')
flush()
check(posted[1] and posted[1].success == false, 'cancel fires the post event with success=false')
api.removeHooks()

-- post event: success true after commit, hookId stripped
local seen
local postId = api.registerHook('swapItems', record('post'), { print = false })
env.AddEventHandler(postId, function(success, payload) seen = { success = success, hookId = payload.hookId } end)
posted = nil
local okm, errm = move('player:7', 'stash:box', 1, 6, 1)
check(okm, 'transfer with a post-event hook ' .. tostring(errm))
check(seen == nil, 'post event is deferred')
flush()
check(seen and seen.success == true and seen.hookId == nil, 'TriggerEvent(hookId, true, payload) after the action')
api.removeHooks()

-- filters
calls = {}
api.registerHook('swapItems', record('pat'), { inventoryFilter = { '^bo' } })
api.registerHook('swapItems', record('nomatch'), { inventoryFilter = { '^zzz' } })
api.registerHook('swapItems', record('map'), { inventoryFilter = { ['stash:box'] = true } })
api.registerHook('swapItems', record('item'), { itemFilter = { bandage = true } })
api.registerHook('swapItems', record('type'), { typeFilter = { player = true } })
api.registerHook('swapItems', record('typeStash'), { typeFilter = { stash = true } })
check(move('stash:box', 'player:7', 6, 7, 1), 'transfer for filters')
local tags = {}
for _, c in ipairs(calls) do tags[c.tag] = true end
check(tags.pat, 'ox pattern array matches the destination id')
check(not tags.nomatch, 'non matching pattern skips the hook')
check(tags.map, 'kora map form still matches kora keys')
check(not tags.item, 'itemFilter skips other items')
check(not tags.type, 'typeFilter checks fromType only (stash source)')
check(tags.typeStash, 'typeFilter matches fromType')
api.removeHooks()

-- first-party kora_* hooks keep kora keys in the id fields
invoker = 'kora_jobcreator'
calls = {}
api.registerHook('swapItems', record('legacy'), { typeFilter = { stash = true } })
check(move('player:7', 'stash:box', 7, 8, 1), 'transfer for legacy hook')
check(calls[1] and calls[1].payload.toInventory == 'stash:box', 'kora_* hooks still see kora keys')
check(calls[1].payload.fromSlot.name == 'water_bottle' and calls[1].payload.source == 7, 'but also the ox payload')
invoker = 'ox_script'
api.removeHooks()
invoker = 'kora_jobcreator'
api.removeHooks()
invoker = 'ox_script'

-- ground drop: move to newdrop with the drop id
calls = {}
api.registerHook('swapItems', record('drop'))
local sl = lease(7, 'player', 7)
local dropped, dropId = callbacks['qbinventory:server:intent'](7, { action = 'drop', token = sl.token,
    primaryRevision = sl.primary.revision, payload = { slot = 1, amount = 2 } })
check(dropped, 'drop succeeds')
p = calls[1].payload
check(p.toInventory == 'newdrop' and p.toType == 'drop' and p.action == 'move', 'ground drop is a move to newdrop')
check(p.dropId == dropId, 'hook sees the id the drop is created with')
check(p.fromInventory == 7 and p.fromSlot.name == 'water_bottle', 'drop fromSlot is an ox slot')
api.removeHooks()
-- a second drop at the same spot merges into the first bag instead of creating another
sl = lease(7, 'player', 7)
local merged, mergedId = callbacks['qbinventory:server:intent'](7, { action = 'drop', token = sl.token,
    primaryRevision = sl.primary.revision, payload = { slot = 1, amount = 1 } })
check(merged and mergedId == dropId, 'a nearby drop merges into the existing ground drop')
api.registerHook('swapItems', function(payload) return payload.toType ~= 'drop' and true or false end)
sl = lease(7, 'player', 7)
local count = #api.GetInventory(7)
local waterBefore = api.GetItemCount(7, 'water_bottle')
local denied = callbacks['qbinventory:server:intent'](7, { action = 'drop', token = sl.token,
    primaryRevision = internal.getRevision('player:7'), payload = { slot = 1, amount = 1 } })
-- the earlier drop is within mergeRadius, so this one is a move into that drop; hooks still see and can cancel it
check(not denied and #api.GetInventory(7) == count and api.GetItemCount(7, 'water_bottle') == waterBefore, 'a cancelled drop removes nothing')
api.removeHooks()

-- give
calls = {}
api.registerHook('swapItems', record('give'))
positions[8] = positions[7]
sl = lease(7, 'player', 7)
local gave = callbacks['qbinventory:server:intent'](7, { action = 'give', token = sl.token,
    primaryRevision = internal.getRevision('player:7'), payload = { slot = 1, amount = 1, target = 8 } })
check(gave, 'give succeeds')
p = calls[1].payload
check(p.action == 'give' and p.fromInventory == 7 and p.toInventory == 8, 'give uses server ids')
check(p.fromType == 'player' and p.toType == 'player' and p.fromSlot.name == 'water_bottle', 'give payload shape')
api.removeHooks()
api.registerHook('swapItems', function(payload) return payload.action ~= 'give' end)
sl = lease(7, 'player', 7)
local had = api.GetItemCount(8, 'water_bottle')
gave = callbacks['qbinventory:server:intent'](7, { action = 'give', token = sl.token,
    primaryRevision = internal.getRevision('player:7'), payload = { slot = 1, amount = 1, target = 8 } })
check(not gave and api.GetItemCount(8, 'water_bottle') == had, 'a hook can cancel a give')
api.removeHooks()

-- openInventory / openShop
calls = {}
api.registerHook('openInventory', record('open'))
lease(7, 'stash', 'box')
p = calls[1].payload
check(p.source == 7 and p.inventoryId == 'box' and p.inventoryType == 'stash', 'openInventory has source and ox id')
api.removeHooks()
api.registerHook('openInventory', function() return false end)
check(not callbacks['qbinventory:server:open'](7, 'stash', 'box'), 'openInventory false cancels')
api.removeHooks()

check(api.registerShop('gunshop', { label = 'Guns', slots = 5, currency = 'money',
    items = { { name = 'water_bottle', amount = 5, price = 10 } } }), 'shop registered')
calls = {}
api.registerHook('openShop', record('shop'))
local shopLease = lease(7, 'shop', 'gunshop')
p = calls[1].payload
check(p.source == 7 and p.shopId == 'gunshop' and p.shopType == 'gunshop' and p.label == 'Guns', 'openShop fires with ox fields')
check(p.items[1].name == 'water_bottle' and p.items[1].price == 10, 'openShop items are ox slots')
api.removeHooks()

-- buyItem: after payment succeeds, rolled back on cancel
local function buy(amount)
    local sh = lease(7, 'shop', 'gunshop')
    return callbacks['qbinventory:server:intent'](7, { action = 'buy', token = sh.token,
        primaryRevision = sh.primary.revision, secondaryRevision = sh.secondary.revision,
        payload = { slot = 1, amount = amount } })
end
calls = {}
api.registerHook('buyItem', record('buy'))
local owned = api.GetItemCount(7, 'water_bottle')
check(buy(2), 'purchase succeeds')
p = calls[1].payload
check(p.source == 7 and p.shopType == 'gunshop' and p.shopId == 'gunshop', 'buyItem shop fields')
check(p.toInventory == 7 and p.itemName == 'water_bottle' and p.count == 2, 'buyItem destination and item')
check(p.price == 10 and p.totalPrice == 20 and p.currency == 'money', 'buyItem price fields')
check(p.fromSlot.name == 'water_bottle' and p.fromSlot.price == 10 and p.fromSlot.currency == 'money', 'buyItem fromSlot is the shop slot')
check(type(p.metadata) == 'table', 'buyItem metadata')
check(money == 80 and api.GetItemCount(7, 'water_bottle') == owned + 2, 'purchase charged and delivered')
api.removeHooks()
api.registerHook('buyItem', function() return false end)
refunds = 0
check(not buy(1), 'a buyItem hook can cancel')
check(money == 80 and refunds == 0 and api.GetItemCount(7, 'water_bottle') == owned + 2, 'cancel happens before any charge')
api.removeHooks()
local moneySeen
api.registerHook('buyItem', function() moneySeen = money end)
check(buy(1) and moneySeen == 80 and money == 70, 'buyItem hook runs before the payment is taken')
api.removeHooks()
money = 80
-- only false cancels for a non-kora owner; a string cancels for koraKeys mode
api.registerHook('buyItem', function() return 'nope' end)
check(buy(1), 'a string return does not cancel an ox owner hook')
api.removeHooks()
money = 80
api.registerHook('buyItem', function() return 'nope' end, { koraKeys = true })
check(not buy(1), 'a string return cancels in koraKeys mode')
api.removeHooks()
money = 0
calls = {}
api.registerHook('buyItem', record('poor'))
check(not buy(1) and #calls == 0, 'unaffordable purchase never reaches the hook')
api.removeHooks()
money = 100

-- usingItem
calls = {}
api.registerHook('usingItem', record('use'))
api.CreateUsableItem('water_bottle', function() end)
api.useItem(7, 'water_bottle')
check(#calls == 1, 'usingItem fires')
p = calls[1].payload
check(p.source == 7 and p.inventoryId == 7 and p.item.name == 'water_bottle', 'usingItem has source, id and slot table')
check(p.consume == 1 and p.inventoryType == 'player', 'usingItem has consume and type')
api.removeHooks()

-- createItem: false does not cancel, resource field
calls = {}
api.registerHook('createItem', function(payload) calls[#calls + 1] = payload return false end)
check(api.AddItem(7, 'water_bottle', 1), 'false does not cancel createItem')
check(calls[1].resource == 'ox_script' and calls[1].inventoryId == 7 and calls[1].item.name == 'water_bottle', 'createItem fields')
api.removeHooks()

print(('qbinventory smoke: %d passed, 0 failed'):format(checks))
