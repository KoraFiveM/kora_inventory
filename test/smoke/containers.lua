local H = dofile('test/harness.lua')

Config = { qbinventory = {} }
dofile('config.lua')
dofile('shared.lua')

local state, opened, broadcasts = {
    ['player:10'] = {
        key = 'player:10', type = 'player', id = 10, slots = 8, maxWeight = 1000,
        items = {
            [1] = { slot = 1, name = 'briefcase', amount = 1, weight = 10, info = {} },
            [3] = { slot = 3, name = 'backpack', amount = 1, weight = 10, info = {} },
        },
    },
    ['player:20'] = {
        key = 'player:20', type = 'player', id = 20, slots = 8, maxWeight = 1000,
        items = { [2] = { slot = 2, name = 'phone', amount = 2, weight = 10, info = { serial = 'P-1' } } },
    },
}, {}, 0

exports = {
    kora_core = {
        getJob = function() return { name = 'unemployed', onduty = false } end,
        getPlayerData = function(_, source)
            if source == 10 then return { citizenid = 'CID-10' } end
            if source == 20 then return { citizenid = 'CID-20' } end
        end,
    },
}
GetGameTimer = function() return 12345 end
GetPlayerPed = function(source) return source == 10 and 110 or source == 20 and 120 or 0 end
GetPlayerRoutingBucket = function(source) return (source == 10 or source == 20) and 1 or 2 end
GetEntityCoords = function() return { x = 0, y = 0, z = 0 } end
Kora = { distance = { player = function() return true end } }

QbInventory = { copy = QbInventory.copy, internal = {} }
local I = QbInventory.internal
I.config = Config.qbinventory
I.copy = QbInventory.copy
I.resolveInventory = function(reference)
    if type(reference) == 'number' then reference = 'player:' .. reference end
    return reference, state[reference]
end
I.createSecondary = function(kind, id, options)
    local inventoryKey = kind .. ':' .. id
    state[inventoryKey] = {
        key = inventoryKey, type = kind, id = id, label = options.label, slots = options.slots,
        maxWeight = options.maxWeight, items = {}, owner = options.owner, access = options.access,
    }
    return state[inventoryKey]
end
I.removeSecondary = function(inventoryKey) state[inventoryKey] = nil; return true end
I.setInventoryItems = function(inventoryKey, items) state[inventoryKey].items = I.copy(items); return true end
I.view = function(inventoryKey) return I.copy(state[inventoryKey]) end
I.lock = function(_, callback) return callback() end
I.canAdd = function(inventoryKey, _, amount, slot)
    local inv = state[inventoryKey]
    if not inv or (slot and inv.items[slot]) then return false, 'slots' end
    return true
end
I.removeFrom = function(inventoryKey, slot, amount)
    local item = state[inventoryKey].items[slot]
    if not item or item.amount < amount then return false, 'item changed' end
    local removed = I.copy(item); removed.amount = amount
    if item.amount == amount then state[inventoryKey].items[slot] = nil else item.amount = item.amount - amount end
    return true, nil, removed
end
I.addTo = function(inventoryKey, name, amount, slot, info)
    local inv = state[inventoryKey]
    slot = slot or 1
    if inv.items[slot] then return false, 'slots' end
    inv.items[slot] = { slot = slot, name = name, amount = amount, weight = 10, info = I.copy(info or {}) }
    return true, slot
end
I.bump = function() end
I.broadcast = function() broadcasts = broadcasts + 1 end
I.open = function(source, inventoryKey) opened[#opened + 1] = { source = source, key = inventoryKey }; return true, I.view(inventoryKey) end

local Domain = dofile('server/containers.lua')
local Containers, Evidence = Domain.containers, Domain.evidence

H.equal(Containers.create('unsafe', {}), false, 'unbounded generic container is refused')
H.equal(Containers.create('locker.1', { ownerSource = 10, slots = 4, maxWeight = 80 }), true, 'server-derived owner can create container')
H.equal(state['container:locker.1'].owner, 'CID-10', 'container owner is citizen id, not client data')
H.equal(Containers.create('bad:key', { ownerSource = 10 }), false, 'container identifiers cannot inject storage keys')

local bound, id = Containers.bindItem(10, 1, { slots = 2, maxWeight = 30 })
H.equal(bound, true, 'player-held item is bound by server slot')
H.ok(id:match('^item%-'), 'bound item id is server generated')
H.equal(state['player:10'].items[1].info.containerId, id, 'binding is written through authoritative setter')
H.equal(Containers.openItem(10, 1), true, 'only current server item binding opens container')
H.equal(opened[#opened].key, 'container:' .. id, 'open uses derived container key')
H.equal(Containers.openItem(10, 2), false, 'empty item slot cannot name a container')

local portable, portableView = Containers.openConfiguredItem(10, 3)
H.equal(portable, true, 'configured backpack opens from its authoritative player slot')
local backpackId = state['player:10'].items[3].info.containerId
local backpackInventory = state['container:' .. backpackId]
H.ok(backpackId:match('^item%-'), 'configured backpack receives a server-generated binding')
H.equal(backpackInventory.owner, nil, 'portable backpack access is not pinned to its first holder')
H.equal(backpackInventory.access(10, backpackInventory), true, 'portable policy proves current first holder possession')
state['player:10'].items[3] = nil
state['player:20'].items[3] = { slot = 3, name = 'backpack', amount = 1, weight = 10, info = { containerId = backpackId } }
H.equal(backpackInventory.access(10, backpackInventory), false, 'former holder loses portable-container access after transfer')
H.equal(backpackInventory.access(20, backpackInventory), true, 'new holder gains access only with the exact bound item')

H.equal(Evidence.open(10, 'case-1'), false, 'evidence remains default deny without trusted policy')
Config.qbinventory.containers.evidence.access = function(source, action, context)
    return source == 10 and (action == 'open' or action == 'seize' or action == 'release') and context.evidenceId == 'case-1'
end
H.equal(Evidence.open(10, 'case-1'), true, 'configured server policy opens evidence')
H.equal(opened[#opened].key, 'evidence:case-1', 'evidence key is server-derived and scoped')
H.equal(Evidence.seize(10, 20, 'case-1', 2, 1, 3), true, 'policy-authorised server seizure succeeds')
H.equal(state['player:20'].items[2].amount, 1, 'seizure removes only authoritative target amount')
H.equal(state['evidence:case-1'].items[3].name, 'phone', 'seizure preserves server item identity')
H.equal(Evidence.release(10, 20, 'case-1', 3, 1, 4), true, 'policy-authorised release succeeds')
H.equal(state['player:20'].items[4].info.serial, 'P-1', 'release preserves trusted metadata')
H.ok(broadcasts >= 4, 'committed evidence moves notify both inventory viewers')

H.finish()
