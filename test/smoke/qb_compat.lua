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

local function resolve(ref, preferred)
    if type(ref) == 'number' then return 'player:' .. ref, state['player:' .. ref] end
    if type(ref) ~= 'string' then return nil, nil end
    if state[ref] then return ref, state[ref] end
    local key = preferred and (preferred .. ':' .. ref) or ref
    return key, state[key]
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

dofile('server/compat/qb.lua')

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
local inventory = registered.GetInventory('evidence')
H.equal(inventory.maxweight, 80, 'inventory snapshot includes qb maxweight')
inventory.items[1] = { name = 'tamper' }
H.equal(state['stash:evidence'].items[1], nil, 'inventory snapshot is detached')
H.equal(registered.CanAddItem('locker', 'WATER', 2), true, 'can add delegates to authority')
H.equal(registered.RemoveInventory('evidence'), true, 'remove inventory delegates to authority')
H.ok(removed['stash:evidence'], 'secondary inventory is removed')

H.finish()
