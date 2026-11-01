-- ox_inventory server-export compatibility adapter.
--
-- This file deliberately does not register any exports or provide an
-- `ox_inventory` identity. server.lua owns the authority and decides when the
-- compatibility contract is complete enough to expose. Keeping this adapter
-- as a table also makes it safe to load alongside native kora_inventory callers.
--
-- Required trusted seam (provided by server.lua):
--   QbInventory.internal.resolveInventory(reference, preferredType)
--   QbInventory.internal.{lock,setInventoryItems,canAdd,addTo,removeFrom}
--   QbInventory.internal.{itemDef,bump,broadcast,totalWeight,config}
--   QbInventory.internal.{createSecondary,removeSecondary,rekeySecondary,open}
-- Never call any of these from a client event. In particular, setInventoryItems
-- preserves kora_core as the only writer of player PlayerData.items.
--
-- Signatures and return shapes are pinned against ox_inventory commit
-- ce8ad4c624cacebf0b2434a3aa27b363fb4c4b06 (see test/contracts/upstream.lua).
-- Everything below that deliberately differs from that commit says so, and why,
-- at the point of divergence -- an undocumented difference here is a silent
-- misbehaviour in every third-party resource written against upstream.

QbInventory = QbInventory or {}
QbInventory.compat = QbInventory.compat or {}

local inventory = QbInventory
local core = assert(inventory.internal, 'qbinventory ox adapter loaded before server authority')
local ox = {}

local function copy(value)
    return core.copy(value)
end

local function countOf(item)
    return math.floor(tonumber(item and (item.amount or item.count)) or 0)
end

local function itemMetadata(item)
    if type(item) ~= 'table' then
        return {}
    end
    return item.metadata or item.info or {}
end

-- Upstream's assertMetadata: anything that is not a table becomes { type = it }.
local function normaliseMetadata(metadata)
    if metadata == nil then
        return nil
    end
    if type(metadata) == 'table' then
        return copy(metadata)
    end
    return { type = metadata }
end

local function contains(actual, expected)
    if expected == nil then
        return true
    end
    if type(actual) ~= 'table' or type(expected) ~= 'table' then
        return actual == expected
    end
    for key, value in pairs(expected) do
        if not contains(actual[key], value) then
            return false
        end
    end
    return true
end

local function identical(a, b)
    return contains(a or {}, b or {}) and contains(b or {}, a or {})
end

-- Upstream picks its comparator as `strict and table.matches or table.contains`,
-- so a nil/false `strict` means PARTIAL matching -- the requested metadata only
-- has to be a subset of the slot's. Defaulting to strict here (as this adapter
-- used to) made every unqualified GetSlotWithItem/GetItemCount/Search call miss
-- slots that carry extra metadata, which is nearly all of them. `strict` is
-- therefore taken exactly as given; the two exports that DO default to strict
-- upstream (GetItemSlots, RemoveItem) apply that default themselves.
local function metadataMatches(actual, metadata, strict)
    metadata = normaliseMetadata(metadata)
    if metadata == nil then
        return true
    end
    if strict then
        return identical(actual or {}, metadata)
    end
    return contains(actual or {}, metadata)
end

local function resolve(reference, preferredType)
    local key, inv = core.resolveInventory(reference, preferredType)
    return key, inv
end

-- Upstream resolves the requested name through the item registry first and
-- returns nil outright when it is unknown, then matches slots against the
-- REGISTRY name. That is what makes 'WATER' and 'water' find the same slots and
-- what makes an unknown item a nil result rather than an empty-but-truthy one.
local function canonicalName(item)
    local name
    if type(item) == 'table' then
        name = type(item.name) == 'string' and item.name or nil
    elseif type(item) == 'string' then
        name = item
    end
    if not name then
        return nil, nil
    end
    local def = core.itemDef(name)
    if not def then
        return nil, nil
    end
    return def.name or name:lower(), def
end

local function itemName(item)
    return (canonicalName(item))
end

local function toOxItem(item)
    if not item then
        return nil
    end
    local out = copy(item)
    out.count = countOf(item)
    out.amount = out.count -- kora_inventory callers retain their native field.
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

-- ACCEPTED DIVERGENCE: upstream's Inventory()/GetInventory() hand back the LIVE
-- OxInventory object, methods and all. kora_inventory returns a detached snapshot
-- on purpose: every write in this resource goes through the lock -> mutate ->
-- bump -> broadcast funnel in server.lua, and a live object is a mutation path
-- straight around it (no lock, no revision bump, no viewer patch, no
-- persistence markDirty). Callers that only READ the snapshot behave the same
-- as upstream; callers that mutate it were relying on a hole we will not open.
local function toOxInventory(key, inv)
    if not inv then
        return nil
    end
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

-- Returns nil (not an empty list) when the inventory or the item name does not
-- resolve, mirroring upstream's `if not inventory or not item then return end`.
-- Callers distinguish "no such item" from "none held".
--
-- MISSING vs upstream: ox_inventory calls Items.UpdateDurability while walking
-- slots, which deletes an expired consumable in the read path. kora_inventory has
-- no durability decay yet, so a fully-degraded item is still reported here.
-- Implementing it needs authority-side write access from a read export, which
-- is a server.lua change, not an adapter one.
local function matchingSlots(inv, requested, metadata, strict)
    local name = itemName(requested)
    if not inv or not name then
        return nil
    end
    local matches = {}
    for rawSlot, slotItem in pairs(inv.items or {}) do
        if slotItem and slotItem.name == name and metadataMatches(itemMetadata(slotItem), metadata, strict) then
            local slot = tonumber(rawSlot) or slotItem.slot
            if slot then
                matches[#matches + 1] = { slot = slot, item = slotItem }
            end
        end
    end
    table.sort(matches, function(a, b)
        return a.slot < b.slot
    end)
    return matches
end

local function mutateItems(reference, callback)
    local key, inv = resolve(reference)
    if not key or not inv then
        return false, 'invalid_inventory'
    end
    return core.lock({ key }, function()
        -- Resolve inside the lock; player inventory views are rebuilt from
        -- kora_core and must never be retained across the critical section.
        local currentKey, current = resolve(key)
        if not currentKey or not current then
            return false, 'invalid_inventory'
        end
        local items = copy(current.items)
        local ok, result, extra = callback(current, items)
        if not ok then
            return false, result
        end
        local stored, err = core.setInventoryItems(currentKey, items)
        if not stored then
            return false, err or 'inventory_update_failed'
        end
        return true, result, extra
    end)
end

-- Both SetSlotCount and SetMaxWeight return nothing upstream, so a rejection
-- has nowhere to go. Print it rather than failing silently.
local function warn(fmt, ...)
    print(('^3[qbinventory:ox]^7 ' .. fmt):format(...))
end

local function changeInventoryDimensions(reference, field, value)
    local key, inv = resolve(reference)
    if not key or not inv then
        return
    end
    value = math.floor(tonumber(value) or 0)
    if value <= 0 then
        return
    end
    if inv.type == 'player' then
        -- ACCEPTED DIVERGENCE: player dimensions are kora_core configuration, not a
        -- mutable secondary record. Pretending to accept this would create a
        -- non-persistent split-brain between PlayerData and the session view.
        return warn('player_inventory_dimensions_are_configured_by_qbcore (%s on %s)', field, key)
    end
    core.lock({ key }, function()
        local currentKey, current = resolve(key)
        if not currentKey or not current then
            return
        end
        if field == 'slots' then
            for rawSlot in pairs(current.items or {}) do
                if (tonumber(rawSlot) or 0) > value then
                    return warn('occupied_slot_outside_new_limit (%s)', currentKey)
                end
            end
        elseif field == 'maxWeight' and core.totalWeight(current.items) > value then
            return warn('current_weight_exceeds_new_limit (%s)', currentKey)
        end
        current[field] = value
        core.bump(currentKey)
        core.broadcast(currentKey)
    end)
end

-- Inventory/getter exports --------------------------------------------------

function ox.Inventory(reference, owner)
    return ox.GetInventory(reference, owner)
end

function ox.GetInventory(reference, owner)
    local key, inv = resolve(reference, owner)
    return toOxInventory(key, inv)
end

function ox.GetInventoryItems(reference, owner)
    local key, inv = resolve(reference, owner)
    if not key or not inv then
        return nil
    end
    return toOxItems(inv.items)
end

function ox.GetSlot(reference, slot)
    local _, inv = resolve(reference)
    slot = math.floor(tonumber(slot) or 0)
    return inv and slot > 0 and toOxItem(inv.items[slot]) or nil
end

function ox.GetEmptySlot(reference)
    local _, inv = resolve(reference)
    if not inv then
        return nil
    end
    for slot = 1, inv.slots do
        if not inv.items[slot] then
            return slot
        end
    end
end

function ox.GetSlotForItem(reference, item, metadata)
    local _, inv = resolve(reference)
    local wanted = itemName(item)
    if not inv or not wanted then
        return nil
    end
    local empty
    for slot = 1, inv.slots do
        local current = inv.items[slot]
        if not current and not empty then
            empty = slot
        end
        -- Upstream gates the stack branch on item.stack and uses table.matches.
        if
            current
            and current.name == wanted
            and not current.unique
            and metadataMatches(itemMetadata(current), metadata, true)
        then
            return slot
        end
    end
    return empty
end

function ox.GetSlotWithItem(reference, item, metadata, strict)
    local _, inv = resolve(reference)
    local found = matchingSlots(inv, item, metadata, strict)
    if not found then
        return nil
    end
    return found[1] and toOxItem(found[1].item) or nil
end

function ox.GetSlotIdWithItem(reference, item, metadata, strict)
    local slot = ox.GetSlotWithItem(reference, item, metadata, strict)
    return slot and slot.slot or nil
end

function ox.GetSlotsWithItem(reference, item, metadata, strict)
    local _, inv = resolve(reference)
    local found = matchingSlots(inv, item, metadata, strict)
    if not found then
        return nil
    end
    local out = {}
    for _, match in ipairs(found) do
        out[#out + 1] = toOxItem(match.item)
    end
    return out
end

function ox.GetSlotIdsWithItem(reference, item, metadata, strict)
    local _, inv = resolve(reference)
    local found = matchingSlots(inv, item, metadata, strict)
    if not found then
        return nil
    end
    local out = {}
    for _, match in ipairs(found) do
        out[#out + 1] = match.slot
    end
    return out
end

-- Unlike the GetSlot* family this returns 0, not nil, for an unresolvable
-- inventory or item -- upstream's `if not inventory or not item then return 0 end`.
function ox.GetItemCount(reference, item, metadata, strict)
    local _, inv = resolve(reference)
    local found = matchingSlots(inv, item, metadata, strict)
    if not found then
        return 0
    end
    local total = 0
    for _, match in ipairs(found) do
        total = total + countOf(match.item)
    end
    return total
end

function ox.GetItem(reference, item, metadata, returnsCount)
    local name, definition = canonicalName(item)
    if not name or not definition then
        return nil
    end
    -- Upstream counts with table.contains, i.e. partial metadata matching.
    local count = ox.GetItemCount(reference, name, metadata, false)
    if returnsCount then
        return count
    end
    local out = copy(definition)
    out.name = out.name or name
    out.count = count
    return out
end

-- Upstream's Search return shape: `itemCount == 1` -- a ONE-ELEMENT ARRAY, not
-- merely a bare string -- returns the single result directly, anything longer
-- returns a name-keyed table. Names are lowercased and `weapon_` prefixes are
-- uppercased before use, and matching is partial (table.contains).
function ox.Search(reference, search, items, metadata)
    if items == nil then
        return false
    end
    local _, inv = resolve(reference)
    if not inv then
        return false
    end
    if search == 'slots' then
        search = 1
    elseif search == 'count' then
        search = 2
    end
    if search ~= 1 and search ~= 2 then
        return false
    end
    local requested = type(items) == 'string' and { items } or items
    if type(requested) ~= 'table' then
        return false
    end
    local itemCount = #requested
    local result, firstKey = {}, nil
    for index = 1, itemCount do
        local raw = requested[index]
        local name = type(raw) == 'string' and raw:lower() or nil
        if name and name:sub(1, 7) == 'weapon_' then
            name = name:upper()
        end
        if name then
            if not firstKey then
                firstKey = name
            end
            if search == 1 then
                local slots = {}
                for _, match in ipairs(matchingSlots(inv, name, metadata, false) or {}) do
                    slots[#slots + 1] = toOxItem(match.item)
                end
                result[name] = slots
            else
                result[name] = ox.GetItemCount(inv, name, metadata, false)
            end
        end
    end
    if not next(result) then
        return false
    end
    -- Upstream indexes the single result with the caller's RAW name
    -- (`returnData[items[1]]`), so its own mixed-case input returns nil there.
    -- Use the normalised key instead: same result for well-formed input, and a
    -- useful one instead of nil for 'WATER'.
    if itemCount == 1 then
        return result[firstKey]
    end
    return result
end

-- Capacity exports ----------------------------------------------------------

-- Upstream returns nil (not false) when the item or inventory cannot be
-- resolved, so `== false` and `== nil` mean different things to a caller.
function ox.CanCarryItem(reference, item, count, metadata)
    local name = itemName(item)
    local key = select(1, resolve(reference))
    if not name or not key then
        return nil
    end
    -- Weight AND slot capacity are checked by the authority, which is stricter
    -- than upstream's inline arithmetic and is the same check every write uses.
    local ok = core.canAdd(key, name, count or 1, nil, normaliseMetadata(metadata) or {})
    return ok == true
end

-- Upstream is deliberately unclamped: math.floor((maxWeight - weight) / weight),
-- with no free-slot term and no clamp at zero, so an overweight inventory
-- reports a negative figure. Matching that keeps callers that compare against
-- their own requested count behaving identically.
function ox.CanCarryAmount(reference, item)
    local _, inv = resolve(reference)
    local _, definition = canonicalName(item)
    if not inv or not definition then
        return nil
    end
    local metadata = type(item) == 'table' and (item.info or item.metadata) or nil
    local weight = core.itemWeight({ weight = definition.weight, amount = 1, info = metadata })
    -- Upstream divides unguarded, which yields inf for a zero-weight item.
    if weight <= 0 then
        return math.maxinteger
    end
    return math.floor((inv.maxWeight - core.totalWeight(inv.items)) / weight)
end

function ox.CanCarryWeight(reference, weight)
    local _, inv = resolve(reference)
    weight = tonumber(weight)
    if not inv or not weight then
        return nil
    end
    local available = inv.maxWeight - core.totalWeight(inv.items)
    return available >= weight, available
end

-- Mutating item exports. All mutations acquire a single deterministic lock
-- and use the authority's qbcore-aware write funnel / secondary persistence.

function ox.AddItem(reference, item, count, metadata, slot, callback)
    local name = itemName(item)
    count = math.floor(tonumber(count) or 0)
    if not name then
        return false, 'invalid_item'
    end
    if count <= 0 then
        return false, 'invalid_count'
    end
    local key, inv = resolve(reference)
    if not key or not inv then
        return false, 'invalid_inventory'
    end
    -- ox `createItem` hook: may replace the metadata (returned table) or cancel.
    local hookOK, hookMetadata = core.createItemHook(inv.source, key, name, count, normaliseMetadata(metadata) or {})
    if not hookOK then
        return false, hookMetadata
    end
    metadata = hookMetadata
    local carried, why = core.canAdd(key, name, count, slot, normaliseMetadata(metadata) or {})
    if not carried then
        return false, why or 'inventory_full'
    end
    local success, response = core.lock({ key }, function()
        local currentKey, current = resolve(key)
        if not currentKey or not current then
            return false, 'invalid_inventory'
        end
        local ok, result = core.addTo(currentKey, name, count, slot, normaliseMetadata(metadata) or {})
        if not ok then
            return false, result
        end
        core.bump(currentKey)
        core.broadcast(currentKey)
        local targetSlot = tonumber(result) or tonumber(slot)
        local itemResult = targetSlot and current.items[targetSlot] or nil
        if not itemResult then
            local matches = matchingSlots(current, name, metadata, false) or {}
            itemResult = matches[#matches] and matches[#matches].item or nil
        end
        return true, toOxItem(itemResult)
    end)
    if callback then
        return callback(success, response)
    end
    return success, response
end

-- Error vocabulary is upstream's: a non-numeric count is 'invalid_count', a
-- number that rounds to <= 0 is 'negative_count', and a shortfall in a NAMED
-- slot is 'not_enough_items_in_slot' rather than the whole-inventory
-- 'not_enough_items'. Third-party code branches on these strings.
function ox.RemoveItem(reference, item, count, metadata, slot, ignoreTotal, strict)
    local name = itemName(item)
    if not name then
        return false, 'invalid_item'
    end
    if tonumber(count) == nil then
        return false, 'invalid_count'
    end
    count = math.floor(tonumber(count) + 0.5)
    if count <= 0 then
        return false, 'negative_count'
    end
    -- One of only two exports that default to STRICT metadata matching.
    if strict == nil then
        strict = true
    end
    local key, inv = resolve(reference)
    if not key or not inv then
        return false, 'invalid_inventory'
    end
    return core.lock({ key }, function()
        local currentKey, current = resolve(key)
        if not currentKey or not current then
            return false, 'invalid_inventory'
        end
        local candidates = {}
        if slot then
            slot = math.floor(tonumber(slot) or 0)
            local currentItem = current.items[slot]
            if
                not currentItem
                or currentItem.name ~= name
                or not metadataMatches(itemMetadata(currentItem), metadata, strict)
            then
                return false, 'no_item_in_slot'
            end
            local held = countOf(currentItem)
            if count > held and not ignoreTotal then
                return false, 'not_enough_items_in_slot'
            end
            candidates[1] = { slot = slot, amount = held }
        else
            candidates = matchingSlots(current, name, metadata, strict) or {}
            for _, candidate in ipairs(candidates) do
                candidate.amount = countOf(candidate.item)
            end
        end
        local available = 0
        for _, candidate in ipairs(candidates) do
            available = available + candidate.amount
        end
        if available < count and not ignoreTotal then
            return false, 'not_enough_items'
        end
        local wanted = math.min(count, available)
        if wanted <= 0 then
            return false, 'not_enough_items'
        end
        local remaining = wanted
        for _, candidate in ipairs(candidates) do
            if remaining <= 0 then
                break
            end
            local take = math.min(remaining, candidate.amount)
            local ok, err = core.removeFrom(currentKey, candidate.slot, take)
            if not ok then
                return false, err or 'remove_failed'
            end
            remaining = remaining - take
        end
        core.bump(currentKey)
        core.broadcast(currentKey)
        return true
    end)
end

function ox.SetItem(reference, item, count, metadata)
    local name = itemName(item)
    count = math.floor(tonumber(count) or -1)
    if not name then
        return false, 'invalid_item'
    end
    if count < 0 then
        return false, 'invalid_count'
    end
    -- Upstream reads the current total through GetItem, i.e. PARTIAL matching.
    local current = ox.GetItem(reference, name, metadata, true) or 0
    if current == count then
        return true
    end
    if current < count then
        return ox.AddItem(reference, name, count - current, metadata)
    end
    return ox.RemoveItem(reference, name, current - count, metadata, nil, false, true)
end

-- Upstream returns nothing from SetMetadata/SetDurability; the slot table is
-- pushed to viewers instead. Anything this adapter refuses is printed, because
-- a bare `return` would otherwise be indistinguishable from success.
function ox.SetMetadata(reference, slot, metadata)
    slot = math.floor(tonumber(slot) or 0)
    if slot < 1 then
        return
    end
    local clean = normaliseMetadata(metadata) or {}
    mutateItems(reference, function(_, items)
        local item = items[slot]
        if not item then
            return false, 'empty_slot'
        end
        item.info = copy(clean)
        item.metadata = copy(clean)
        return true
    end)
end

function ox.SetDurability(reference, slot, durability)
    slot = math.floor(tonumber(slot) or 0)
    durability = tonumber(durability)
    if slot < 1 or not durability then
        return
    end
    mutateItems(reference, function(_, items)
        local item = items[slot]
        if not item then
            return false, 'empty_slot'
        end
        local metadata = copy(itemMetadata(item))
        metadata.durability = durability
        item.info = copy(metadata)
        item.metadata = copy(metadata)
        return true
    end)
end

function ox.SetSlotCount(reference, slots)
    changeInventoryDimensions(reference, 'slots', slots)
end

function ox.SetMaxWeight(reference, maxWeight)
    changeInventoryDimensions(reference, 'maxWeight', maxWeight)
end

-- Three return values upstream: a slot-id-keyed MAP OF COUNTS ({ [3] = 5 }),
-- the total across those slots, and the inventory's remaining empty slots.
-- Callers index it by slot id and read `totalCount`; an array of item tables
-- (what this used to return) silently reads as empty for both.
-- One of only two exports that default to strict metadata matching.
function ox.GetItemSlots(reference, item, metadata, strict)
    local _, inv = resolve(reference)
    local name = itemName(item)
    if not inv or not inv.slots or not name then
        return nil
    end
    if strict == nil then
        strict = true
    end
    local slots, totalCount, emptySlots = {}, 0, inv.slots
    for rawSlot, slotItem in pairs(inv.items or {}) do
        emptySlots = emptySlots - 1
        if slotItem and slotItem.name == name and metadataMatches(itemMetadata(slotItem), metadata, strict) then
            local slot = tonumber(rawSlot) or slotItem.slot
            if slot then
                local held = countOf(slotItem)
                slots[slot] = held
                totalCount = totalCount + held
            end
        end
    end
    return slots, totalCount, emptySlots
end

-- Upstream keys the bound container off `metadata.container` and sizes a
-- missing one from `metadata.size` = { slots, maxWeight }. kora_inventory's own
-- container domain writes `info.containerId`, so both spellings are accepted.
function ox.GetContainerFromSlot(reference, slot)
    local key, inv = resolve(reference)
    slot = math.floor(tonumber(slot) or 0)
    if not inv or slot < 1 then
        return nil
    end
    local slotItem = inv.items[slot]
    if not slotItem then
        return nil
    end
    local metadata = itemMetadata(slotItem)
    local id = metadata.container or metadata.containerId
    if id == nil then
        return nil
    end
    local containerKey, container = resolve(core.key('container', id))
    if not container then
        local size = type(metadata.size) == 'table' and metadata.size or {}
        -- DIVERGENCE (deliberate): upstream creates the container with no access
        -- boundary at all. server.lua's canAccess treats an ownerless secondary
        -- as open to everyone, so inherit the holding inventory's owner (or the
        -- player holding it) -- otherwise this export would mint a world-
        -- readable stash out of any item that carries a container id.
        container = core.createSecondary('container', id, {
            label = slotItem.label or tostring(id),
            slots = tonumber(size[1]) or nil,
            maxWeight = tonumber(size[2]) or nil,
            owner = inv.owner or (inv.type == 'player' and inv.id) or nil,
        })
        containerKey = container and container.key or nil
    end
    if not container then
        return nil
    end
    return toOxInventory(containerKey, container)
end

function ox.RemoveInventory(reference)
    local key, inv = resolve(reference)
    if not key or not inv or inv.type == 'player' then
        return
    end
    core.removeSecondary(key)
end

-- Upstream: SwapSlots(fromInventory, toInventory, slot1, slot2) -- FOUR
-- arguments and TWO inventories -- returning the two cloned slot tables with
-- their `slot` fields already pointing at their new homes. The old
-- (reference, fromSlot, toSlot) shape here made every upstream caller bind an
-- inventory table into `fromSlot`, where tonumber() produced nil -> 0 and the
-- call could only ever fail.
---@return table|nil fromSlot, table|nil toSlot  (or nil, string on failure)
function ox.SwapSlots(fromInventory, toInventory, slot1, slot2)
    slot1 = math.floor(tonumber(slot1) or 0)
    slot2 = math.floor(tonumber(slot2) or 0)
    if slot1 < 1 or slot2 < 1 then
        return nil, 'invalid_slot'
    end
    local fromKey = select(1, resolve(fromInventory))
    local toKey = select(1, resolve(toInventory))
    if not fromKey or not toKey then
        return nil, 'invalid_inventory'
    end
    -- core.lock sorts its keys, so taking both here cannot deadlock against a
    -- concurrent transfer that happens to name the same pair the other way up.
    local ok, first, second = core.lock({ fromKey, toKey }, function()
        local fromCurrentKey, fromInv = resolve(fromKey)
        local toCurrentKey, toInv = resolve(toKey)
        if not fromCurrentKey or not fromInv or not toCurrentKey or not toInv then
            return false, 'invalid_inventory'
        end
        if slot1 > fromInv.slots or slot2 > toInv.slots then
            return false, 'invalid_slot'
        end
        local sameInventory = fromCurrentKey == toCurrentKey
        local fromItems = copy(fromInv.items)
        local toItems = sameInventory and fromItems or copy(toInv.items)
        local moved, displaced = fromItems[slot1], toItems[slot2]
        if moved then
            moved.slot = slot2
        end
        if displaced then
            displaced.slot = slot1
        end
        fromItems[slot1], toItems[slot2] = displaced, moved
        if sameInventory then
            local stored, err = core.setInventoryItems(fromCurrentKey, fromItems)
            if not stored then
                return false, err or 'inventory_update_failed'
            end
        else
            local previous = copy(fromInv.items)
            local stored, err = core.setInventoryItems(fromCurrentKey, fromItems)
            if not stored then
                return false, err or 'inventory_update_failed'
            end
            local applied, applyErr = core.setInventoryItems(toCurrentKey, toItems)
            if not applied then
                -- A half-applied cross-inventory swap duplicates or destroys an
                -- item, so put the source back before reporting the failure.
                core.setInventoryItems(fromCurrentKey, previous)
                return false, applyErr or 'inventory_update_failed'
            end
        end
        return true, toOxItem(moved), toOxItem(displaced)
    end)
    if not ok then
        return nil, first or 'swap_failed'
    end
    return first, second
end

-- Real weight arithmetic, as upstream: could this inventory hold `testCount` of
-- `testItem` if `firstCount` of `firstItem` left it? The previous "advisory"
-- stub returned true for any resolvable inventory and two non-nil names, which
-- is not advisory -- it is an unconditional yes that callers acted on.
function ox.CanSwapItem(reference, firstItem, firstCount, testItem, testCount)
    local _, inv = resolve(reference)
    if not inv then
        return nil
    end
    local firstName = canonicalName(firstItem)
    local _, testDef = canonicalName(testItem)
    if not firstName or not testDef then
        return nil
    end
    firstCount = tonumber(firstCount) or 0
    testCount = tonumber(testCount) or 0
    -- Upstream falls through to nil (not false) when the inventory does not
    -- actually hold enough of the first item to give up.
    if ox.GetItemCount(inv, firstName, nil, false) < firstCount then
        return nil
    end
    local remaining, removedWeight = firstCount, 0
    for _, current in pairs(inv.items) do
        if remaining > 0 and current.name == firstName then
            local amount = math.min(countOf(current), remaining)
            local removed = copy(current)
            removed.amount = amount
            removedWeight = removedWeight + core.itemWeight(removed)
            remaining = remaining - amount
        end
    end
    local weightWithoutFirst = core.totalWeight(inv.items) - removedWeight
    local weightWithTest = weightWithoutFirst + core.itemWeight({
        weight = testDef.weight,
        amount = testCount,
        info = type(testItem) == 'table' and (testItem.info or testItem.metadata) or nil,
    })
    return weightWithTest <= inv.maxWeight
end

function ox.ClearInventory(reference, keep)
    local key, inv = resolve(reference)
    if not key or not inv then
        return
    end
    local retained = {}
    local wanted = type(keep) == 'string' and { [keep] = true } or {}
    if type(keep) == 'table' then
        for _, name in ipairs(keep) do
            wanted[name] = true
        end
    end
    for slot, item in pairs(inv.items or {}) do
        if wanted[item.name] then
            retained[slot] = copy(item)
        end
    end
    core.lock({ key }, function()
        return core.setInventoryItems(key, retained)
    end)
end

-- `instance` is upstream's 8th parameter. kora_inventory gates stash access on
-- owner/groups/access plus the LIVE player's routing bucket, not on a value
-- declared at registration time, so it is recorded on the record for callers
-- that read it back and is deliberately NOT enforced as an access check.
function ox.RegisterStash(id, label, slots, maxWeight, owner, groups, coords, instance)
    local stashKey = inventory.api.RegisterStash(id, label, slots, maxWeight, owner, groups, coords)
    if instance ~= nil and stashKey then
        local _, inv = resolve(stashKey)
        if inv then
            inv.instance = instance
        end
    end
end

-- os.time() alone gives two drops created in the same second the SAME id, and
-- core.createSecondary returns the existing record for a key it already knows,
-- so the second caller silently received the first caller's drop. A monotonic
-- counter makes the id unique regardless of clock resolution.
local nextTransientId = 0
local function transientId(prefix)
    nextTransientId = nextTransientId + 1
    return ('%s-%d-%d'):format(prefix, os.time(), nextTransientId)
end

local function createDrop(prefix, items, coords, slots, maxWeight, instance, model)
    local label = tostring(prefix or 'Drop')
    return core.createSecondary('drop', transientId(label:lower():gsub('[^%w]', '')), {
        label = label,
        items = items or {},
        coords = coords,
        slots = slots,
        maxWeight = maxWeight,
        temporary = true,
        instance = instance,
        bucket = instance or nil,
        model = model,
    })
end

function ox.CreateTemporaryStash(properties)
    properties = type(properties) == 'table' and copy(properties) or {}
    -- Same collision as CustomDrop: server.lua derives its fallback id from a
    -- timestamp, so supply a unique one from here rather than letting two
    -- stashes created in the same tick resolve to one record.
    if properties.id == nil then
        properties.id = transientId('temp')
    end
    return inventory.api.CreateTemporaryStash(properties)
end

function ox.RegisterShop(shopType, shopDetails)
    if type(shopDetails) ~= 'table' then
        return
    end
    inventory.api.RegisterShop(shopType, shopDetails)
end

function ox.CustomDrop(prefix, items, coords, slots, maxWeight, instance, model)
    local inv = createDrop(prefix, items, coords, slots, maxWeight, instance, model)
    return inv and inv.id or nil
end

-- Upstream copies the player's items into the drop AND THEN clears the player,
-- returning the drop id. Skipping the clear (as this used to) leaves the same
-- items in both inventories -- a duplication bug, not a cosmetic one. The clear
-- runs inside the SAME lock as the copy so nothing can be added in between.
function ox.CreateDropFromPlayer(playerId)
    playerId = tonumber(playerId)
    if not playerId then
        return nil
    end
    local key, inv = resolve(playerId)
    if not key or not inv or not next(inv.items or {}) then
        return nil
    end
    local ok, dropId = core.lock({ key }, function()
        local currentKey, current = resolve(key)
        if not currentKey or not current or not next(current.items or {}) then
            return false
        end
        local drop = createDrop('Drop', copy(current.items), nil, current.slots, current.maxWeight, GetPlayerRoutingBucket(playerId))
        if not drop then
            return false
        end
        local cleared = core.setInventoryItems(currentKey, {})
        if not cleared then
            -- Never leave a drop holding a copy of an inventory we failed to empty.
            core.removeSecondary(drop.key)
            return false
        end
        return true, drop.id
    end)
    if not ok then
        return nil
    end
    return dropId
end

-- MISSING vs upstream: ox_inventory tracks an EQUIPPED slot (inv.weapon) and
-- returns that slot only. kora_inventory has no equipped-slot concept on the
-- server -- adding one means new authority state in server.lua, driven by the
-- client's weapon events. Until then this reports the first weapon-type slot
-- found, which answers "is a weapon carried?" but NOT "which is drawn?".
function ox.GetCurrentWeapon(reference)
    local _, inv = resolve(reference)
    if not inv then
        return nil
    end
    for _, item in pairs(inv.items or {}) do
        if item.type == 'weapon' then
            return toOxItem(item)
        end
    end
end

-- Upstream ids are ('trunk%s'):format(PLATE) and ('glove%s'):format(PLATE) --
-- `glove`, not `glovebox` -- uppercased, with an optional whitespace trim.
-- kora_inventory keys the same records as trunk:<PLATE> / glovebox:<PLATE>, so the
-- kind names are mapped here and the plate is normalised the same way.
local function normalisePlate(value)
    if inventory.vehicles then
        return inventory.vehicles.normalisePlate(value)
    end
    if type(value) ~= 'string' then
        return nil
    end
    local plate = value:gsub('^%s*(.-)%s*$', '%1'):upper():gsub('%s+', ' ')
    return plate ~= '' and plate or nil
end

-- Setting inv.id/inv.key in place left the record reachable only under its OLD
-- registry key while its own .key field claimed the new one -- every later
-- lookup, session patch and persistence write went to the wrong place.
-- core.rekeySecondary moves the registry entry, the durable row and any open
-- viewers together. Returns nothing, like upstream.
function ox.UpdateVehicle(oldPlate, newPlate)
    local old, new = normalisePlate(oldPlate), normalisePlate(newPlate)
    if not old or not new or old == new then
        return
    end
    for _, kind in ipairs({ 'trunk', 'glovebox' }) do
        local oldKey = core.key(kind, old)
        if select(2, resolve(oldKey)) then
            local _, err = core.rekeySecondary(oldKey, kind, new)
            if err then
                warn('UpdateVehicle could not rekey %s: %s', oldKey, tostring(err))
            end
        end
    end
end

-- Upstream is InspectInventory(playerId, invId): the VIEWER comes FIRST. The
-- old (target, source) order here inverted every upstream call site, opening
-- the inspected player's panel on the inspector instead. Returns nothing.
function ox.InspectInventory(playerId, invId)
    playerId = tonumber(playerId)
    if not playerId then
        return
    end
    -- Upstream's `invId ~= playerId` guard: inspecting yourself is a no-op.
    if invId == playerId or invId == nil then
        return
    end
    local key = select(1, resolve(invId))
    if not key then
        return
    end
    core.open(playerId, key)
end

function ox.ConfiscateInventory(source)
    source = tonumber(source)
    if not source then
        return
    end
    local key, inv = resolve(source)
    if not key or not inv then
        return
    end
    -- Copy and clear under one lock, for the same reason CreateDropFromPlayer does.
    core.lock({ key }, function()
        local currentKey, current = resolve(key)
        if not currentKey or not current then
            return
        end
        local stash = core.createSecondary('confiscation', tostring(source), {
            label = 'Confiscated inventory',
            items = copy(current.items),
            slots = current.slots,
            maxWeight = current.maxWeight,
        })
        if not stash then
            return
        end
        local cleared = core.setInventoryItems(currentKey, {})
        if not cleared then
            core.removeSecondary(stash.key)
        end
    end)
end

function ox.ReturnInventory(source)
    source = tonumber(source)
    if not source then
        return
    end
    local key, inv = resolve(source)
    local stashKey, stash = resolve('confiscation:' .. tostring(source))
    if not key or not inv or not stash then
        return
    end
    core.lock({ key }, function()
        if core.setInventoryItems(key, copy(stash.items)) then
            core.removeSecondary(stashKey)
        end
    end)
end

function ox.ConvertItems(_, items)
    local out, slot = {}, 0
    for name, count in pairs(items or {}) do
        slot = slot + 1
        if type(count) == 'table' then
            out[slot] = toOxItem(count)
        else
            out[slot] = { slot = slot, name = name, count = count, amount = count, metadata = {} }
        end
    end
    return out
end

-- Upstream: ConvertInventory(inv) is ConvertItems' counterpart for a WHOLE
-- inventory record rather than a bare items array -- it takes an
-- id/type/slots/maxWeight table (as third-party migration code and secondary
-- inventories built outside this authority hand it, in either the name-keyed
-- shape ConvertItems accepts or an already slot-keyed one) and hands back the
-- same shape toOxInventory() returns, with items reshaped and weight
-- recomputed from the real item registry. A bare reference this authority
-- already knows about (a stash id, a player source, ...) is resolved through
-- the same resolver every other export here uses, then handed to
-- toOxInventory() directly -- there is nothing to convert, it is already
-- stored in ox shape.
function ox.ConvertInventory(inv)
    -- A reference this authority already knows about (a player source, a
    -- registered stash id, an inventory's own `key`/`type`+`id` pair) always
    -- wins: it is already stored in ox shape, so there is nothing to convert.
    local key, resolved = resolve(inv)
    if resolved then
        return toOxInventory(key, resolved)
    end
    if type(inv) ~= 'table' then
        return nil
    end
    local items = ox.ConvertItems(nil, inv.items)
    local weight = 0
    for _, converted in pairs(items) do
        local _, definition = canonicalName(converted)
        weight = weight + core.itemWeight({
            weight = definition and definition.weight,
            amount = countOf(converted),
            info = converted.info or converted.metadata,
        })
    end
    return {
        id = inv.id,
        label = inv.label,
        type = inv.type or 'stash',
        slots = inv.slots,
        maxWeight = inv.maxWeight,
        weight = weight,
        items = items,
    }
end

-- A single lookup goes through the authority's resolver so weapons and
-- case-insensitive names behave exactly as they do everywhere else here.
-- The registry is named 'items' (kora_core modules/registry/server.lua:12) and
-- `getShared(name, key)` requires BOTH arguments. Calling it with only a
-- registry name returns nil unconditionally, whichever spelling is used, so the
-- full-list form has to come from allShared -- which is a dense ARRAY, not the
-- name-keyed map upstream's Items() returns.
function ox.Items(name)
    if name ~= nil then
        local def = core.itemDef(name)
        return def and inventory.toOxItemDef(def, type(name) == 'string' and name:lower() or name) or nil
    end
    local out = {}
    for _, def in ipairs(exports.kora_core:allShared('items') or {}) do
        if type(def) == 'table' and type(def.name) == 'string' then
            out[def.name] = inventory.toOxItemDef(def)
        end
    end
    return out
end
ox.ItemList = ox.Items

function ox.setPlayerInventory(player, data)
    local source = type(player) == 'table' and player.source or tonumber(player)
    if not source then
        return
    end
    core.setInventoryItems(core.playerKey(source), copy(data or {}))
end

-- Upstream: useItem(source, slot, cb). This is the SERVER identity's copy of
-- the same export client/compat/ox.lua already publishes -- it was reachable
-- on the client and via kora_inventory's own native `useItem`, but never on the
-- ox_inventory SERVER identity, so a third-party server script calling
-- exports.ox_inventory:useItem(...) resolved to nothing. Delegates to the
-- exact same use-item funnel kora_inventory's own api.useItem calls: handler
-- dispatch, the portable-container bypass and the QBCore:Server:UseItem
-- legacy fallback all live there and are never reimplemented here.
function ox.useItem(source, slot, cb)
    source = tonumber(source)
    if not source then
        if cb then
            cb(false, 'invalid_source')
        end
        return false, 'invalid_source'
    end
    local ok, err = inventory.api.useItem(source, slot)
    if cb then
        cb(ok, err)
    end
    return ok, err
end

function ox.forceOpenInventory(source, invType, data)
    return core.open(source, core.key(invType, type(data) == 'table' and data.id or data))
end
function ox.registerHook(event, callback, options)
    return inventory.api.registerHook(event, callback, options)
end
function ox.removeHooks(id)
    inventory.api.removeHooks(id)
end

-- ACCEPTED DIVERGENCE: upstream registers these in modules/pefcl, against a
-- pefcl bank/cash account. kora_inventory has no pefcl dependency, so they stay
-- pointed at kora_core's accounts -- the only source of truth for money here.
function ox.getCash(source)
    return exports.kora_core:getMoney(source, 'cash')
end
function ox.addCash(source, amount, reason)
    return exports.kora_core:addMoney(source, 'cash', amount, reason or 'ox_inventory')
end
function ox.removeCash(source, amount, reason)
    return exports.kora_core:removeMoney(source, 'cash', amount, reason or 'ox_inventory')
end
-- Upstream registers this as a literal no-op -- its pefcl module exports a
-- `function() end` under this name and never fills it in.
-- Nothing consumes its return, so returning a balance here would be inventing a
-- contract. kora_core's own money export is the way to read a bank balance.
function ox.getBank() end
function ox.getCards(_)
    return {}
end
function ox.giveCard(...)
    return false
end

inventory.compat.ox = ox
return ox
