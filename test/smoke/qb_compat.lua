local H = dofile('test/harness.lua')

local registered = {}
exports = function(name, fn) registered[name] = fn end

QbInventory = {
    copy = function(value)
        if type(value) ~= 'table' then return value end
        local out = {}
        for k, v in pairs(value) do out[k] = QbInventory.copy(v) end
        return out
    end,
    internal = {},
}

local state = {
    ['player:7'] = {
        key = 'player:7', type = 'player', id = 7, label = 'Player', slots = 4, maxWeight = 100,
        items = {
            [1] = { slot = 1, name = 'Water', amount = 2, weight = 10, info = {} },
            [3] = { slot = 3, name = 'bread', amount = 1, weight = 20, info = {} },
        },
    },
    ['stash:locker'] = {
        key = 'stash:locker', type = 'stash', id = 'locker', label = 'Locker', slots = 3, maxWeight = 50,
        items = { [2] = { slot = 2, name = 'WATER', amount = 1, weight = 10, info = {} } },
    },
}
local removed, broadcasts, bumps = {}, 0, 0

-- Mirrors server.lua's resolveInventoryRef: a bare string is tried as a direct
-- key first, then against the preferred type, then SCANNED across the known
-- secondary kinds. The scan matters -- compat callers such as SetInventory and
-- GetInventory pass a plain identifier with no type hint.
local RESOLVE_KINDS = { 'stash', 'trunk', 'glovebox', 'container', 'shop', 'temporary', 'drop', 'evidence' }
local function resolve(ref, preferred)
    if type(ref) == 'number' then return 'player:' .. ref, state['player:' .. ref] end
    if type(ref) ~= 'string' then return nil, nil end
    if state[ref] then return ref, state[ref] end
    if preferred then
        local key = preferred .. ':' .. ref
        if state[key] then return key, state[key] end
    end
    for _, kind in ipairs(RESOLVE_KINDS) do
        local key = kind .. ':' .. ref
        if state[key] then return key, state[key] end
    end
    return (preferred and (preferred .. ':' .. ref) or ref), nil
end

QbInventory.internal.resolveInventory = resolve
QbInventory.internal.copy = QbInventory.copy
QbInventory.internal.totalWeight = function(items)
    local total = 0
    for _, item in pairs(items or {}) do total = total + (item.weight or 0) * (item.amount or 0) end
    return total
end
QbInventory.internal.lock = function(_, fn) return fn() end
QbInventory.internal.setInventoryItems = function(key, items)
    state[key].items = QbInventory.copy(items)
    return true
end
QbInventory.internal.createSecondary = function(kind, id, data)
    state[kind .. ':' .. id] = { key = kind .. ':' .. id, type = kind, id = id, label = data.label, slots = data.slots or 50,
        maxWeight = data.maxWeight or 100000, items = QbInventory.copy(data.items or {}) }
end
QbInventory.internal.removeSecondary = function(key) removed[key] = true; state[key] = nil; return true end
QbInventory.internal.canAdd = function(identifier, name, amount)
    H.equal(identifier, 'locker', 'adapter preserves inventory identifier')
    H.equal(name, 'water', 'adapter normalises item name')
    H.equal(amount, 2, 'adapter preserves amount')
    return true
end

-- server.lua installs I.api in the live resource; without a stub here
-- `local native = I.api or {}` leaves every delegating entry calling a nil
-- field, so half the compat surface was asserted vacuously.
local calls = {}
QbInventory.api = {
    GetInventory = function(src) return state['player:' .. src] and state['player:' .. src].items or {} end,
    SetInventory = function(src, items, reason)
        calls.setInventory = { src = src, items = items, reason = reason }
        state['player:' .. src].items = QbInventory.copy(items)
        return true
    end,
    useItem = function(src, slotOrName) calls.useItem = { src = src, slotOrName = slotOrName }; return true end,
    RegisterShop = function(id, data) calls.shops = calls.shops or {}; calls.shops[id] = data; return 'shop:' .. id end,
    OpenInventory = function(src, a, b) calls.open = { src = src, a = a, b = b }; return true end,
    CloseInventory = function(src) calls.close = { src = src, argc = select('#', src) }; return true end,
    HasItem = function(src, names, amount) calls.hasItem = { src = src, names = names, amount = amount }; return true end,
    GetItemBySlot = function() end, GetItemByName = function() end, GetItemsByName = function() end,
    GetItemCount = function() end, GetFreeWeight = function() end,
    ClearInventory = function() end, AddItem = function() end, RemoveItem = function() end,
}

dofile('server/compat/qb.lua')
registered = QbInventory.compat.qb

H.equal(#registered.GetSlotsByItem(state['player:7'].items, 'wAtEr'), 1, 'case-insensitive slot list')
H.equal(registered.GetSlotsByItem(state['player:7'].items, 'water')[1], 1, 'slot list is numeric and sorted')
H.equal(registered.GetFirstSlotByItem(state['player:7'].items, 'BREAD'), 3, 'case-insensitive first slot')
H.equal(registered.GetTotalWeight(state['player:7'].items), 40, 'weight delegates to authority helper')
local used, free = registered.GetSlots(7)
H.equal(used, 2, 'player used slot count')
H.equal(free, 2, 'player free slot count')
H.equal(registered.SetItemData(7, 'water', 'description', 'clean', 1), true, 'item data updates by case-insensitive item name')
H.equal(state['player:7'].items[1].description, 'clean', 'item update committed through authority helper')
H.equal(registered.SetItemData(7, 'bread', 'quality', 90), true, 'item data finds first matching slot')
H.equal(state['player:7'].items[3].quality, 90, 'first matching slot updated')
registered.ClearStash('locker')
H.equal(next(state['stash:locker'].items), nil, 'stash clear commits empty item table')
registered.CreateInventory('evidence', { label = 'Evidence', slots = 8, maxweight = 80 })
H.equal(state['stash:evidence'].label, 'Evidence', 'create inventory maps label')
H.equal(state['stash:evidence'].maxWeight, 80, 'create inventory maps qb maxweight')
-- Upstream GetInventory(identifier) returns the whole inventory record, not
-- just its items. The ByIdentifier-suffixed aliases these used to go through
-- existed only to dodge an export-table collision that no longer exists --
-- compat is published under its own provider identity now.
local inventory = registered.GetInventory('evidence')
H.equal(inventory.maxweight, 80, 'inventory snapshot includes qb maxweight')
H.equal(inventory.slots, 8, 'inventory snapshot includes slots')
inventory.items[1] = { name = 'tamper' }
H.equal(state['stash:evidence'].items[1], nil, 'inventory snapshot is detached')
H.equal(registered.CanAddItem('locker', 'WATER', 2), true, 'can add delegates to authority')
H.equal(registered.RemoveInventory('evidence'), true, 'remove inventory delegates to authority')
H.ok(removed['stash:evidence'], 'secondary inventory is removed')

-- --- upstream signature fidelity ---
--
-- These are the shapes a real qb-inventory dependant calls with. Each one
-- diverged from upstream before this pass, so a stock third-party script would
-- have silently misbehaved rather than errored.

-- CreateShop(shopData) is ONE table upstream, with the name inside it.
registered.CreateShop({ name = 'ammunation', label = 'Ammu-Nation', items = {} })
H.ok(calls.shops and calls.shops['ammunation'] ~= nil, 'CreateShop accepts the single-table upstream form')
-- A table with no `name` is a collection of shops keyed by name.
registered.CreateShop({ vending = { label = 'Vending', items = {} }, hardware = { label = 'Hardware', items = {} } })
H.ok(calls.shops['vending'] ~= nil and calls.shops['hardware'] ~= nil, 'CreateShop registers a keyed collection of shops')
-- The older two-argument form still works.
registered.CreateShop('legacy', { label = 'Legacy' })
H.ok(calls.shops['legacy'] ~= nil, 'CreateShop still accepts the name+data form')

-- UseItem(itemName, source, itemData): the FIRST argument is the item name.
registered.UseItem('bandage', 7, { slot = 3 })
H.equal(calls.useItem.src, 7, 'UseItem reads the source from the second argument')
H.equal(calls.useItem.slotOrName, 3, 'UseItem forwards the itemData slot')
registered.UseItem('bandage', 7)
H.equal(calls.useItem.slotOrName, 'bandage', 'UseItem falls back to the item name when no itemData is given')
registered.UseItem(7, { slot = 2 })
H.equal(calls.useItem.slotOrName, 2, 'UseItem still accepts the older (source, item) form')

-- CanAddItem returns upstream's exact reason vocabulary.
QbInventory.internal.canAdd = function() return false, 'weight' end
local ok, reason = registered.CanAddItem('locker', 'water', 1)
H.equal(ok, false, 'CanAddItem reports failure')
H.equal(reason, 'weight', 'CanAddItem reports the upstream weight reason')
QbInventory.internal.canAdd = function() return false, 'slots' end
H.equal(select(2, registered.CanAddItem('locker', 'water', 1)), 'slots', 'CanAddItem reports the upstream slots reason')
QbInventory.internal.canAdd = function() return false, 'inventory' end
H.equal(select(2, registered.CanAddItem('nope', 'water', 1)), nil, 'an unresolvable inventory is a bare false, no reason')

-- HasItem is reachable at all -- it was missing from the compat table entirely.
H.equal(registered.HasItem(7, 'water', 2), true, 'HasItem is published on the qb identity')
H.equal(calls.hasItem.names, 'water', 'HasItem forwards its item argument')

-- SetInventory(identifier, items, reason) forwards the reason for a player and
-- routes a secondary identifier through the authority write funnel.
registered.SetInventory(7, { [1] = { slot = 1, name = 'bread', amount = 1, weight = 1 } }, 'admin-set')
H.equal(calls.setInventory.reason, 'admin-set', 'SetInventory forwards the upstream reason argument')
registered.SetInventory('locker', { [1] = { slot = 1, name = 'water', amount = 1, weight = 10 } })
H.equal(state['stash:locker'].items[1].name, 'water', 'SetInventory writes a secondary through the authority funnel')

-- CloseInventory tolerates upstream's second argument and stays a wrapper.
H.equal(type(registered.CloseInventory), 'function', 'CloseInventory is a live wrapper, not a load-time value copy')
registered.CloseInventory(7, 'stash-name')
H.equal(calls.close.src, 7, 'CloseInventory closes the calling player session')

-- LoadInventory accepts (source, citizenid).
H.ok(registered.LoadInventory(7, 'CID1') ~= nil, 'LoadInventory accepts the upstream citizenid argument')

H.finish()
