-- qb-inventory 2.x AddHook / RemoveHook / AddListener / RemoveListener.
--
-- Upstream keeps one hook list and one listener list per event and calls them
-- as `callback(subtype, data)`: a hook runs before the action and cancels it by
-- returning false, a listener runs afterwards. Here the registry is the same,
-- but the engine events are not raised by this file. Moves, drops, uses,
-- purchases and opens are fired by kora_inventory's own ox-style hook
-- dispatcher, which already runs them before commit and settles them after, so
-- this module subscribes to that dispatcher lazily (on the first AddHook or
-- AddListener for an event) and translates its payloads to upstream's shapes.
-- ItemAdded and ItemRemoved belong to the AddItem/RemoveItem compat wrappers in
-- qb.lua, which call trigger()/notify() directly, as upstream does; internal
-- moves never raise them.
--
-- The callbacks are trusted server callbacks registered by other resources and
-- are pcall'd. The payloads are detached copies, so a hook can veto an action
-- but cannot reach live inventory state.

local inventory = assert(KoraInventory, 'kora_inventory authority missing')
local internal = assert(inventory.internal, 'kora_inventory internal authority must load before qb hook compatibility')
local api = assert(inventory.api, 'kora_inventory api must load before qb hook compatibility')

local EVENT_NAMES = {
    'ItemMoved',
    'ItemDropped',
    'ItemUsed',
    'ItemBought',
    'ItemAdded',
    'ItemRemoved',
    'InventoryOpened',
    'ShopOpened',
}

local events = {}
for _, name in ipairs(EVENT_NAMES) do
    events[name] = { hooks = {}, listeners = {} }
end

local function slotNumber(value)
    if type(value) == 'table' then
        return value.slot
    end
    return value
end

local function shopType(shop)
    return shop.type or (tostring(shop.id):gsub('%d+$', ''))
end

local function inventoryType(inv)
    if inv.type == 'player' or inv.type == 'trunk' or inv.type == 'glovebox' or inv.type == 'drop' then
        return inv.type
    end
    if inv.type == 'shop' then
        return shopType(inv)
    end
    return 'inventory'
end

local function inventoryId(inv)
    if inv.type == 'player' then
        return inv.source or inv.id
    end
    if inv.type == 'trunk' or inv.type == 'glovebox' or inv.type == 'drop' then
        return ('%s-%s'):format(inv.type, tostring(inv.id))
    end
    return inv.id
end

local function snapshot(inventoryKey)
    local inv = internal.getInventory(inventoryKey)
    if not inv then
        return nil
    end
    return {
        label = inv.label,
        slots = inv.slots,
        maxweight = inv.maxWeight,
        items = internal.copy(inv.items or {}),
    }
end

local function shopRecord(shop)
    return {
        name = shop.id,
        label = shop.label,
        coords = internal.copy(shop.coords),
        slots = shop.slots,
        items = internal.copy(shop.stock or shop.items or {}),
        type = shopType(shop),
    }
end

local function heldItem(inventoryKey, slot, amount)
    local inv = internal.getInventory(inventoryKey)
    local held = inv and inv.items and inv.items[tonumber(slot)]
    if not held then
        return nil
    end
    local copy = internal.copy(held)
    if amount then
        copy.amount = amount
    end
    return copy
end

local translators = {}

function translators.swapItems(payload)
    local src = payload.source
    if payload.toInventory == 'newdrop' then
        payload.qbItem = payload.qbItem
            or heldItem(payload.fromKey, slotNumber(payload.fromSlot), payload.count)
        if not payload.qbItem then
            return nil
        end
        if not payload.koraCoords then
            local ped = GetPlayerPed(src)
            payload.koraCoords = ped and GetEntityCoords(ped) or nil
        end
        return 'ItemDropped', payload.qbItem.type, {
            source = src,
            sourceInventory = snapshot(payload.fromKey),
            coords = payload.koraCoords,
            item = payload.qbItem,
            amount = payload.count,
        }
    end
    if payload.action == 'give' then
        return 'ItemMoved', 'given', {
            fromType = 'player',
            toType = 'player',
            fromInventory = snapshot(payload.fromKey),
            toInventory = snapshot(payload.toKey),
            fromId = src,
            toId = payload.toInventory,
            fromSlot = slotNumber(payload.fromSlot),
            amount = payload.count,
        }
    end
    local from, to = internal.getInventory(payload.fromKey), internal.getInventory(payload.toKey)
    if not from or not to then
        return nil
    end
    local moveType = ({ stack = 'stacked', swap = 'swapped' })[payload.action]
    if not moveType then
        local held = type(payload.fromSlot) == 'table' and tonumber(payload.fromSlot.count) or nil
        moveType = (held and tonumber(payload.count) and payload.count < held) and 'split' or 'moved'
    end
    return 'ItemMoved', moveType, {
        fromType = inventoryType(from),
        toType = inventoryType(to),
        fromInventory = snapshot(payload.fromKey),
        toInventory = snapshot(payload.toKey),
        fromId = inventoryId(from),
        toId = inventoryId(to),
        fromSlot = slotNumber(payload.fromSlot),
        toSlot = slotNumber(payload.toSlot),
        amount = payload.count,
    }
end

function translators.usingItem(payload)
    local item = payload.qbItem or heldItem(payload.inventoryKey, slotNumber(payload.item))
    if not item then
        return nil
    end
    payload.qbItem = item
    return 'ItemUsed', item.type, {
        source = payload.source,
        sourceInventory = snapshot(payload.inventoryKey),
        item = item,
    }
end

function translators.buyItem(payload)
    local shop = internal.getInventory(payload.fromKey)
    if not shop then
        return nil
    end
    local stocked = (shop.stock or shop.items or {})[tonumber(slotNumber(payload.fromSlot))]
    if not stocked then
        return nil
    end
    local kind = shopType(shop)
    return 'ItemBought', kind, {
        shopType = kind,
        shop = shopRecord(shop),
        toId = payload.source,
        item = internal.copy(stocked),
        amount = payload.count,
        totalPrice = payload.totalPrice,
    }
end

function translators.openInventory(payload)
    local inv = internal.getInventory(payload.inventoryKey)
    if not inv then
        return nil
    end
    return 'InventoryOpened', inventoryType(inv), {
        source = payload.source,
        sourceInventory = snapshot(internal.playerKey(payload.source)),
        inventoryId = inventoryId(inv),
        inventory = snapshot(payload.inventoryKey),
    }
end

function translators.openShop(payload)
    local shop = internal.getInventory(payload.inventoryKey)
    if not shop then
        return nil
    end
    return 'ShopOpened', shopType(shop), {
        source = payload.source,
        sourceInventory = snapshot(internal.playerKey(payload.source)),
        shop = shopRecord(shop),
    }
end

local engineEvents = {
    ItemMoved = 'swapItems',
    ItemDropped = 'swapItems',
    ItemUsed = 'usingItem',
    ItemBought = 'buyItem',
    InventoryOpened = 'openInventory',
    ShopOpened = 'openShop',
}

local function trigger(eventName, subtype, data)
    local event = events[eventName]
    if not event then
        return nil
    end
    local result
    local list = event.hooks
    for i = 1, #list do
        local hook = list[i]
        if hook then
            local ok, response = pcall(hook.fn, subtype, data)
            if ok then
                if response == false then
                    return false
                elseif response ~= nil then
                    result = response
                end
            end
        end
    end
    return result
end

local function notify(eventName, subtype, data)
    local event = events[eventName]
    if not event then
        return
    end
    local list = event.listeners
    for i = 1, #list do
        local listener = list[i]
        if listener then
            pcall(listener.fn, subtype, data)
        end
    end
end

local function active(eventName)
    local event = events[eventName]
    if not event then
        return false
    end
    for _, list in ipairs({ event.hooks, event.listeners }) do
        for i = 1, #list do
            if list[i] then
                return true
            end
        end
    end
    return false
end

local bridged = {}

local function bridge(engineEvent)
    if bridged[engineEvent] then
        return
    end
    bridged[engineEvent] = true
    local translate = translators[engineEvent]
    local hookId = api.registerHook(engineEvent, function(payload)
        local name, subtype, data = translate(payload)
        if name and trigger(name, subtype, data) == false then
            return false
        end
    end, { koraKeys = false })
    AddEventHandler(hookId, function(success, payload)
        if success ~= true or type(payload) ~= 'table' then
            return
        end
        local name, subtype, data = translate(payload)
        if name then
            notify(name, subtype, data)
        end
    end)
end

local function add(field, eventName, callback)
    local event = events[eventName]
    if not eventName or not callback then
        return nil
    end
    if not event then
        print(('^3[kora_inventory]^7 qb-inventory hook: invalid event %s'):format(tostring(eventName)))
        return nil
    end
    if not inventory.isCallable(callback) then
        return nil
    end
    local list = event[field]
    local index = #list + 1
    list[index] = { fn = callback, resource = GetInvokingResource() }
    if engineEvents[eventName] then
        bridge(engineEvents[eventName])
    end
    return index
end

local function remove(field, eventName, index)
    local event = events[eventName]
    if not event or type(index) ~= 'number' then
        return
    end
    local list = event[field]
    if list[index] then
        list[index] = false
    end
end

AddEventHandler('onResourceStop', function(resource)
    for _, event in pairs(events) do
        for _, list in ipairs({ event.hooks, event.listeners }) do
            for i = 1, #list do
                if list[i] and list[i].resource == resource then
                    list[i] = false
                end
            end
        end
    end
end)

inventory.compat = inventory.compat or {}
inventory.compat.koraHooks = { trigger = trigger, notify = notify, active = active }

local qb = assert(inventory.compat.qb, 'qb compatibility must load before qb hook compatibility')
qb.AddHook = function(eventName, callback)
    return add('hooks', eventName, callback)
end
qb.RemoveHook = function(eventName, index)
    return remove('hooks', eventName, index)
end
qb.AddListener = function(eventName, callback)
    return add('listeners', eventName, callback)
end
qb.RemoveListener = function(eventName, index)
    return remove('listeners', eventName, index)
end
