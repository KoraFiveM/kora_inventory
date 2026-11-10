-- qb-inventory parity against the real server.lua: stock AddItem/RemoveItem
-- identifiers, hooks and listeners, reader exports and the legacy open/use events.
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
assert(loadfile(resource .. '/server/compat/qb.lua', 't', env))()
assert(loadfile(resource .. '/server/compat/qb_hooks.lua', 't', env))()
assert(loadfile(resource .. '/server/compat/qb_events.lua', 't', env))()
local inventory, internal = env.KoraInventory, env.KoraInventory.internal
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

local qb = inventory.compat.qb
local invoker2
check(api.registerStash('box', 'Box', 10, 100000), 'stash registered')
check(api.registerStash('locked', 'Locked', 5, 100000, nil, { police = 0 }), 'group stash registered')
check(api.registerStash('far', 'Far', 5, 100000, nil, nil, { x = 900, y = 0, z = 0 }), 'fixture stash registered')

-- AddItem / RemoveItem: player source and stash identifier, stock arg order
check(qb.AddItem(7, 'water_bottle', 4, nil, { q = 1 }, 'test') == true, 'AddItem to a player source')
check(qb.AddItem('box', 'water_bottle', 3, nil, { q = 1 }, 'test') == true, 'AddItem to a stash identifier')
check(internal.getInventory('stash:box').items[1].amount == 3, 'stash holds the item at the first free slot')
check(qb.AddItem('box', 'water_bottle', 2, 1, { q = 1 }) == true, 'AddItem stacks on an explicit slot')
check(internal.getInventory('stash:box').items[1].amount == 5, 'stacked amount')
check(qb.AddItem('box', 'water_bottle', 1, false, false) == true, 'false slot and info (stock snowball style) are accepted')
check(qb.AddItem('box', 'not_an_item', 1) == false, 'unknown item refused')
check(qb.AddItem('nostash', 'water_bottle', 1) == false, 'unknown inventory refused (stock does not create it)')
check(qb.AddItem('box', 'water_bottle', 1000) == false, 'over weight refused')
check(qb.AddItem('player:7', 'water_bottle', 1) == false, 'a raw player key string is not an identifier')
check(qb.AddItem('shop:x', 'water_bottle', 1) == false, 'shops are not writable here')
check(qb.RemoveItem('box', 'water_bottle', 2, 1, 'test') == true, 'RemoveItem from a stash with slot')
check(internal.getInventory('stash:box').items[1].amount == 3, 'removed amount')
check(qb.RemoveItem('box', 'water_bottle', 99) == false, 'removing more than held is refused')
check(internal.getInventory('stash:box').items[1].amount == 3, 'refused removal changed nothing')
check(qb.RemoveItem('box', 'water_bottle', 1, 9) == false, 'slot holding nothing refused')
check(qb.RemoveItem(7, 'water_bottle', 1, nil, 'test') == true, 'RemoveItem from a player source')
check(qb.RemoveItem('nostash', 'water_bottle', 1) == false, 'RemoveItem unknown inventory')
check(qb.RemoveItem('box', 'water_bottle', nil) == false, 'RemoveItem without amount is refused')
local rev = internal.getRevision('stash:box')
qb.AddItem('box', 'water_bottle', 1)
check(internal.getRevision('stash:box') == rev + 1, 'stash writes bump the revision')

-- trunk-/drop- identifiers resolve typed inventories, never other kinds
internal.createSecondary('trunk', 'ABC123', { slots = 5, maxWeight = 100000 })
check(qb.AddItem('trunk-ABC123', 'water_bottle', 1) == true, 'trunk- identifier writes the trunk')
check(internal.getInventory('trunk:ABC123').items[1].amount == 1, 'trunk holds it')
check(qb.AddItem('drop-ABC123', 'water_bottle', 1) == false, 'a prefix cannot reach another kind')
check(qb.AddItem('trunk-player:7', 'water_bottle', 1) == false, 'trunk- prefix cannot reach a player')
check(qb.GetSlots('trunk-ABC123') == 1, 'GetSlots understands the prefix')

-- hooks
local seen = {}
invoker = 'hook_script'
local addIdx = qb.AddHook('ItemAdded', function(kind, data)
    seen[#seen + 1] = { kind = kind, data = data }
    if data.reason == 'veto' then return false end
    if data.reason == 'mutate' then return { q = 99 } end
end)
check(addIdx == 1, 'AddHook returns an index')
check(qb.AddHook('Nope', function() end) == nil, 'invalid hook type refused')
check(qb.AddHook('ItemAdded', 5) == nil, 'non-callable refused')
local listened = {}
qb.AddListener('ItemAdded', function(kind, data) listened[#listened + 1] = data end)
check(qb.AddItem('box', 'water_bottle', 1, nil, nil, 'veto') == false, 'a hook returning false cancels AddItem')
check(#listened == 0, 'listener does not run for a cancelled add')
check(qb.AddItem('box', 'water_bottle', 1, nil, nil, 'mutate') == true, 'hook mutation add')
check(seen[2].kind == 'item' and seen[2].data.toId == 'box' and seen[2].data.toType == 'stash', 'hook receives (type, data) with toId/toType')
check(seen[2].data.amount == 1 and seen[2].data.item.name == 'water_bottle', 'hook data carries amount and item')
check(#listened == 1, 'listener runs after a committed add')
local found
for _, item in pairs(internal.getInventory('stash:box').items) do if item.info.q == 99 then found = true end end
check(found, 'a returned table replaces the item metadata')
qb.AddItem('box', 'water_bottle', 1, nil, nil, 'internal', true)
check(#seen == 2, 'isInternalMove suppresses the hook')
qb.RemoveHook('ItemAdded', addIdx)
qb.AddItem('box', 'water_bottle', 1, nil, nil, 'veto')
check(#seen == 2, 'RemoveHook stops the hook')

local removed = {}
qb.AddHook('ItemRemoved', function(kind, data) removed[#removed + 1] = data; if data.reason == 'veto' then return false end end)
check(qb.RemoveItem('box', 'water_bottle', 1, nil, 'veto') == false, 'ItemRemoved hook cancels')
check(qb.RemoveItem('box', 'water_bottle', 1, nil, 'ok') == true, 'ItemRemoved hook allows')
check(removed[2].fromId == 'box' and removed[2].amount == 1 and removed[2].fromType == 'stash', 'ItemRemoved data shape')
env.onStop = nil
env.TriggerEvent('onResourceStop', 'hook_script')
local before = #removed
qb.RemoveItem('box', 'water_bottle', 1, nil, 'veto')
check(#removed == before, 'hooks of a stopped resource are dropped')

-- engine bridged hooks: ItemUsed hook + listener, ItemMoved
local used, usedListener, moved, movedListener = {}, {}, {}, {}
invoker = 'hook_script2'
api.createUseable('water_bottle', function() end)
qb.AddHook('ItemUsed', function(kind, data) used[#used + 1] = { kind = kind, data = data }; if data.item.info.q == 7 then return false end end)
qb.AddListener('ItemUsed', function(kind, data) usedListener[#usedListener + 1] = data end)
qb.AddHook('ItemMoved', function(kind, data) moved[#moved + 1] = { kind = kind, data = data } end)
qb.AddListener('ItemMoved', function(kind, data) movedListener[#movedListener + 1] = { kind = kind, data = data } end)
qb.AddItem(7, 'water_bottle', 1, 5, { q = 7 })
local slotOfSeven
for slot, item in pairs(internal.getInventory('player:7').items) do if item.info.q == 7 then slotOfSeven = slot end end
check(api.useItem(7, slotOfSeven) == false, 'ItemUsed hook returning false cancels the use')
check(used[1].kind == 'item' and used[1].data.source == 7 and used[1].data.item.name == 'water_bottle', 'ItemUsed receives (type, data)')
qb.AddItem(7, 'water_bottle', 1, 6, { q = 8 })
check(api.useItem(7, 6) == true, 'uncancelled use proceeds')
flush()
check(#usedListener >= 1, 'ItemUsed listener runs after use')

local session = select(2, callbacks['kora_inventory:server:open'](7, 'stash', 'box'))
local okOpen = callbacks['kora_inventory:server:open'](7, 'stash', 'box')
check(okOpen, 'open stash')
local l = internal.sessionOf(7)
local function move(fromKey, toKey, fromSlot, toSlot, amount)
    l = internal.sessionOf(7)
    return callbacks['kora_inventory:server:transfer'](7, { token = l.token, fromInventory = fromKey, toInventory = toKey,
        fromSlot = fromSlot, toSlot = toSlot, amount = amount,
        fromRevision = internal.getRevision(fromKey), toRevision = internal.getRevision(toKey) })
end
check(move('player:7', 'stash:box', 6, 8, 1), 'move to stash')
check(moved[1].kind == 'moved' and moved[1].data.fromType == 'player' and moved[1].data.toType == 'inventory', 'ItemMoved moved: types map to stock names')
check(moved[1].data.fromId == 7 and moved[1].data.toId == 'box' and moved[1].data.toSlot == 8 and moved[1].data.fromSlot == 6, 'ItemMoved ids and slots')
check(type(moved[1].data.fromInventory.items) == 'table' and moved[1].data.toInventory.maxweight == 100000, 'ItemMoved carries inventory snapshots')
flush()
check(movedListener[1] and movedListener[1].kind == 'moved', 'ItemMoved listener runs after commit')
qb.AddItem(7, 'water_bottle', 5, 9)
check(move('player:7', 'stash:box', 9, 10, 2), 'partial move')
check(moved[#moved].kind == 'split', 'partial move is a split')

-- reader exports
check(qb.HasItem(7, 'water_bottle') == true, 'HasItem string')
check(qb.HasItem(7, { 'water_bottle' }) == true, 'HasItem array')
check(qb.HasItem(7, { 'water_bottle', 'bandage' }) == false, 'HasItem array needs every name')
check(qb.HasItem(7, { water_bottle = 1 }) == true, 'HasItem map met')
check(qb.HasItem(7, { water_bottle = 500 }) == false, 'HasItem map count not met')
check(qb.HasItem(7, { water_bottle = 1, bandage = 1 }) == false, 'HasItem map missing item')
check(qb.HasItem(7, {}) == false, 'HasItem empty table is false')
check(qb.HasItem(7, { 'water_bottle' }, 500) == false, 'HasItem array with amount')
qb.AddItem(7, 'water_bottle', 1, 20, { q = 20 })
check(qb.GetItemBySlot(7, '20').name == 'water_bottle', 'GetItemBySlot accepts a string slot')
check(qb.GetItemsByName(99, 'water_bottle') == nil and qb.GetItemCount(99, 'water_bottle') == nil, 'unknown player yields nil')
check(qb.GetFreeWeight(99) == 0 and qb.GetFreeWeight(nil) == 0, 'GetFreeWeight is 0 for an unknown player')
check(qb.GetFreeWeight(7) > 0, 'GetFreeWeight for a player')
check(qb.GetInventory('box').isOpen == 7, 'GetInventory reports isOpen')
check(qb.OpenInventoryById(7, 99) == false, 'OpenInventoryById unknown player')

-- OpenInventory(nil) opens the caller's own inventory, not a stash called "nil"
check(qb.OpenInventory(7) == true, 'OpenInventory with no identifier succeeds')
check(internal.sessionOf(7).secondary == nil, 'it is a single-panel self session')
check(internal.getInventory('stash:nil') == nil, 'no stash named nil is created')

-- CreateInventory on an existing stash updates label and capacity
qb.CreateInventory('box', { label = 'Renamed', slots = 7, maxweight = 12345 })
local b = internal.getInventory('stash:box')
check(b.label == 'Renamed' and b.slots == 7 and b.maxWeight == 12345, 'CreateInventory refreshes an existing stash')

-- legacy events
local ev = handlers
local function fire(name, src, ...)
    env.source = src
    for _, cb in ipairs(ev[name] or {}) do cb(...) end
end
invoker = nil
local function lastReject() local e = clientEvents[#clientEvents]; return e and e.name == 'kora_inventory:client:rejected' and e.args[1] end
check(#(ev['inventory:server:OpenInventory'] or {}) == 1 and #(ev['qb-inventory:server:OpenInventory'] or {}) == 1, 'legacy open events registered')
fire('inventory:server:OpenInventory', 7, 'stash', 'box', { maxweight = 999999999, slots = 999 })
check(internal.sessionOf(7).secondary == 'stash:box', 'legacy open of a registered stash opens it')
check(internal.getInventory('stash:box').maxWeight == 12345, 'client-supplied capacity is ignored')
clientEvents = {}
fire('qb-inventory:server:OpenInventory', 7, 'stash', 'client_made_up', {})
check(internal.getInventory('stash:client_made_up') == nil, 'a stash the server never registered is not created')
check(lastReject(), 'and the caller is told')
clientEvents = {}
fire('inventory:server:OpenInventory', 7, 'stash', 'locked')
check(lastReject() == 'not authorised', 'group policy applies to the legacy open')
clientEvents = {}
fire('inventory:server:OpenInventory', 7, 'stash', 'far')
check(lastReject() == 'too far away', 'fixture distance applies to the legacy open')
for _, bad in ipairs({ 'trunk', 'glovebox', 'crafting', 5 }) do
    clientEvents = {}
    fire('inventory:server:OpenInventory', 7, bad, 'ABC123')
    check(lastReject(), 'type ' .. tostring(bad) .. ' refused')
end
clientEvents = {}
fire('inventory:server:OpenInventory', 7, 'stash', 'x; DROP')
check(lastReject(), 'malformed identifier refused')
fire('inventory:server:OpenInventory', 7, 'stash', 'box')
fire('inventory:server:SetIsOpenState', 7, false, 'stash', 'box')
check(internal.sessionOf(7) ~= nil, 'SetIsOpenState cannot close or unlock a session')
local useSlot
for slot, item in pairs(internal.getInventory('player:7').items) do if item.info.q == 8 then useSlot = slot end end
local usedBefore = #used
if useSlot then
    fire('inventory:server:UseItem', 7, 'player', { slot = useSlot, name = 'bandage' })
    check(#used == usedBefore + 1, 'legacy UseItem uses the caller slot')
end
fire('qb-inventory:server:UseItem', 7, 'player', { slot = 9999 })
check(#used == usedBefore + (useSlot and 1 or 0), 'legacy UseItem for an empty slot does nothing')

io.write(('kora_inventory smoke: %d passed, 0 failed\n'):format(checks))
