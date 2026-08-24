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
        shouldClose = true, preventClose = true, useTime = true })[dataKey] then return false end
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

-- This module does NOT call exports(). It builds a table which
-- server/compat/providers.lua publishes under the `qb-inventory` identity
-- through __cfx_export_qb-inventory_<name> handlers -- a namespace entirely
-- separate from qbinventory's own flat export table. That separation is what
-- lets GetInventory and CanAddItem keep their upstream qb-inventory return
-- shapes here while server.lua's native exports of the same names keep theirs.
-- (An earlier version of this file did call exports() and silently overwrote
-- the native ones; test/smoke/export_collisions.lua guards that regression.)
local api = {
    GetSlotsByItem = slotsByItem,
    GetFirstSlotByItem = firstSlotByItem,
    GetTotalWeight = function(items) return internal.totalWeight(items) end,
    GetSlots = slots,
    SetItemData = setItemData,
    ClearStash = clearStash,
    CreateInventory = createInventory,
    RemoveInventory = removeInventory,
}

-- Full upstream qb-inventory compatibility uses the same authority methods,
-- but keeps its provider-specific return shapes separate from qbinventory's
-- native exports (and from ox_inventory's identically named exports).
-- I.api is installed by server.lua in the live resource. Keeping a blank
-- fallback permits this transport-free adapter to be unit-tested in isolation.
local native = I.api or {}

---Upstream: LoadInventory(source, citizenid) -> slot-keyed item table.
---`citizenid` is accepted and ignored: qbcore owns player persistence and has
---already loaded PlayerData.items by the time anything can call this.
api.LoadInventory = function(source, _citizenid) return I.copy(native.GetInventory(source) or {}) end

---Upstream: SaveInventory(source, offline). Player items are written through
---qbcore's own mutation funnel, so there is nothing to flush for a player.
---Secondary inventories DO have durable state of their own, so honour the call
---by flushing them rather than pretending the whole thing is a no-op.
api.SaveInventory = function(_source, _offline)
    local persistence = I.persistence
    if persistence and type(persistence.flush) == 'function' then pcall(persistence.flush) end
    return true
end

---Upstream: SetInventory(identifier, items, reason). The identifier may be a
---player source OR a secondary inventory id, so route non-players through the
---authority write funnel instead of only handling players.
api.SetInventory = function(identifier, items, reason)
    items = items or {}
    local inventoryKey, inventory = resolve(identifier)
    if inventory and inventory.type == 'player' then
        return native.SetInventory(inventory.source or identifier, items, reason)
    end
    if not inventory then return false end
    return internal.lock({ inventoryKey }, function()
        return internal.setInventoryItems(inventoryKey, items)
    end)
end

---Upstream: UseItem(itemName, ...) -- the first argument is the ITEM NAME and
---the varargs are forwarded to the registered handler, which upstream calls as
---(source, itemData). qbinventory's own earlier compat shape was
---UseItem(source, item); both are accepted so neither caller breaks.
api.UseItem = function(first, second, third)
    if type(first) == 'string' then
        local source = tonumber(second)
        if not source then return false, 'UseItem requires a player source' end
        return native.useItem(source, (type(third) == 'table' and third.slot) or first)
    end
    return native.useItem(first, type(second) == 'table' and second.slot or second)
end

api.OpenInventoryById = function(source, target) return I.internal.open(source, 'player:' .. tostring(tonumber(target) or -1)) end

---Upstream: CreateShop(shopData) -- ONE table. `shopData.name` names the shop;
---a table with no `name` is treated as a collection of shops keyed by name.
---The older CreateShop(name, data) form is still accepted.
api.CreateShop = function(first, second)
    if type(first) == 'string' then return native.RegisterShop(first, second or {}) end
    if type(first) ~= 'table' then return nil, 'CreateShop requires a shop table' end
    if first.name then return native.RegisterShop(first.name, first) end

    local last, err
    for shopName, shopData in pairs(first) do
        if type(shopData) == 'table' then
            last, err = native.RegisterShop(shopData.name or shopName, shopData)
            if not last then return nil, err end
        end
    end
    return last
end

api.OpenShop = function(source, name) return native.OpenInventory(source, 'shop', name) end
api.OpenInventory = function(source, identifier, data) return native.OpenInventory(source, identifier, data) end

---Upstream: CloseInventory(source, identifier). qbinventory sessions are keyed
---by player, so the identifier is advisory -- closing the player's session is
---what actually releases the inventory either way. Kept as a WRAPPER rather
---than a direct `native.CloseInventory` reference: the value-copy form silently
---became nil under the `I.api or {}` fallback, and providers.lua's
---`type(fn) == 'function'` filter then dropped the export entirely.
api.CloseInventory = function(source, _identifier) return native.CloseInventory(source) end

---Upstream: GetInventory(identifier) -> the whole inventory record, not just
---its items. Returns the detached descriptor built above.
api.GetInventory = getInventory
api.GetItemBySlot = native.GetItemBySlot
api.GetItemByName = native.GetItemByName
api.GetItemsByName = native.GetItemsByName
api.GetItemCount = native.GetItemCount
api.GetFreeWeight = native.GetFreeWeight
-- Upstream HasItem(source, items, amount) accepts a name, an array of names,
-- or a {name = count} map, and returns a plain boolean. server.lua's native
-- hasItem already handles all three shapes identically, so this is a straight
-- wire-up -- it was simply never copied onto the compat table, which left
-- exports['qb-inventory']:HasItem(...) resolving to nothing on the server.
api.HasItem = native.HasItem
---Upstream: CanAddItem(identifier, item, amount) -> true, or false plus a
---reason of exactly 'weight' or 'slots' (bare false for an unresolvable
---inventory or unknown item). internal.canAdd already speaks that vocabulary
---and, unlike the native canCarry, accepts a secondary inventory identifier
---rather than only a player source.
api.CanAddItem = function(identifier, item, amount)
    local ok, reason = canAddItem(identifier, item, amount)
    if ok then return true end
    if reason == 'weight' or reason == 'slots' then return false, reason end
    return false
end
api.ClearInventory = native.ClearInventory
api.AddItem = native.AddItem
api.RemoveItem = native.RemoveItem

I.compat = I.compat or {}
I.compat.qb = api
