-- qb-inventory server export compatibility.
--
-- This module is deliberately transport-free.  It runs after server.lua and
-- talks only to QbInventory.internal, so player item writes continue through
-- qbcore's PlayerData mutation funnel and secondary changes keep their
-- qbinventory revision/broadcast guarantees.

local I = QbInventory
local internal = assert(I and I.internal, 'qbinventory internal authority must load before qb compatibility')

local function lower(value)
    return type(value) == 'string' and value:lower() or nil
end

local function slotsByItem(items, itemName)
    local wanted, found = lower(itemName), {}
    if not wanted or type(items) ~= 'table' then return found end
    for rawSlot, item in pairs(items) do
        if type(item) == 'table' and lower(item.name) == wanted then
            local slot = tonumber(rawSlot)
            if slot then found[#found + 1] = slot end
        end
    end
    table.sort(found)
    return found
end

local function firstSlotByItem(items, itemName)
    local found = slotsByItem(items, itemName)
    return found[1]
end

local function resolve(identifier, preferredType)
    return internal.resolveInventory(identifier, preferredType)
end

local function slots(identifier)
    local _, inventory = resolve(identifier)
    if not inventory then return 0, nil end
    local used = 0
    for _, item in pairs(inventory.items or {}) do
        if item then used = used + 1 end
    end
    return used, math.max(0, (tonumber(inventory.slots) or 0) - used)
end

local function setItemData(identifier, itemName, dataKey, value, slot)
    local wanted = lower(itemName)
    if not wanted or type(dataKey) ~= 'string' or dataKey == '' then return false end
    -- These are shared-definition mechanics, not mutable per-instance state.
    -- Letting a compatibility caller override them would invalidate capacity
    -- checks or turn a stackable item into a unique one mid-transaction.
    if ({ slot = true, name = true, amount = true, count = true, weight = true,
        type = true, unique = true, useable = true, label = true, image = true,
        shouldClose = true })[dataKey] then return false end
    local inventoryKey, inventory = resolve(identifier)
    if not inventory then return nil end

    return internal.lock({ inventoryKey }, function()
        -- Resolve and copy again inside the lock.  The copy is then committed
        -- with setInventoryItems rather than mutating a player table in place.
        local key, current = resolve(inventoryKey)
        if not current then return false end
        local selected
        if slot ~= nil then
            selected = tonumber(slot)
            local item = selected and current.items[selected]
            if not item or lower(item.name) ~= wanted then return false end
        else
            selected = firstSlotByItem(current.items, wanted)
            if not selected then return false end
        end
        local items = internal.copy(current.items)
        items[selected][dataKey] = internal.copy(value)
        return internal.setInventoryItems(key, items)
    end)
end

local function clearStash(identifier)
    if type(identifier) ~= 'string' or identifier == '' then return end
    local inventoryKey, inventory = resolve(identifier, 'stash')
    if not inventory or inventory.type ~= 'stash' then return end
    internal.lock({ inventoryKey }, function()
        -- setInventoryItems owns persistence, revision increments and live
        -- broadcasts for both player-safe and secondary inventories.
        internal.setInventoryItems(inventoryKey, {})
    end)
end

local function createInventory(identifier, data)
    if type(identifier) ~= 'string' or identifier == '' then return end
    local existing = select(2, resolve(identifier, 'stash'))
    if existing then return end
    data = type(data) == 'table' and data or {}
    internal.createSecondary('stash', identifier, {
        label = data.label or identifier,
        slots = data.slots,
        maxWeight = data.maxWeight or data.maxweight,
        items = data.items or data.inventory,
        coords = data.coords,
        owner = data.owner,
        groups = data.groups,
    })
end

local function removeInventory(identifier)
    if type(identifier) ~= 'string' or identifier == '' then return end
    local inventoryKey, inventory = resolve(identifier, 'stash')
    if not inventory or inventory.type == 'player' then return end
    -- The internal remover is intentionally authoritative: it evicts the
    -- in-memory record and removes durable secondary data together.
    return internal.removeSecondary(inventoryKey)
end

local function getInventory(identifier)
    if type(identifier) ~= 'string' or identifier == '' then return nil end
    local inventoryKey, inventory = resolve(identifier, 'stash')
    if not inventory then return nil end
    -- Upstream callers historically receive a table. Return a detached
    -- compatibility view so another resource cannot mutate live state.
    return {
        id = inventory.id,
        identifier = inventory.id,
        key = inventoryKey,
        label = inventory.label,
        slots = inventory.slots,
        maxweight = inventory.maxWeight,
        maxWeight = inventory.maxWeight,
        items = internal.copy(inventory.items or {}),
    }
end

local function canAddItem(identifier, itemName, amount)
    local wanted = lower(itemName)
    if not wanted then return false end
    return internal.canAdd(identifier, wanted, amount)
end

-- GetInventory/CanAddItem are deliberately NOT exported under those names:
-- server.lua already registers native exports with the same names
-- (GetInventory(src) takes a numeric player source; CanAddItem is the native
-- canCarry signature). Since exports() writes into one flat per-resource
-- table and this file loads after server.lua in fxmanifest.lua, reusing those
-- names would silently overwrite the native ones for every other resource
-- that calls them. Use the ByIdentifier-suffixed names below instead, which
-- match this module's string-identifier calling convention.
local api = {
    GetSlotsByItem = slotsByItem,
    GetFirstSlotByItem = firstSlotByItem,
    GetTotalWeight = function(items) return internal.totalWeight(items) end,
    GetSlots = slots,
    SetItemData = setItemData,
    ClearStash = clearStash,
    CreateInventory = createInventory,
    RemoveInventory = removeInventory,
    GetInventoryByIdentifier = getInventory,
    CanAddItemByIdentifier = canAddItem,
}

-- Full upstream qb-inventory compatibility uses the same authority methods,
-- but keeps its provider-specific return shapes separate from qbinventory's
-- native exports (and from ox_inventory's identically named exports).
-- I.api is installed by server.lua in the live resource. Keeping a blank
-- fallback permits this transport-free adapter to be unit-tested in isolation.
local native = I.api or {}
api.LoadInventory = function(source) return I.copy(native.GetInventory(source) or {}) end
api.SaveInventory = function(_) return true end -- qbcore persistence owns player writes.
api.SetInventory = function(source, items) return native.SetInventory(source, items or {}) end
api.UseItem = function(source, item) return native.useItem(source, type(item) == 'table' and item.slot or item) end
api.OpenInventoryById = function(source, target) return I.internal.open(source, 'player:' .. tostring(tonumber(target) or -1)) end
api.CreateShop = function(name, data) return native.RegisterShop(name, data or {}) end
api.OpenShop = function(source, name) return native.OpenInventory(source, 'shop', name) end
api.OpenInventory = function(source, identifier, data) return native.OpenInventory(source, identifier, data) end
api.CloseInventory = native.CloseInventory
api.GetInventory = function(identifier)
    local _, inv = resolve(identifier)
    return inv and I.copy(inv.items or {}) or nil
end
api.GetItemBySlot = native.GetItemBySlot
api.GetItemByName = native.GetItemByName
api.GetItemsByName = native.GetItemsByName
api.GetItemCount = native.GetItemCount
api.GetFreeWeight = native.GetFreeWeight
api.CanAddItem = native.CanAddItem
api.ClearInventory = native.ClearInventory
api.AddItem = native.AddItem
api.RemoveItem = native.RemoveItem

I.compat = I.compat or {}
I.compat.qb = api
