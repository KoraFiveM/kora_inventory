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
QbInventory.internal.createItemHook = function(_, _, _, _, info) return true, info end
QbInventory.internal.bump = function() bumps = bumps + 1 end
QbInventory.internal.broadcast = function() broadcasts = broadcasts + 1 end
-- Mirrors server.lua's addTo/removeFrom write funnel closely enough to prove
-- AddToStash/RemoveFromStash route through it rather than mutating items
-- directly: an explicit slot is honoured, a matching existing slot stacks,
-- and a fresh placement takes the first free slot.
QbInventory.internal.addTo = function(k, name, amount, slot, info)
    local items = state[k].items
    if slot then
        local existing = items[slot]
        if existing and existing.name:lower() ~= name then return false, 'slot occupied by another item' end
        if existing then existing.amount = existing.amount + amount
        else items[slot] = { slot = slot, name = name, amount = amount, weight = 10, info = info or {} } end
        return true, slot
    end
    for s, existing in pairs(items) do
        if existing.name:lower() == name then existing.amount = existing.amount + amount; return true, s end
    end
    for s = 1, 20 do
        if not items[s] then
            items[s] = { slot = s, name = name, amount = amount, weight = 10, info = info or {} }
            return true, s
        end
    end
    return false, 'no free slot'
end
QbInventory.internal.removeFrom = function(k, slot, amount)
    local items = state[k].items
    local existing = items[slot]
    if not existing or existing.amount < amount then return false, 'not enough of item' end
    existing.amount = existing.amount - amount
    if existing.amount <= 0 then items[slot] = nil end
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

-- upstream signature fidelity
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

-- OpenShop(source, name) must enter the native typed-shop path.
H.equal(registered.OpenShop(7, 'ammunation'), true, 'OpenShop forwards native success')
H.equal(calls.open.src, 7, 'OpenShop preserves source')
H.equal(calls.open.a, 'ammunation', 'OpenShop forwards the actual shop identifier')
H.equal(calls.open.b.type, 'shop', 'OpenShop requests the shop path')
H.equal(calls.open.b.id, 'ammunation', 'OpenShop selects the registered shop')
local originalOpen = QbInventory.api.OpenInventory
local nativePayload = { token = 'shop-session' }
QbInventory.api.OpenInventory = function() return true, nativePayload end
local shopOK, shopResult = registered.OpenShop(7, 'ammunation')
H.equal(shopOK, true, 'OpenShop preserves success boolean')
H.equal(shopResult, nativePayload, 'OpenShop preserves native payload identity')
QbInventory.api.OpenInventory = function() return false, 'access denied' end
shopOK, shopResult = registered.OpenShop(7, 'ammunation')
H.equal(shopOK, false, 'OpenShop preserves failure boolean')
H.equal(shopResult, 'access denied', 'OpenShop preserves native failure reason')
QbInventory.api.OpenInventory = originalOpen

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

-- AddToStash / RemoveFromStash were entirely unbound on both realms. They
-- must route through the addTo/removeFrom write funnel (proven by the
-- bump/broadcast counters below), not mutate stash items directly.
-- state['stash:locker'].items is now { [1] = water x1 } after the SetInventory
-- call above replaced the stash's whole item table.
bumps, broadcasts = 0, 0
H.equal(registered.AddToStash('locker', 'bread', 2), true, 'AddToStash accepts an item with no explicit slot')
H.equal(state['stash:locker'].items[2].name, 'bread', 'AddToStash places the item in the first free slot')
H.equal(state['stash:locker'].items[2].amount, 2, 'AddToStash writes the requested amount')
H.equal(bumps, 1, 'a successful AddToStash bumps the inventory revision')
H.equal(broadcasts, 1, 'a successful AddToStash broadcasts the inventory')

H.equal(registered.AddToStash('locker', 'WATER', 3, 1), true, 'AddToStash accepts an explicit slot and a mixed-case item name')
H.equal(state['stash:locker'].items[1].amount, 4, 'AddToStash stacks onto the existing slot 1 water')

H.equal(registered.AddToStash('locker', 'bread', 1, 1), false, 'AddToStash refuses a slot already holding a different item')
H.equal(state['stash:locker'].items[1].amount, 4, 'a refused AddToStash leaves the occupied slot untouched')

H.equal(registered.AddToStash('nope', 'water', 1), false, 'AddToStash is false for an unresolvable stash')
H.equal(registered.AddToStash('locker', 'water', 0), false, 'AddToStash is false for a non-positive amount')

bumps, broadcasts = 0, 0
H.equal(registered.RemoveFromStash('locker', 'bread', 1), true, 'RemoveFromStash removes from the matching slot by name')
H.equal(state['stash:locker'].items[2].amount, 1, 'RemoveFromStash decrements the matched slot')
H.equal(bumps, 1, 'a successful RemoveFromStash bumps the inventory revision')
H.equal(broadcasts, 1, 'a successful RemoveFromStash broadcasts the inventory')

H.equal(registered.RemoveFromStash('locker', 'bread', 1, 2), true, 'RemoveFromStash accepts an explicit slot')
H.equal(state['stash:locker'].items[2], nil, 'removing the last of a slot clears it entirely')

H.equal(registered.RemoveFromStash('locker', 'water', 999), false, 'RemoveFromStash refuses a shortfall across the whole stash')
H.equal(state['stash:locker'].items[1].amount, 4, 'a refused RemoveFromStash leaves the stash untouched')
H.equal(registered.RemoveFromStash('locker', 'water', 1, 5), false, 'RemoveFromStash refuses an explicit slot that holds nothing')
H.equal(state['stash:locker'].items[1].amount, 4, 'a refused slot-targeted RemoveFromStash leaves the stash untouched')

H.equal(registered.RemoveFromStash('nope', 'water', 1), false, 'RemoveFromStash is false for an unresolvable stash')
H.equal(registered.RemoveFromStash('locker', 'water', 4, 1), true, 'RemoveFromStash can drain a named slot completely')
H.equal(state['stash:locker'].items[1], nil, 'draining a slot to zero clears it')

H.finish()
