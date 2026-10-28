-- Behavioural coverage for the ox_inventory server adapter.
--
-- This file used to be a plain string-grep over server/compat/ox.lua: it
-- asserted that 27 of the 52 pinned names appeared somewhere in the source and
-- nothing at all about their arity or return shape. That is precisely how
-- SwapSlots ended up with an inverted arity, InspectInventory with reversed
-- parameters, CreateDropFromPlayer duplicating items and five exports
-- defaulting `strict` the wrong way -- every one of those greps stayed green.
--
-- So: mock the QbInventory.internal seam the way server.lua actually behaves,
-- load the REAL shared.lua for copy/totalWeight/sameInfo (a hand-rolled mock of
-- those primitives is the same drift one layer down), then call the adapter and
-- assert what comes back.
local H = dofile('test/harness.lua')

-- --- structural assertions (retained from the original grep) ----------------
local file = assert(io.open('server/compat/ox.lua', 'r'))
local source = file:read('*a')
file:close()
H.ok(source:find('inventory.compat.ox = ox', 1, true), 'adapter is namespaced and does not replace authority')
H.ok(not source:find("exports('", 1, true), 'adapter registers no Cfx exports; providers.lua owns the identity')

-- --- the world the adapter runs in -----------------------------------------

local warnings = {}
local realPrint = print
print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
    warnings[#warnings + 1] = table.concat(parts, ' ')
end

QbInventory = nil
dofile('shared.lua') -- real copy/amount/sameInfo/totalWeight/itemWeight primitives
local I = QbInventory

local ITEMS = {
    water = { name = 'water', label = 'Water', weight = 10 },
    bread = { name = 'bread', label = 'Bread', weight = 20 },
    phone = { name = 'phone', label = 'Phone', weight = 5, unique = true },
    feather = { name = 'feather', label = 'Feather', weight = 0 },
    backpack = { name = 'backpack', label = 'Backpack', weight = 1, container = true },
    weapon_pistol = { name = 'weapon_pistol', label = 'Pistol', weight = 100, type = 'weapon' },
}
GetPlayerRoutingBucket = function(src) return src == 1 and 55 or 0 end

local state, locks, lockOrder, writes, opened, created, removedKeys

local function item(name, amount, slot, metadata)
    local def = ITEMS[name]
    return {
        slot = slot, name = def.name, amount = amount, weight = def.weight, type = def.type or 'item',
        unique = def.unique or false, label = def.label,
        info = I.copy(metadata or {}), metadata = I.copy(metadata or {}),
    }
end

local function inventory(key, kind, id, slots, maxWeight, items, extra)
    local inv = { key = key, type = kind, id = id, label = tostring(id), slots = slots,
        maxWeight = maxWeight, items = items or {}, revision = 0 }
    if kind == 'player' then inv.source = id end
    for field, value in pairs(extra or {}) do inv[field] = value end
    return inv
end

local function reset()
    locks, lockOrder, writes, opened, created, removedKeys = {}, {}, {}, {}, {}, {}
    warnings = {}
    state = {
        ['player:1'] = inventory('player:1', 'player', 1, 5, 1000, {
            [1] = item('water', 2, 1, { quality = 100, serial = 'A' }),
            [2] = item('water', 3, 2, { quality = 100 }),
            [3] = item('bread', 1, 3),
        }),
        ['stash:box'] = inventory('stash:box', 'stash', 'box', 5, 100, {
            [2] = item('phone', 1, 2),
        }, { owner = 'CID1' }),
        ['trunk:ABC 123'] = inventory('trunk:ABC 123', 'trunk', 'ABC 123', 4, 500, {
            [1] = item('bread', 1, 1),
        }),
    }
end
reset()

-- Mirrors server.lua's key/playerKey/resolveInventoryRef exactly, including the
-- scan across secondary kinds that a bare identifier relies on.
local RESOLVE_KINDS = { 'stash', 'trunk', 'glovebox', 'container', 'shop', 'temporary', 'drop', 'evidence' }
local function key(kind, id) return ('%s:%s'):format(kind, tostring(id)) end
local function resolve(reference, preferred)
    if type(reference) == 'number' then
        local k = key('player', reference)
        return k, state[k]
    end
    if type(reference) == 'table' then
        if reference.key then return resolve(reference.key, preferred) end
        if reference.type and reference.id ~= nil then return resolve(key(reference.type, reference.id)) end
        return nil, nil
    end
    if type(reference) ~= 'string' or reference == '' then return nil, nil end
    if state[reference] then return reference, state[reference] end
    if preferred and state[key(preferred, reference)] then return key(preferred, reference), state[key(preferred, reference)] end
    for _, kind in ipairs(RESOLVE_KINDS) do
        if state[key(kind, reference)] then return key(kind, reference), state[key(kind, reference)] end
    end
    return nil, nil
end

local function held(k) return locks[k] ~= nil end
-- Snapshot of every key locked at this instant, so a test can assert that one
-- call happened inside the lock another call took.
local function heldKeys()
    local out = {}
    for k in pairs(locks) do out[#out + 1] = k end
    table.sort(out)
    return table.concat(out, '|')
end

I.internal = {
    key = key,
    playerKey = function(src) return key('player', src) end,
    resolveInventory = resolve,
    copy = I.copy,
    itemWeight = I.itemWeight,
    totalWeight = I.totalWeight,
    sameInfo = I.sameInfo,
    itemDef = function(name)
        return ITEMS[type(name) == 'string' and name:lower() or name]
    end,
    bump = function(k) if state[k] then state[k].revision = state[k].revision + 1 end end,
    broadcast = function() end,
    open = function(src, secondaryKey)
        opened[#opened + 1] = { src = src, key = secondaryKey }
        return true
    end,
}
local core = I.internal

-- The real lock sorts its keys and is re-entrant per key; both matter here,
-- since SwapSlots takes TWO and may be handed the same one twice.
core.lock = function(keys, fn)
    table.sort(keys)
    lockOrder[#lockOrder + 1] = table.concat(keys, '|')
    for _, k in ipairs(keys) do
        if locks[k] then locks[k] = locks[k] + 1 else locks[k] = 1 end
    end
    local result = table.pack(fn())
    for _, k in ipairs(keys) do
        locks[k] = locks[k] - 1
        if locks[k] == 0 then locks[k] = nil end
    end
    return table.unpack(result, 1, result.n)
end

-- Mirrors server.lua's setInventoryItems: rebuild every slot, reject anything
-- outside the slot range or over maxWeight, and only then commit.
core.setInventoryItems = function(reference, items)
    local k, inv = resolve(reference)
    if not k or not inv then return false, 'inventory not found' end
    if type(items) ~= 'table' then return false, 'items must be a table' end
    local checked = {}
    for rawSlot, rawItem in pairs(items) do
        local slot = math.floor(tonumber(rawSlot) or 0)
        local amount = rawItem and I.amount(rawItem.amount or rawItem.count, 1)
        if slot < 1 or slot > inv.slots or not rawItem or not amount or not ITEMS[rawItem.name] then
            return false, 'invalid item table'
        end
        local built = I.copy(rawItem)
        built.slot, built.amount = slot, amount
        built.weight = ITEMS[rawItem.name].weight
        checked[slot] = built
    end
    if I.totalWeight(checked) > inv.maxWeight then return false, 'over weight' end
    inv.items = checked
    writes[#writes + 1] = { key = k, locked = held(k), slots = (function()
        local n = 0; for _ in pairs(checked) do n = n + 1 end; return n
    end)() }
    return true
end

core.createSecondary = function(kind, id, opts)
    local k = key(kind, id)
    if state[k] then return state[k], true end
    local inv = inventory(k, kind, id, math.floor(tonumber(opts.slots) or 50),
        tonumber(opts.maxWeight or opts.maxweight) or 100000, I.copy(opts.items or {}),
        { label = opts.label, owner = opts.owner, coords = opts.coords, bucket = opts.bucket, temporary = opts.temporary == true })
    state[k] = inv
    created[#created + 1] = { key = k, kind = kind, id = id, opts = I.copy(opts), locked = heldKeys() }
    return inv
end

core.removeSecondary = function(reference)
    local k, inv = resolve(reference)
    if not k or not inv or inv.type == 'player' then return false end
    state[k] = nil
    removedKeys[#removedKeys + 1] = k
    return true
end

-- Mirrors server.lua's rekeySecondary: move the registry entry, not just the
-- record's own id/key fields.
core.rekeySecondary = function(reference, newKind, newId)
    local oldKey, inv = resolve(reference)
    if not oldKey or not inv then return nil, 'inventory' end
    if inv.type == 'player' then return nil, 'player inventories cannot be rekeyed' end
    local newKey = key(newKind or inv.type, newId)
    if newKey == oldKey then return newKey end
    if state[newKey] then return nil, 'target inventory already exists' end
    state[oldKey] = nil
    inv.key, inv.id = newKey, newId
    if newKind then inv.type = newKind end
    state[newKey] = inv
    return newKey
end

core.canAdd = function(reference, name, amount)
    local k, inv = resolve(reference)
    if not k or not inv then return false, 'inventory' end
    if not ITEMS[name] then return false, 'item' end
    if I.totalWeight(inv.items) + (ITEMS[name].weight * amount) > inv.maxWeight then return false, 'weight' end
    return true
end

core.addTo = function(reference, name, amount, slot, metadata)
    local k, inv = resolve(reference)
    if not k or not inv then return false, 'inventory' end
    local target = slot or I.stackSlot(inv.items, { name = name, info = metadata or {} })
        or I.firstFreeSlot(inv.items, inv.slots)
    if not target then return false, 'no free slot' end
    if inv.items[target] then
        inv.items[target].amount = inv.items[target].amount + amount
    else
        inv.items[target] = item(name, amount, target, metadata)
    end
    return true, target
end

core.removeFrom = function(reference, slot, amount)
    local k, inv = resolve(reference)
    if not k or not inv or not inv.items[slot] then return false, 'no item' end
    inv.items[slot].amount = inv.items[slot].amount - amount
    if inv.items[slot].amount < 1 then inv.items[slot] = nil end
    return true
end

local api = {}
I.api = api
api.RegisterStash = function(id, label, slots, maxWeight, owner, groups, coords)
    api.stash = { id = id, label = label, slots = slots, maxWeight = maxWeight, owner = owner, groups = groups, coords = coords }
    core.createSecondary('stash', id, { label = label, slots = slots, maxWeight = maxWeight, owner = owner })
    return key('stash', id)
end
api.CreateTemporaryStash = function(properties)
    api.temporaryIds = api.temporaryIds or {}
    api.temporaryIds[#api.temporaryIds + 1] = properties.id
    return key('temporary', properties.id)
end
api.RegisterShop = function(shopType, details) api.shop = { shopType = shopType, details = details } end
api.registerHook = function(event, cb, options) api.hook = { event = event, cb = cb, options = options }; return 7 end
api.removeHooks = function(id) api.removedHook = id; return true end
-- Mirrors server.lua's native useItem: locates the item by slot/name, mutates
-- nothing directly (that lives inside the real lock/hook/handler chain), and
-- just reports whether a use happened.
api.useItem = function(src, slotOrName)
    api.usedItem = { src = src, slotOrName = slotOrName }
    local inv = state[key('player', src)]
    local item = type(slotOrName) == 'number' and inv and inv.items[slotOrName] or nil
    if not item then return false, 'item not found' end
    return true
end

exports = setmetatable({}, {
    __call = function() error('the ox compat module must never call exports()', 2) end,
    __index = function()
        return setmetatable({}, { __index = function() return function() return {} end end })
    end,
})

dofile('server/compat/ox.lua')
local Ox = I.compat.ox
H.ok(type(Ox) == 'table' and type(Ox.SwapSlots) == 'function', 'the adapter table is published on I.compat.ox')

local function argc(...) return select('#', ...) end
local function count(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n end

-- --- Tier 1: SwapSlots is a FOUR-argument, TWO-inventory cross swap ---------

reset()
local fromSlot, toSlot = Ox.SwapSlots('player:1', 'stash:box', 1, 2)
H.equal(state['player:1'].items[1].name, 'phone', 'SwapSlots moves the target item into the source slot')
H.equal(state['stash:box'].items[2].name, 'water', 'SwapSlots moves the source item into the target slot')
H.equal(state['stash:box'].items[2].amount, 2, 'SwapSlots carries the whole stack across')
H.equal(fromSlot.name, 'water', 'SwapSlots returns the source slot table')
H.equal(fromSlot.slot, 2, 'the returned source slot is re-slotted to its new home')
H.equal(toSlot.name, 'phone', 'SwapSlots returns the displaced target slot table')
H.equal(toSlot.slot, 1, 'the returned target slot is re-slotted to its new home')
H.equal(lockOrder[1], 'player:1|stash:box', 'both inventories are locked together, in sorted order')

reset()
local moved, displaced = Ox.SwapSlots('player:1', 'stash:box', 3, 4)
H.equal(state['player:1'].items[3], nil, 'swapping into an empty slot empties the source slot')
H.equal(state['stash:box'].items[4].name, 'bread', 'swapping into an empty slot fills the target slot')
H.equal(moved.name, 'bread', 'the moved item is returned')
H.equal(displaced, nil, 'an empty target slot returns nil for the displaced item')

reset()
Ox.SwapSlots('player:1', 'player:1', 1, 5)
H.equal(state['player:1'].items[5].name, 'water', 'a same-inventory swap is a single write')
H.equal(state['player:1'].items[1], nil, 'a same-inventory swap does not duplicate the item')
H.equal(count(state['player:1'].items), 3, 'a same-inventory swap preserves the slot count')

reset()
local nilResult, err = Ox.SwapSlots('player:1', 'stash:box', 1, 9)
H.equal(nilResult, nil, 'a slot outside the target inventory is refused')
H.equal(err, 'invalid_slot', 'the refusal names the slot as the problem')
H.equal(state['player:1'].items[1].name, 'water', 'a refused swap leaves the source untouched')

-- The old (reference, fromSlot, toSlot) shape bound an inventory into fromSlot,
-- where tonumber() gave nil -> 0. Passing three arguments now fails loudly on
-- the missing fourth rather than pretending to swap.
reset()
H.equal((Ox.SwapSlots('player:1', 1, 2)), nil, 'the legacy three-argument call no longer resolves')

-- --- Tier 1: CreateDropFromPlayer must EMPTY the player ---------------------

reset()
local dropId = Ox.CreateDropFromPlayer(1)
H.ok(dropId ~= nil, 'CreateDropFromPlayer returns a drop id')
H.equal(next(state['player:1'].items), nil, 'the player inventory is left EMPTY, not duplicated')
local drop = state[key('drop', dropId)]
H.ok(drop ~= nil, 'the drop inventory exists under its own key')
H.equal(drop.bucket, 55, 'player-originated drops retain the server-resolved bucket')
H.equal(count(drop.items), 3, 'every player slot was copied into the drop')
H.equal(created[1].locked, 'player:1', 'the drop is created while the player key is locked')
H.equal(writes[#writes].key, 'player:1', 'the last write clears the player')
H.equal(writes[#writes].slots, 0, 'the clearing write commits an empty item table')
H.equal(writes[#writes].locked, true, 'the clear happens INSIDE the same lock as the copy')
H.equal(Ox.CreateDropFromPlayer(1), nil, 'an empty player produces no drop, as upstream')

-- --- Tier 1: CanSwapItem does real weight arithmetic ------------------------

reset()
-- stash:box holds one phone (5) and caps at 100. Trading the phone for six
-- loaves is 0 + 120 > 100.
H.equal(Ox.CanSwapItem('stash:box', 'phone', 1, 'bread', 6), false, 'CanSwapItem refuses a swap that would exceed maxWeight')
H.equal(Ox.CanSwapItem('stash:box', 'phone', 1, 'bread', 4), true, 'CanSwapItem allows a swap that fits')
H.equal(Ox.CanSwapItem('stash:box', 'phone', 5, 'bread', 1), nil, 'CanSwapItem is nil when the inventory lacks the first item')
H.equal(Ox.CanSwapItem('stash:box', 'nonexistent', 1, 'bread', 1), nil, 'CanSwapItem is nil for an unknown item')
H.equal(Ox.CanSwapItem('nope', 'phone', 1, 'bread', 1), nil, 'CanSwapItem is nil for an unresolvable inventory')

-- --- Tier 1: UpdateVehicle re-keys the registry -----------------------------

reset()
H.equal(argc(Ox.UpdateVehicle(' abc 123 ', 'xyz789')), 0, 'UpdateVehicle returns nothing, as upstream')
H.equal(state['trunk:ABC 123'], nil, 'the vehicle inventory is no longer reachable under the old key')
H.ok(state['trunk:XYZ789'] ~= nil, 'the vehicle inventory is reachable under the new key')
H.equal(state['trunk:XYZ789'].key, 'trunk:XYZ789', 'the record key matches the registry key')
H.equal(state['trunk:XYZ789'].id, 'XYZ789', 'the record id is the new plate')
H.equal(state['trunk:XYZ789'].items[1].name, 'bread', 'the contents survive the rekey')

-- --- Tier 1: InspectInventory takes the VIEWER first ------------------------

reset()
H.equal(argc(Ox.InspectInventory(1, 'stash:box')), 0, 'InspectInventory returns nothing, as upstream')
H.equal(opened[1].src, 1, 'the panel opens on the VIEWER named by the first argument')
H.equal(opened[1].key, 'stash:box', 'the inspected inventory is the second argument')
Ox.InspectInventory(1, 1)
H.equal(#opened, 1, 'inspecting yourself is a no-op')

-- --- Tier 2: strict defaults to PARTIAL on five exports ---------------------

reset()
-- Slot 1 is water with { quality = 100, serial = 'A' }; slot 2 is water with
-- { quality = 100 }. A partial match finds both, a strict match only slot 2.
local partial = { quality = 100 }
H.equal(Ox.GetItemCount('player:1', 'water', partial), 5, 'GetItemCount defaults to partial metadata matching')
H.equal(Ox.GetItemCount('player:1', 'water', partial, true), 3, 'GetItemCount honours an explicit strict=true')
H.equal(Ox.GetSlotIdWithItem('player:1', 'water', partial), 1, 'GetSlotIdWithItem defaults to partial matching')
H.equal(Ox.GetSlotIdWithItem('player:1', 'water', partial, true), 2, 'GetSlotIdWithItem honours an explicit strict=true')
H.equal(Ox.GetSlotWithItem('player:1', 'water', partial).slot, 1, 'GetSlotWithItem defaults to partial matching')
H.equal(#Ox.GetSlotsWithItem('player:1', 'water', partial), 2, 'GetSlotsWithItem defaults to partial matching')
H.equal(#Ox.GetSlotsWithItem('player:1', 'water', partial, true), 1, 'GetSlotsWithItem honours an explicit strict=true')
H.equal(#Ox.GetSlotIdsWithItem('player:1', 'water', partial), 2, 'GetSlotIdsWithItem defaults to partial matching')
H.equal(Ox.GetSlotIdsWithItem('player:1', 'water', partial)[2], 2, 'GetSlotIdsWithItem returns bare slot ids')
-- GetItemSlots is one of only two exports that DO default to strict.
H.equal(select(2, Ox.GetItemSlots('player:1', 'water', partial)), 3, 'GetItemSlots still defaults to STRICT, as upstream')
H.equal(select(2, Ox.GetItemSlots('player:1', 'water', partial, false)), 5, 'GetItemSlots honours an explicit strict=false')

-- --- Tier 2: GetItemSlots returns three values ------------------------------

reset()
local slots, totalCount, emptySlots = Ox.GetItemSlots('player:1', 'water')
H.equal(argc(Ox.GetItemSlots('player:1', 'water')), 3, 'GetItemSlots returns three values')
H.equal(slots[1], 2, 'the first return is a slot-id-keyed MAP OF COUNTS')
H.equal(slots[2], 3, 'every matching slot id maps to its count')
H.equal(slots[3], nil, 'non-matching slots are absent from the map')
H.equal(totalCount, 5, 'the second return is the total count across those slots')
H.equal(emptySlots, 2, 'the third return is the inventory-wide empty slot count')
H.equal(Ox.GetItemSlots('player:1', 'nonexistent'), nil, 'GetItemSlots is nil for an unknown item')

-- --- Tier 2: Search treats a one-element ARRAY as single --------------------

reset()
H.equal(Ox.Search('player:1', 'count', { 'water' }), 5, 'a one-element array returns a bare value, not a table')
H.equal(Ox.Search('player:1', 'count', 'water'), 5, 'a bare string still returns a bare value')
local multi = Ox.Search('player:1', 'count', { 'water', 'bread' })
H.equal(type(multi), 'table', 'a multi-element array returns a name-keyed table')
H.equal(multi.water, 5, 'the keyed table counts each requested item')
H.equal(multi.bread, 1, 'the keyed table counts every requested item')
local searched = Ox.Search('player:1', 'slots', { 'WATER' })
H.equal(#searched, 2, 'Search lowercases the requested name before matching')
H.equal(searched[1].name, 'water', 'slot search returns item tables')
H.equal(Ox.Search('player:1', 1, { 'water' })[1].slot, 1, 'the numeric 1 alias still means slots')
-- Upstream uppercases a weapon_ prefix; the registry lookup is still
-- case-insensitive, so both spellings find the same slot.
state['player:1'].items[4] = item('weapon_pistol', 1, 4)
H.equal(Ox.Search('player:1', 'count', { 'WEAPON_PISTOL' }), 1, 'a weapon_ prefixed name is found whatever its case')
H.equal(Ox.Search('player:1', 'count', {}), false, 'an empty request is false')
H.equal(Ox.Search('nope', 'count', { 'water' }), false, 'an unresolvable inventory is false')

-- --- Tier 2: the GetSlot* family is nil for an unknown item -----------------

reset()
H.equal(Ox.GetSlotWithItem('player:1', 'nonexistent'), nil, 'GetSlotWithItem is nil for an unknown item')
H.equal(Ox.GetSlotIdWithItem('player:1', 'nonexistent'), nil, 'GetSlotIdWithItem is nil for an unknown item')
H.equal(Ox.GetSlotsWithItem('player:1', 'nonexistent'), nil, 'GetSlotsWithItem is nil for an unknown item')
H.equal(Ox.GetSlotIdsWithItem('player:1', 'nonexistent'), nil, 'GetSlotIdsWithItem is nil for an unknown item')
H.equal(Ox.GetSlotsWithItem('nope', 'water'), nil, 'GetSlotsWithItem is nil for an unresolvable inventory')
-- GetItemCount is the exception: upstream returns 0, not nil.
H.equal(Ox.GetItemCount('player:1', 'nonexistent'), 0, 'GetItemCount is 0, not nil, for an unknown item')
H.equal(Ox.GetItemCount('nope', 'water'), 0, 'GetItemCount is 0 for an unresolvable inventory')
-- A known item held in no slot is an empty list, not nil.
H.equal(#Ox.GetSlotsWithItem('player:1', 'feather'), 0, 'a known but unheld item is an empty list')

-- --- Tier 2: GetContainerFromSlot reads metadata.container ------------------

reset()
state['player:1'].items[4] = item('backpack', 1, 4, { container = 'bag-1', size = { 6, 250 } })
local container = Ox.GetContainerFromSlot('player:1', 4)
H.ok(container ~= nil, 'GetContainerFromSlot resolves upstream metadata.container')
H.equal(container.id, 'bag-1', 'the container is keyed by metadata.container')
H.equal(container.slots, 6, 'a missing container is sized from metadata.size[1]')
H.equal(container.maxWeight, 250, 'a missing container is sized from metadata.size[2]')
H.equal(created[1].opts.owner, 1, 'the created container inherits an access boundary from its holder')
-- kora_inventory's own container domain writes info.containerId; both are accepted.
state['player:1'].items[5] = item('backpack', 1, 5, { containerId = 'bag-2', size = { 2, 20 } })
H.equal(Ox.GetContainerFromSlot('player:1', 5).id, 'bag-2', 'the native containerId spelling still resolves')
H.equal(Ox.GetContainerFromSlot('player:1', 3), nil, 'a slot with no container metadata is nil')

-- --- Tier 3/4: transient ids never collide ---------------------------------

reset()
local dropA = Ox.CustomDrop('loot', {}, nil, 5, 100)
local dropB = Ox.CustomDrop('loot', {}, nil, 5, 100)
local scopedDrop = Ox.CustomDrop('loot', {}, nil, 5, 100, 22)
H.equal(state[key('drop', scopedDrop)].bucket, 22, 'CustomDrop preserves the trusted instance restriction')
H.ok(dropA ~= dropB, 'two CustomDrop calls in the same second produce different ids')
H.ok(state[key('drop', dropA)] ~= nil and state[key('drop', dropB)] ~= nil, 'both drops exist as separate inventories')
Ox.CreateTemporaryStash({ label = 'A' })
Ox.CreateTemporaryStash({ label = 'B' })
H.ok(api.temporaryIds[1] ~= api.temporaryIds[2], 'two CreateTemporaryStash calls produce different ids')

-- --- Tier 3/4: RemoveItem error vocabulary ---------------------------------

reset()
H.equal(select(2, Ox.RemoveItem('player:1', 'water', 'abc')), 'invalid_count', 'a non-numeric count is invalid_count')
H.equal(select(2, Ox.RemoveItem('player:1', 'water', 0)), 'negative_count', 'a zero count is negative_count')
H.equal(select(2, Ox.RemoveItem('player:1', 'water', -3)), 'negative_count', 'a negative count is negative_count')
H.equal(select(2, Ox.RemoveItem('player:1', 'water', 99)), 'not_enough_items', 'an inventory-wide shortfall is not_enough_items')
H.equal(select(2, Ox.RemoveItem('player:1', 'water', 99, nil, 1)), 'not_enough_items_in_slot', 'a shortfall in a named slot is not_enough_items_in_slot')
H.equal(select(2, Ox.RemoveItem('player:1', 'water', 1, nil, 3)), 'no_item_in_slot', 'the wrong item in a named slot is no_item_in_slot')
H.equal(select(2, Ox.RemoveItem('player:1', 'nonexistent', 1)), 'invalid_item', 'an unknown item is invalid_item')
H.equal(Ox.RemoveItem('player:1', 'water', 2, nil, 1), true, 'a valid removal succeeds')
H.equal(state['player:1'].items[1], nil, 'the emptied slot is cleared')

-- --- Tier 3/4: capacity return shapes --------------------------------------

reset()
H.equal(Ox.CanCarryItem('nope', 'water', 1), nil, 'CanCarryItem is nil, not false, for an unresolvable inventory')
H.equal(Ox.CanCarryItem('player:1', 'nonexistent', 1), nil, 'CanCarryItem is nil for an unknown item')
H.equal(Ox.CanCarryItem('player:1', 'water', 1), true, 'CanCarryItem is true when the item fits')
H.equal(Ox.CanCarryItem('stash:box', 'bread', 20), false, 'CanCarryItem is false when the item does not fit')
-- stash:box holds 5 of 100; water is 10 each, so floor(95/10) = 9 -- unclamped,
-- with no free-slot term, exactly as upstream.
H.equal(Ox.CanCarryAmount('stash:box', 'water'), 9, 'CanCarryAmount is the unclamped weight quotient')
state['stash:box'].maxWeight = 1
H.equal(Ox.CanCarryAmount('stash:box', 'water'), -1, 'an overweight inventory reports a negative amount, as upstream')
H.equal(Ox.CanCarryAmount('nope', 'water'), nil, 'CanCarryAmount is nil for an unresolvable inventory')

-- --- Tier 3/4: exports that return nothing ---------------------------------

reset()
H.equal(argc(Ox.SetMetadata('player:1', 3, { quality = 50 })), 0, 'SetMetadata returns nothing')
H.equal(state['player:1'].items[3].metadata.quality, 50, 'SetMetadata still writes the metadata')
H.equal(state['player:1'].items[3].info.quality, 50, 'SetMetadata keeps the native info field in step')
H.equal(argc(Ox.SetDurability('player:1', 3, 42)), 0, 'SetDurability returns nothing')
H.equal(state['player:1'].items[3].metadata.durability, 42, 'SetDurability still writes the durability')
H.equal(argc(Ox.SetSlotCount('stash:box', 8)), 0, 'SetSlotCount returns nothing')
H.equal(state['stash:box'].slots, 8, 'SetSlotCount still resizes a secondary inventory')
H.equal(argc(Ox.SetMaxWeight('stash:box', 500)), 0, 'SetMaxWeight returns nothing')
H.equal(state['stash:box'].maxWeight, 500, 'SetMaxWeight still recaps a secondary inventory')
H.equal(argc(Ox.ClearInventory('player:1')), 0, 'ClearInventory returns nothing')
H.equal(next(state['player:1'].items), nil, 'ClearInventory still empties the inventory')
H.equal(argc(Ox.RemoveInventory('stash:box')), 0, 'RemoveInventory returns nothing')
H.equal(state['stash:box'], nil, 'RemoveInventory still removes the record')
H.equal(argc(Ox.RegisterShop('gun', { label = 'Guns' })), 0, 'RegisterShop returns nothing')
H.equal(api.shop.shopType, 'gun', 'RegisterShop still forwards to the authority')
H.equal(argc(Ox.RegisterShop('gun', 'not a table')), 0, 'RegisterShop rejects a non-table without returning')
H.equal(argc(Ox.removeHooks(7)), 0, 'removeHooks returns nothing')
H.equal(api.removedHook, 7, 'removeHooks still forwards the id')
H.equal(argc(Ox.getBank(1)), 0, 'getBank returns nothing, matching upstream\'s no-op pefcl stub')

reset()
H.equal(argc(Ox.setPlayerInventory(1, { [1] = { slot = 1, name = 'bread', amount = 2 } })), 0, 'setPlayerInventory returns nothing')
H.equal(state['player:1'].items[1].name, 'bread', 'setPlayerInventory still writes through the authority funnel')
H.equal(count(state['player:1'].items), 1, 'setPlayerInventory replaces the whole item table')

reset()
H.equal(argc(Ox.ConfiscateInventory(1)), 0, 'ConfiscateInventory returns nothing')
H.equal(next(state['player:1'].items), nil, 'ConfiscateInventory empties the player')
H.equal(count(state['confiscation:1'].items), 3, 'ConfiscateInventory stores the items under a confiscation record')
H.equal(argc(Ox.ReturnInventory(1)), 0, 'ReturnInventory returns nothing')
H.equal(count(state['player:1'].items), 3, 'ReturnInventory restores the items')
H.equal(state['confiscation:1'], nil, 'ReturnInventory removes the confiscation record')

-- --- Tier 3/4: RegisterStash accepts upstream's 8th parameter ---------------

reset()
H.equal(argc(Ox.RegisterStash('vault', 'Vault', 10, 900, 'CID1', nil, nil, 'instance-3')), 0, 'RegisterStash returns nothing')
H.equal(api.stash.slots, 10, 'RegisterStash forwards the first seven arguments')
H.equal(state['stash:vault'].instance, 'instance-3', 'RegisterStash records upstream\'s instance parameter')

-- --- accepted divergences, asserted so they stay deliberate -----------------

reset()
local snapshot = Ox.GetInventory('player:1')
snapshot.items[1].amount = 999
snapshot.items[2] = nil
H.equal(state['player:1'].items[1].amount, 2, 'GetInventory is a DETACHED snapshot; mutating it cannot reach the authority')
H.ok(state['player:1'].items[2] ~= nil, 'deleting from the snapshot cannot delete a real slot')
H.equal(Ox.Inventory('player:1').weight, 70, 'Inventory is the same snapshot, with a computed weight')
local itemsOnly = Ox.GetInventoryItems('player:1')
itemsOnly[3] = nil
H.ok(state['player:1'].items[3] ~= nil, 'GetInventoryItems is detached too')

reset()
Ox.SetSlotCount(1, 9)
H.equal(state['player:1'].slots, 5, 'player slot counts stay owned by qbcore')
Ox.SetMaxWeight(1, 9999)
H.equal(state['player:1'].maxWeight, 1000, 'player max weight stays owned by qbcore')
H.equal(#warnings, 2, 'each refused player-dimension change is reported, not silently dropped')

reset()
Ox.SetMetadata('player:1', 3, { weight = 5 })
H.equal(state['player:1'].items[3].metadata.weight, 5, 'metadata weight is retained')
H.equal(I.totalWeight(state['player:1'].items), 55, 'metadata weight changes the authoritative total')

-- --- useItem is published on the SERVER identity too ------------------------
--
-- Previously only client/compat/ox.lua and kora_inventory's own native api
-- carried this name; exports.ox_inventory:useItem(...) on the server
-- resolved to nothing.

reset()
local usedOk = Ox.useItem(1, 3)
H.equal(usedOk, true, 'useItem delegates to the native use-item funnel and reports success')
H.equal(api.usedItem.src, 1, 'useItem forwards the source')
H.equal(api.usedItem.slotOrName, 3, 'useItem forwards the slot')
local failedOk, failedErr = Ox.useItem(1, 99)
H.equal(failedOk, false, 'useItem reports failure for an empty slot')
H.equal(failedErr, 'item not found', 'useItem forwards the native funnel\'s error')
local cbResult, cbErr
Ox.useItem(1, 3, function(ok, err) cbResult, cbErr = ok, err end)
H.equal(cbResult, true, 'useItem invokes an optional callback with the result')
H.equal(Ox.useItem('not-a-number', 1), false, 'useItem refuses a non-numeric source')

-- --- ConvertInventory converts a whole inventory record ---------------------

reset()
local live = Ox.ConvertInventory('player:1')
H.equal(live.id, 1, 'ConvertInventory resolves a known reference like GetInventory')
H.equal(live.items[3].name, 'bread', 'a resolved reference is returned already in ox item shape')
live.items[3] = nil
H.ok(state['player:1'].items[3] ~= nil, 'ConvertInventory returns a detached snapshot for a resolved reference')

local raw = Ox.ConvertInventory({
    id = 'migrated', label = 'Migrated', type = 'stash', slots = 10, maxWeight = 1000,
    items = { water = 3, bread = { name = 'bread', amount = 2, info = { quality = 50 } } },
})
H.equal(raw.id, 'migrated', 'ConvertInventory preserves the id of an unregistered raw payload')
H.equal(raw.type, 'stash', 'ConvertInventory preserves the type of an unregistered raw payload')
local rawByName = {}
for _, it in pairs(raw.items) do rawByName[it.name] = it end
H.equal(rawByName.water.count, 3, 'a bare name -> count entry converts into a counted ox item')
H.equal(rawByName.bread.count, 2, 'a name -> item table entry keeps its count')
H.equal(rawByName.bread.metadata.quality, 50, 'a name -> item table entry keeps its metadata')
H.equal(raw.weight, (3 * 10) + (2 * 20), 'ConvertInventory recomputes weight from the real item registry')
H.equal(Ox.ConvertInventory('no-such-reference'), nil, 'an unresolvable string reference with no items table converts to nil')

print = realPrint
H.finish()
