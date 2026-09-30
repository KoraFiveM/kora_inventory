-- Real persistence/authority code, with only the framework and SQL transport stubbed.
local H = dofile('test/harness.lua')
Config = {}
dofile('config.lua')
dofile('shared.lua')
local rows, saved, events, callbacks, threads, registered = {}, {}, {}, {}, {}, {}
local players = {
    [7] = { citizenid = 'CID7', job = { name = 'police', grade = { level = 1 } }, items = {} },
    [8] = { citizenid = 'CID8', job = { name = 'civilian', grade = { level = 0 } }, items = {} },
}
local positions = { [7] = 2, [8] = 100 }
local function noop() end
GetCurrentResourceName = function() return 'qbinventory' end
GetInvokingResource = function() return nil end
GetGameTimer = function() return 1000 end
GetPlayerPed = function(source) return source end
GetEntityCoords = function(source) return { x = positions[source], y = 0, z = 0 } end
GetPlayerRoutingBucket = function() return 0 end
CreateThread = function(callback) threads[#threads + 1] = callback end
Wait, RegisterCommand, TriggerClientEvent = noop, noop, noop
AddEventHandler = function(name, callback) events[name] = callback end
RegisterNetEvent = AddEventHandler
TriggerEvent = function(name, ...) if events[name] then events[name](...) end end
local encoded, nextJson = {}, 0
json = {
    encode = function(value)
        nextJson = nextJson + 1
        local token = tostring(nextJson)
        encoded[token] = QbInventory.copy(value)
        return token
    end,
    decode = function(token) return QbInventory.copy(encoded[token]) end,
}
QB = {
    resources = { serverRegistry = function() return { track = noop, untrack = noop } end },
    callback = { register = function(name, callback) callbacks[name] = callback end },
    distance = { player = function(source, point, distance) return math.abs(point.x - positions[source]) <= distance end },
    sql = {
        ready = function() return true end,
        migrateFiles = function() return {} end,
        query = function(_, params)
            if #params == 0 then return rows end
            for _, row in ipairs(rows) do
                if row.inventory_type == params[1] and row.inventory_id == params[2] then return { row } end
            end
            return {}
        end,
        execute = function(statement, params)
            if statement:find('INSERT INTO `qbinventory_inventories`', 1, true) then
                local key = params[1] .. ':' .. params[2]
                saved[key] = { items = json.decode(params[7]), properties = json.decode(params[8]), revision = params[6] }
                for _, row in ipairs(rows) do
                    if row.inventory_type == params[1] and row.inventory_id == params[2] then
                        row.items, row.properties = params[7], params[8]
                    end
                end
            end
            return true
        end,
        upsert = function() return true end,
    },
}
local definitions = {
    wood = { name = 'wood', weight = 1 },
    backpack = { name = 'backpack', weight = 1, unique = true },
}
exports = setmetatable({}, {
    __call = function(_, name, callback) registered[name] = callback end,
    __index = function(_, resource)
        return setmetatable({}, { __index = function(_, name)
            return function(_, ...)
                if resource == 'qbcore' then
                    local source, field = ...
                    if name == 'getShared' then return definitions[field] end
                    if name == 'allShared' then return {} end
                    if name == 'getPlayerData' then return field and players[source].items or players[source] end
                end
                return registered[name] and registered[name](...)
            end
        end })
    end,
})
local function stored(kind, id, properties)
    rows[#rows + 1] = {
        inventory_type = kind, inventory_id = id, label = 'Stored label', slots = 9,
        max_weight = 900, revision = 12,
        items = { [1] = { name = 'wood', amount = 7, price = 5, info = { batch = 'persisted' } } },
        properties = properties or {},
    }
end
stored('shop', 'before', { owner = 'OLD', groups = { old = 5 }, coords = { x = 500, y = 0, z = 0 }, distance = 1,
    prices = { wood = 50 }, currency = 'old', accessRequired = true })
stored('shop', 'later', { accessRequired = true })
stored('shop', 'removed-before', { accessRequired = true })
stored('container', 'before-container', { accessRequired = true })
stored('stash', 'cached', { owner = 'CID7', groups = { police = 1 }, coords = { x = 2, y = 0, z = 0 }, distance = 3 })
stored('stash', 'cached-set', { owner = 'CID7', accessRequired = true })
stored('stash', 'unbound', { accessRequired = true })
stored('stash', 'legacy-owner', { owner = 'CID7' })
stored('stash', 'legacy-groups', { groups = { police = 1 } })
stored('stash', 'legacy-coords', { coords = { x = 2, y = 0, z = 0 }, distance = 3 })
stored('stash', 'legacy-open')
stored('evidence', 'case', { accessRequired = true })
stored('container', 'portable')
local bareOpens = { 'open-nil', 'open-false', 'native-open-nil', 'native-open-false', 'direct-false' }
for _, id in ipairs(bareOpens) do
    stored('stash', id, { owner = 'CID7', groups = { police = 1 } })
end
stored('stash', 'capacity-before', { owner = 'CID7', groups = { police = 1 }, accessRequired = true })
stored('stash', 'label-before', { owner = 'CID7', groups = { police = 1 } })
stored('stash', 'callback-before', { owner = 'CID7', groups = { police = 1 }, accessRequired = true })

dofile('server/persistence.lua')
dofile('server.lua')
local inventory, internal, persistence = QbInventory, QbInventory.internal, QbInventory.persistence
local deny = function() return false end
local function genericOpen(key) return callbacks['qbinventory:server:open'](7, 'stash', { key = key }) end
H.ok(inventory.api.RegisterShop('before', {
    label = 'Current label', slots = 4, maxWeight = 400, owner = 'CID7', groups = { police = 1 },
    coords = { x = 2, y = 0, z = 0 }, distance = 3, access = deny, prices = { wood = 3 }, currency = 'cash',
    inventory = { { name = 'wood', amount = 10, price = 2 } },
}))
internal.createSecondary('container', 'before-container', { access = deny, slots = 4, maxWeight = 400 })
H.ok(inventory.api.RegisterShop('removed-before', {}), 'a trusted registration may deliberately remove an old callback')
H.equal(inventory.api.stashGet('cached')[1], nil, 'bare cache lookup occurs before persistence is ready')
H.ok(inventory.api.stashSet('cached-set', {}), 'bare cache writer may also create a startup placeholder')
H.ok(inventory.api.stashOpen(8, 'open-nil'), 'omitted public stash options remain a bare lookup')
H.ok(inventory.api.stashOpen(8, 'open-false', false), 'false public stash options remain a bare lookup')
H.ok(inventory.api.OpenInventory(8, 'native-open-nil'), 'omitted native open options remain a bare lookup')
H.ok(inventory.api.OpenInventory(8, 'native-open-false', false), 'false native open options remain a bare lookup')
H.ok(internal.createSecondary('stash', 'direct-false', false), 'false constructor options also remain a bare lookup')
H.ok(inventory.api.stashOpen(8, 'capacity-before', { slots = 4 }), 'capacity options can precede persistence readiness')
H.ok(inventory.api.OpenInventory(8, 'label-before', { label = 'Current partial label' }))
internal.createSecondary('stash', 'callback-before', { access = deny })
threads[1]() -- Actual bootstrap/migration/restore event; periodic workers remain captured.

local before = internal.getInventory('shop:before')
H.equal(before.access, deny, 'restoration keeps the trusted callback registered before readiness')
H.equal(genericOpen(before.key), false, 'generic key open cannot bypass the retained callback')
H.equal(before.label, 'Current label')
H.equal(before.slots, 4)
H.equal(before.maxWeight, 400)
H.equal(before.owner, 'CID7')
H.equal(before.groups.police, 1)
H.equal(before.coords.x, 2)
H.equal(before.distance, 3)
H.equal(before.prices.wood, 3)
H.equal(before.currency, 'cash')
H.equal(before.items[1].amount, 7, 'persisted contents replace the startup seed')
H.equal(before.stock[1].amount, 7, 'persisted shop stock is retained')
H.equal(before.items[1].info.batch, 'persisted', 'persisted metadata is retained')
H.equal(before.revision, 12, 'restoration does not invent a revision')
H.equal(internal.getInventory('container:before-container').access, deny, 'explicit domain construction retains its policy too')
H.equal(genericOpen('container:before-container'), false)
H.equal(genericOpen('shop:removed-before'), true, 'trusted callback removal before readiness remains intentional')

local cached = internal.getInventory('stash:cached')
H.equal(cached.label, 'Stored label', 'an unregistered placeholder cannot overwrite durable descriptive state')
H.equal(cached.owner, 'CID7', 'bare lookup cannot overwrite durable ownership')
H.equal(cached.groups.police, 1)
H.equal(cached.coords.x, 2)
H.equal(cached.slots, 9)
H.equal(cached.items[1].amount, 7)
H.equal(internal.canAccess(8, cached), false)
for _, id in ipairs(bareOpens) do
    local inv = internal.getInventory('stash:' .. id)
    H.equal(inv.owner, 'CID7', 'bare public open cannot replace durable ownership')
    H.equal(inv.groups.police, 1, 'bare public open cannot replace durable groups')
    H.equal(internal.canAccess(8, inv), false, 'the earlier bare opener is denied after hydration')
end
local capacityBefore = internal.getInventory('stash:capacity-before')
H.equal(capacityBefore.slots, 4, 'only the supplied capacity is refreshed')
H.equal(capacityBefore.label, 'Stored label', 'unsupplied descriptive state is retained')
H.equal(capacityBefore.owner, 'CID7', 'partial capacity cannot remove durable ownership')
H.equal(capacityBefore.groups.police, 1)
H.equal(capacityBefore.accessRequired, true, 'partial capacity cannot remove a callback requirement')
H.equal(genericOpen(capacityBefore.key), false)
H.equal(internal.canAccess(8, capacityBefore), false)
local labelBefore = internal.getInventory('stash:label-before')
H.equal(labelBefore.label, 'Current partial label')
H.equal(labelBefore.slots, 9, 'a partial label cannot replace unsupplied capacity')
H.equal(labelBefore.owner, 'CID7')
H.equal(labelBefore.groups.police, 1)
H.equal(internal.canAccess(8, labelBefore), false)
local callbackBefore = internal.getInventory('stash:callback-before')
H.equal(callbackBefore.access, deny, 'a partial callback registration survives bootstrap')
H.equal(callbackBefore.owner, 'CID7', 'a partial callback retains other durable restrictions')
H.equal(callbackBefore.groups.police, 1)
H.equal(genericOpen(callbackBefore.key), false)
H.equal(genericOpen('stash:cached-set'), false, 'bare startup writer cannot discard a stored callback requirement')
H.ok(persistence.flush(), 'startup dirty snapshots can now flush')
H.equal(saved['shop:before'].items[1].amount, 7, 'flush cannot persist the old initial stock seed')
H.equal(saved['shop:before'].properties.stock[1].amount, 7)
H.equal(saved['shop:before'].revision, 12)
H.equal(saved['shop:before'].properties.accessRequired, true)
H.equal(saved['shop:before'].properties.access, nil, 'callbacks themselves never enter JSON')
H.equal(saved['stash:cached'].properties.owner, 'CID7', 'queued bare lookup is replaced by the hydrated durable record')
H.equal(saved['stash:cached-set'].properties.accessRequired, true)
H.equal(saved['stash:cached-set'].items[1].amount, 7)

stored('stash', 'capacity-after', { owner = 'CID7', groups = { police = 1 }, accessRequired = true })
local capacityAfter = internal.createSecondary('stash', 'capacity-after', { slots = 4 })
H.equal(capacityAfter.slots, 4, 'on-demand load applies the same partial capacity rules')
H.equal(capacityAfter.label, 'Stored label')
H.equal(capacityAfter.owner, 'CID7')
H.equal(capacityAfter.groups.police, 1)
H.equal(capacityAfter.accessRequired, true)
H.equal(genericOpen(capacityAfter.key), false)
H.equal(internal.canAccess(8, capacityAfter), false)
stored('stash', 'label-after', { owner = 'CID7', groups = { police = 1 } })
local labelAfter = internal.createSecondary('stash', 'label-after', { label = 'Current partial label' })
H.equal(labelAfter.label, 'Current partial label')
H.equal(labelAfter.slots, 9)
H.equal(labelAfter.owner, 'CID7')
H.equal(labelAfter.groups.police, 1)
H.equal(internal.canAccess(8, labelAfter), false)
stored('stash', 'callback-after', { owner = 'CID7', groups = { police = 1 }, accessRequired = true })
local callbackAfter = internal.createSecondary('stash', 'callback-after', { access = deny })
H.equal(callbackAfter.access, deny, 'on-demand load preserves the supplied callback')
H.equal(callbackAfter.owner, 'CID7')
H.equal(callbackAfter.groups.police, 1)
H.equal(genericOpen(callbackAfter.key), false)

H.equal(genericOpen('shop:later'), false, 'marked restore before registration fails closed')
H.ok(inventory.api.RegisterShop('later', { access = deny }))
H.equal(genericOpen('shop:later'), false, 'later registration installs the real callback')
H.equal(internal.getInventory('shop:later').stock[1].amount, 7, 'later registration does not reseed stock')
H.ok(persistence.save(internal.getInventory('shop:later')))
H.equal(saved['shop:later'].properties.accessRequired, true)
H.ok(inventory.api.RegisterShop('later', {}), 'explicit callback removal is supported')
H.equal(genericOpen('shop:later'), true)
H.ok(persistence.save(internal.getInventory('shop:later')))
H.equal(saved['shop:later'].properties.accessRequired, false, 'trusted callback removal clears the persisted requirement')
H.equal(persistence.load('shop', 'later').accessRequired, false)

H.equal(genericOpen('stash:unbound'), false)
H.ok(inventory.api.stashGet('unbound'), 'bare item reads are still supported')
H.ok(inventory.api.stashSet('unbound', internal.getInventory('stash:unbound').items))
H.ok(persistence.save(internal.getInventory('stash:unbound')))
H.equal(saved['stash:unbound'].properties.accessRequired, true, 'unbound saves and bare writes retain the callback requirement')
H.equal(persistence.load('stash', 'unbound').accessRequired, true)
H.equal(genericOpen('stash:unbound'), false)
inventory.api.RegisterStash('unbound', 'Deliberately public', 9, 900, false)
H.equal(genericOpen('stash:unbound'), true, 'explicit stash registration can remove a prior callback requirement')
H.ok(persistence.save(internal.getInventory('stash:unbound')))
H.equal(saved['stash:unbound'].properties.accessRequired, false)

for _, id in ipairs({ 'legacy-owner', 'legacy-groups', 'legacy-coords' }) do
    H.equal(internal.canAccess(7, internal.getInventory('stash:' .. id)), true, 'legacy durable restriction still permits the authorized player')
    H.equal(internal.canAccess(8, internal.getInventory('stash:' .. id)), false, 'legacy durable restriction still denies another player')
end
H.equal(internal.canAccess(8, internal.getInventory('stash:legacy-open')), true, 'historical unmarked public stores keep their semantics')
H.ok(persistence.save(internal.getInventory('stash:legacy-open')))
H.equal(saved['stash:legacy-open'].properties.accessRequired, false)

Config.qbinventory.containers.evidence.access = function(source) return source == 7 end
dofile('server/containers.lua')
H.equal(genericOpen('evidence:case'), false, 'marked evidence cannot bypass its unbound domain policy')
H.ok(inventory.evidence.open(7, 'case'), 'existing evidence flow reinstalls its callback')
H.equal(internal.canAccess(8, internal.getInventory('evidence:case')), false)
players[7].items[1] = internal.buildItem('backpack', 1, 1, { containerId = 'portable' })
H.ok(inventory.containers.openConfiguredItem(7, 1), 'existing portable-container flow reinstalls possession policy')
H.equal(internal.canAccess(8, internal.getInventory('container:portable')), false)
H.ok(persistence.save(internal.getInventory('container:portable')))
H.equal(saved['container:portable'].properties.accessRequired, true, 'newly rebound legacy callbacks gain the marker on save')
H.equal(persistence.load('container', 'portable').accessRequired, true)

stored('stash', 'late-constructor', { accessRequired = true })
local late = internal.createSecondary('stash', 'late-constructor', { label = 'Late trusted constructor' })
H.equal(late.accessRequired, true, 'constructor after readiness preserves a stored missing-callback requirement')
H.equal(genericOpen(late.key), false)
TriggerEvent('qbinventory:server:persistenceReady')
H.equal(internal.getInventory(late.key).accessRequired, true, 'bulk hydration cannot interpret constructor options as callback removal')
H.equal(genericOpen(late.key), false, 'missing callback stays denied after repeated hydration')
H.ok(persistence.flush())
H.equal(saved[late.key].properties.accessRequired, true, 'merged dirty snapshot preserves the missing-callback requirement')
inventory.api.RegisterStash('late-constructor', 'Deliberately public', 9, 900, false)
TriggerEvent('qbinventory:server:persistenceReady')
H.equal(internal.getInventory(late.key).accessRequired, false, 'explicit callback removal remains authoritative over the marked stored row')
H.equal(genericOpen(late.key), true)
H.ok(persistence.flush())
H.equal(saved[late.key].properties.accessRequired, false, 'explicit callback removal queues the cleared marker')
H.finish()
