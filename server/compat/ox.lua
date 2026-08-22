-- ox_inventory server-export compatibility adapter.
--
-- This file deliberately does not register any exports or provide an
-- `ox_inventory` identity. server.lua owns the authority and decides when the
-- compatibility contract is complete enough to expose. Keeping this adapter
-- as a table also makes it safe to load alongside native qbinventory callers.
--
-- Required trusted seam (provided by server.lua):
--   QbInventory.internal.resolveInventory(reference, preferredType)
--   QbInventory.internal.{lock,setInventoryItems,canAdd,addTo,removeFrom}
--   QbInventory.internal.{itemDef,bump,broadcast,totalWeight,config}
-- Never call any of these from a client event. In particular, setInventoryItems
-- preserves qbcore as the only writer of player PlayerData.items.

QbInventory = QbInventory or {}
QbInventory.compat = QbInventory.compat or {}

local I = QbInventory
local core = assert(I.internal, 'qbinventory ox adapter loaded before server authority')
local Ox = {}

local function copy(value)
    return core.copy(value)
end

local function countOf(item)
    return math.floor(tonumber(item and (item.amount or item.count)) or 0)
end

local function itemMetadata(item)
    if type(item) ~= 'table' then return {} end
    return item.metadata or item.info or {}
end

local function normaliseMetadata(metadata)
    if metadata == nil then return nil end
    if type(metadata) == 'table' then return copy(metadata) end
    return { type = metadata }
end

local function contains(actual, expected)
    if expected == nil then return true end
    if type(actual) ~= 'table' or type(expected) ~= 'table' then return actual == expected end
    for key, value in pairs(expected) do
        if not contains(actual[key], value) then return false end
    end
    return true
end

local function identical(a, b)
    return contains(a or {}, b or {}) and contains(b or {}, a or {})
end

local function metadataMatches(actual, metadata, strict)
    metadata = normaliseMetadata(metadata)
    if metadata == nil then return true end
    if strict == nil then strict = true end
    return strict and identical(actual or {}, metadata) or contains(actual or {}, metadata)
end

local function resolve(reference, preferredType)
    local key, inv = core.resolveInventory(reference, preferredType)
    return key, inv
end

local function toOxItem(item)
    if not item then return nil end
    local out = copy(item)
    out.count = countOf(item)
    out.amount = out.count -- qbinventory callers retain their native field.
    out.metadata = copy(itemMetadata(item))
    out.info = copy(out.metadata)
    return out
end

local function toOxItems(items)
    local out = {}
    for rawSlot, item in pairs(items or {}) do
        local slot = tonumber(rawSlot) or item.slot
        if slot and item then
            local converted = toOxItem(item)
            converted.slot = slot
            out[slot] = converted
        end
    end
    return out
end

local function toOxInventory(key, inv)
    if not inv then return nil end
    return {
        id = inv.id,
        key = key,
        type = inv.type,
        label = inv.label,
        slots = inv.slots,
        maxWeight = inv.maxWeight,
        weight = core.totalWeight(inv.items),
        items = toOxItems(inv.items),
    }
end

local function itemName(item)
    if type(item) == 'table' then return item.name end
    return type(item) == 'string' and item:lower() or nil
end

local function matchingSlots(inv, requested, metadata, strict)
    local name = itemName(requested)
    if not inv or not name then return {} end
    local matches = {}
    for rawSlot, slotItem in pairs(inv.items or {}) do
        if slotItem and slotItem.name == name and metadataMatches(itemMetadata(slotItem), metadata, strict) then
            local slot = tonumber(rawSlot) or slotItem.slot
            if slot then matches[#matches + 1] = { slot = slot, item = slotItem } end
        end
    end
    table.sort(matches, function(a, b) return a.slot < b.slot end)
    return matches
end

local function mutateItems(reference, callback)
    local key, inv = resolve(reference)
    if not key or not inv then return false, 'invalid_inventory' end
    return core.lock({ key }, function()
        -- Resolve inside the lock; player inventory views are rebuilt from
        -- qbcore and must never be retained across the critical section.
        local currentKey, current = resolve(key)
        if not currentKey or not current then return false, 'invalid_inventory' end
        local items = copy(current.items)
        local ok, result, extra = callback(current, items)
        if not ok then return false, result end
        local stored, err = core.setInventoryItems(currentKey, items)
        if not stored then return false, err or 'inventory_update_failed' end
        return true, result, extra
    end)
end

local function changeInventoryDimensions(reference, field, value)
    local key, inv = resolve(reference)
    if not key or not inv then return false, 'invalid_inventory' end
    value = math.floor(tonumber(value) or 0)
    if value <= 0 then return false, 'invalid_value' end
    if inv.type == 'player' then
        -- Player dimensions are qbcore configuration, not a mutable secondary
        -- record. Pretending to accept this would create a non-persistent
        -- split-brain between PlayerData and the qbinventory session view.
        return false, 'player_inventory_dimensions_are_configured_by_qbcore'
    end
    return core.lock({ key }, function()
        local currentKey, current = resolve(key)
        if not currentKey or not current then return false, 'invalid_inventory' end
        if field == 'slots' then
            for rawSlot in pairs(current.items or {}) do
                if (tonumber(rawSlot) or 0) > value then return false, 'occupied_slot_outside_new_limit' end
            end
        elseif field == 'maxWeight' and core.totalWeight(current.items) > value then
            return false, 'current_weight_exceeds_new_limit'
        end
        current[field] = value
        core.bump(currentKey)
        core.broadcast(currentKey)
        return true
    end)
end

-- Inventory/getter exports --------------------------------------------------

function Ox.Inventory(reference, owner)
    return Ox.GetInventory(reference, owner)
end

function Ox.GetInventory(reference, owner)
    local key, inv = resolve(reference, owner)
    return toOxInventory(key, inv)
end

function Ox.GetInventoryItems(reference, owner)
    local key, inv = resolve(reference, owner)
    if not key or not inv then return nil end
    return toOxItems(inv.items)
end

function Ox.GetSlot(reference, slot)
    local _, inv = resolve(reference)
    slot = math.floor(tonumber(slot) or 0)
    return inv and slot > 0 and toOxItem(inv.items[slot]) or nil
end

function Ox.GetEmptySlot(reference)
    local _, inv = resolve(reference)
    if not inv then return nil end
    for slot = 1, inv.slots do if not inv.items[slot] then return slot end end
end

function Ox.GetSlotForItem(reference, item, metadata)
    local _, inv = resolve(reference)
    if not inv or not itemName(item) then return nil end
    local wanted = itemName(item)
    local empty
    for slot = 1, inv.slots do
        local current = inv.items[slot]
        if not current and not empty then empty = slot end
        if current and current.name == wanted and not current.unique and metadataMatches(itemMetadata(current), metadata, true) then
            return slot
        end
    end
    return empty
end

function Ox.GetSlotWithItem(reference, item, metadata, strict)
    local _, inv = resolve(reference)
    local found = matchingSlots(inv, item, metadata, strict)
    return found[1] and toOxItem(found[1].item) or nil
end

function Ox.GetSlotIdWithItem(reference, item, metadata, strict)
    local slot = Ox.GetSlotWithItem(reference, item, metadata, strict)
    return slot and slot.slot or nil
end

function Ox.GetSlotsWithItem(reference, item, metadata, strict)
    local _, inv = resolve(reference)
    local out = {}
    for _, match in ipairs(matchingSlots(inv, item, metadata, strict)) do out[#out + 1] = toOxItem(match.item) end
    return out
end

function Ox.GetSlotIdsWithItem(reference, item, metadata, strict)
    local _, inv = resolve(reference)
    local out = {}
    for _, match in ipairs(matchingSlots(inv, item, metadata, strict)) do out[#out + 1] = match.slot end
    return out
end

function Ox.GetItemCount(reference, item, metadata, strict)
    local _, inv = resolve(reference)
    local total = 0
    for _, match in ipairs(matchingSlots(inv, item, metadata, strict)) do total = total + countOf(match.item) end
    return total
end

function Ox.GetItem(reference, item, metadata, returnsCount)
    local name = itemName(item)
    if not name then return nil end
    local definition = core.itemDef(name)
    if not definition then return nil end
    local count = Ox.GetItemCount(reference, name, metadata, false)
    if returnsCount then return count end
    local out = copy(definition)
    out.name = out.name or name
    out.count = count
    return out
end

-- Matches ox_inventory's Search return shape: a single requested item returns
-- one result, while a list returns a name-keyed result table. Search accepts
-- numeric 1/2 and the readable slots/count aliases.
function Ox.Search(reference, search, items, metadata)
    local _, inv = resolve(reference)
    if not inv or items == nil then return false end
    if search == 'slots' then search = 1 elseif search == 'count' then search = 2 end
    if search ~= 1 and search ~= 2 then return false end
    local requested = type(items) == 'string' and { items } or items
    if type(requested) ~= 'table' then return false end
    local isSingle = type(items) == 'string'
    local result = {}
    for _, rawName in ipairs(requested) do
        local name = itemName(rawName)
        if name then
            if search == 1 then
                local slots = {}
                for _, match in ipairs(matchingSlots(inv, name, metadata, false)) do slots[#slots + 1] = toOxItem(match.item) end
                result[name] = slots
            else
                result[name] = Ox.GetItemCount(inv, name, metadata, false)
            end
        end
    end
    if not next(result) then return false end
    if isSingle then return result[itemName(items)] end
    return result
end

-- Capacity exports ----------------------------------------------------------

function Ox.CanCarryItem(reference, item, count, metadata)
    local name = itemName(item)
    if not name then return false end
    local ok = core.canAdd(reference, name, count or 1, nil, normaliseMetadata(metadata) or {})
    return ok == true
end

function Ox.CanCarryAmount(reference, item)
    local _, inv = resolve(reference)
    local name = itemName(item)
    local definition = name and core.itemDef(name) or nil
    if not inv or not definition then return nil end
    local weight = tonumber(definition.weight) or 0
    if weight <= 0 then return 0 end -- No max stack count exists in qbinventory yet.
    local byWeight = math.max(0, math.floor((inv.maxWeight - core.totalWeight(inv.items)) / weight))
    if definition.unique then
        local free = 0
        for slot = 1, inv.slots do if not inv.items[slot] then free = free + 1 end end
        return math.min(byWeight, free)
    end
    if not I.stackSlot(inv.items, { name = name, unique = definition.unique, info = {} }) and not Ox.GetEmptySlot(inv) then return 0 end
    return byWeight
end

function Ox.CanCarryWeight(reference, weight)
    local _, inv = resolve(reference)
    weight = tonumber(weight)
    if not inv or not weight then return nil end
    local available = inv.maxWeight - core.totalWeight(inv.items)
    return available >= weight, available
end

-- Mutating item exports. All mutations acquire a single deterministic lock
-- and use the authority's qbcore-aware write funnel / secondary persistence.

function Ox.AddItem(reference, item, count, metadata, slot, callback)
    local name = itemName(item)
    count = math.floor(tonumber(count) or 0)
    if not name then return false, 'invalid_item' end
    if count <= 0 then return false, 'invalid_count' end
    local key, inv = resolve(reference)
    if not key or not inv then return false, 'invalid_inventory' end
    local carried, why = core.canAdd(key, name, count, slot, normaliseMetadata(metadata) or {})
    if not carried then return false, why or 'inventory_full' end
    local success, response = core.lock({ key }, function()
        local currentKey, current = resolve(key)
        if not currentKey or not current then return false, 'invalid_inventory' end
        local ok, result = core.addTo(currentKey, name, count, slot, normaliseMetadata(metadata) or {})
        if not ok then return false, result end
        core.bump(currentKey)
        core.broadcast(currentKey)
        local targetSlot = tonumber(result) or tonumber(slot)
        local itemResult = targetSlot and current.items[targetSlot] or nil
        if not itemResult then
            local matches = matchingSlots(current, name, metadata, false)
            itemResult = matches[#matches] and matches[#matches].item or nil
        end
        return true, toOxItem(itemResult)
    end)
    if callback then return callback(success, response) end
    return success, response
end

function Ox.RemoveItem(reference, item, count, metadata, slot, ignoreTotal, strict)
    local name = itemName(item)
    count = math.floor(tonumber(count) or 0)
    if not name then return false, 'invalid_item' end
    if count <= 0 then return false, 'invalid_count' end
    if strict == nil then strict = true end
    local key, inv = resolve(reference)
    if not key or not inv then return false, 'invalid_inventory' end
    return core.lock({ key }, function()
        local currentKey, current = resolve(key)
        if not currentKey or not current then return false, 'invalid_inventory' end
        local candidates = {}
        if slot then
            slot = math.floor(tonumber(slot) or 0)
            local currentItem = current.items[slot]
            if not currentItem or currentItem.name ~= name or not metadataMatches(itemMetadata(currentItem), metadata, strict) then
                return false, 'no_item_in_slot'
            end
            candidates[1] = { slot = slot, amount = countOf(currentItem) }
        else
            candidates = matchingSlots(current, name, metadata, strict)
            for _, candidate in ipairs(candidates) do candidate.amount = countOf(candidate.item) end
        end
        local available = 0
        for _, candidate in ipairs(candidates) do available = available + candidate.amount end
        if available < count and not ignoreTotal then return false, 'not_enough_items' end
        local wanted = math.min(count, available)
        if wanted <= 0 then return false, 'not_enough_items' end
        local remaining = wanted
        for _, candidate in ipairs(candidates) do
            if remaining <= 0 then break end
            local take = math.min(remaining, candidate.amount)
            local ok, err = core.removeFrom(currentKey, candidate.slot, take)
            if not ok then return false, err or 'remove_failed' end
            remaining = remaining - take
        end
        core.bump(currentKey)
        core.broadcast(currentKey)
        return true
    end)
end

function Ox.SetItem(reference, item, count, metadata)
    local name = itemName(item)
    count = math.floor(tonumber(count) or -1)
    if not name then return false, 'invalid_item' end
    if count < 0 then return false, 'invalid_count' end
    local current = Ox.GetItemCount(reference, name, metadata, true)
    if current == count then return true end
    if current < count then return Ox.AddItem(reference, name, count - current, metadata) end
    return Ox.RemoveItem(reference, name, current - count, metadata, nil, false, true)
end

function Ox.SetMetadata(reference, slot, metadata)
    if type(metadata) == 'table' and metadata.weight ~= nil then
        -- qbinventory's item-weight accounting currently uses the shared item
        -- definition only. Reject rather than accepting a custom-weight value
        -- that would make CanCarryItem disagree with actual inventory weight.
        return false, 'metadata_weight_not_supported'
    end
    slot = math.floor(tonumber(slot) or 0)
    if slot < 1 then return false, 'invalid_slot' end
    local clean = normaliseMetadata(metadata) or {}
    return mutateItems(reference, function(_, items)
        local item = items[slot]
        if not item then return false, 'empty_slot' end
        item.info = copy(clean)
        item.metadata = copy(clean)
        return true, toOxItem(item)
    end)
end

function Ox.SetDurability(reference, slot, durability)
    slot = math.floor(tonumber(slot) or 0)
    durability = tonumber(durability)
    if slot < 1 or not durability then return false, 'invalid_durability' end
    return mutateItems(reference, function(_, items)
        local item = items[slot]
        if not item then return false, 'empty_slot' end
        local metadata = copy(itemMetadata(item))
        metadata.durability = durability
        item.info = copy(metadata)
        item.metadata = copy(metadata)
        return true, toOxItem(item)
    end)
end

function Ox.SetSlotCount(reference, slots)
    return changeInventoryDimensions(reference, 'slots', slots)
end

function Ox.SetMaxWeight(reference, maxWeight)
    return changeInventoryDimensions(reference, 'maxWeight', maxWeight)
end

-- Explicit capability map for consumers that need to branch before the full
-- ox_inventory surface is enabled. This adapter does not emulate vehicle
-- persistence, containers, crafting, weapons, or hook/event contracts.
Ox.unsupported = {
    'GetContainerFromSlot', 'RemoveInventory', 'UpdateVehicle', 'SwapSlots',
    'GetCurrentWeapon', 'CanSwapItem', 'CustomDrop', 'CreateDropFromPlayer',
    'ConfiscateInventory', 'ReturnInventory', 'ClearInventory', 'RegisterStash',
    'CreateTemporaryStash', 'InspectInventory', 'RegisterShop', 'registerHook',
    'removeHooks',
}

I.compat.ox = Ox
return Ox
