-- qb-inventory server export compatibility.
--
-- This module is deliberately transport-free.  It runs after server.lua and
-- talks only to QbInventory.internal, so player item writes continue through
-- kora_core's PlayerData mutation funnel and secondary changes keep their
-- kora_inventory revision/broadcast guarantees.

local inventory = QbInventory
local internal =
    assert(inventory and inventory.internal, 'qbinventory internal authority must load before qb compatibility')

local function lower(value)
    return type(value) == 'string' and value:lower() or nil
end

local function slotsByItem(items, itemName)
    local wanted, found = lower(itemName), {}
    if not wanted or type(items) ~= 'table' then
        return found
    end
    for rawSlot, item in pairs(items) do
        if type(item) == 'table' and lower(item.name) == wanted then
            local slot = tonumber(rawSlot)
            if slot then
                found[#found + 1] = slot
            end
        end
    end
    table.sort(found)
    return found
end

local function firstSlotByItem(items, itemName)
    local found = slotsByItem(items, itemName)
    return found[1]
end

-- inventory.api is installed by server.lua in the live resource. Keeping a blank
-- fallback permits this transport-free adapter to be unit-tested in isolation.
local native = inventory.api or {}

local function wholeNumber(value)
    local number = tonumber(value)
    if number and number >= 1 and number % 1 == 0 then
        return number
    end
    return nil
end

local prefixKinds = { trunk = true, glovebox = true, drop = true }

---Stock identifiers name trunks, gloveboxes and drops as `<kind>-<id>`; kora
---keys them `<kind>:<id>`. The prefix is only honoured when the resolved
---inventory really is that kind, so `trunk-player:7` can never reach a player.
local function resolve(identifier, preferredType)
    if type(identifier) == 'string' then
        local kind, rest = identifier:match('^(%a+)%-(.+)$')
        if prefixKinds[kind] then
            local key, found = internal.resolveInventory(rest, kind)
            if found and found.type == kind then
                return key, found
            end
        end
    end
    return internal.resolveInventory(identifier, preferredType)
end

local function slots(identifier)
    local _, inventory = resolve(identifier)
    if not inventory then
        return 0, nil
    end
    local used = 0
    for _, item in pairs(inventory.items or {}) do
        if item then
            used = used + 1
        end
    end
    return used, math.max(0, (tonumber(inventory.slots) or 0) - used)
end

local function setItemData(identifier, itemName, dataKey, value, slot)
    local wanted = lower(itemName)
    if not wanted or type(dataKey) ~= 'string' or dataKey == '' then
        return false
    end
    -- These are shared-definition mechanics, not mutable per-instance state.
    -- Letting a compatibility caller override them would invalidate capacity
    -- checks or turn a stackable item into a unique one mid-transaction.
    if
        ({
            slot = true,
            name = true,
            amount = true,
            count = true,
            weight = true,
            type = true,
            unique = true,
            useable = true,
            label = true,
            image = true,
            shouldClose = true,
            preventClose = true,
            useTime = true,
        })[dataKey]
    then
        return false
    end
    local inventoryKey, inventory = resolve(identifier)
    if not inventory then
        return nil
    end

    return internal.lock({ inventoryKey }, function()
        -- Resolve and copy again inside the lock.  The copy is then committed
        -- with setInventoryItems rather than mutating a player table in place.
        local key, current = resolve(inventoryKey)
        if not current then
            return false
        end
        local selected
        if slot ~= nil then
            selected = tonumber(slot)
            local item = selected and current.items[selected]
            if not item or lower(item.name) ~= wanted then
                return false
            end
        else
            selected = firstSlotByItem(current.items, wanted)
            if not selected then
                return false
            end
        end
        local items = internal.copy(current.items)
        items[selected][dataKey] = internal.copy(value)
        if dataKey == 'info' then
            items[selected].metadata = internal.copy(value)
        end
        return internal.setInventoryItems(key, items)
    end)
end

local function clearStash(identifier)
    if type(identifier) ~= 'string' or identifier == '' then
        return
    end
    local inventoryKey, inventory = resolve(identifier, 'stash')
    if not inventory or inventory.type ~= 'stash' then
        return
    end
    internal.lock({ inventoryKey }, function()
        -- setInventoryItems owns persistence, revision increments and live
        -- broadcasts for both player-safe and secondary inventories.
        internal.setInventoryItems(inventoryKey, {})
    end)
end

local function createInventory(identifier, data)
    if type(identifier) ~= 'string' or identifier == '' then
        return
    end
    local existingKey, existing = resolve(identifier, 'stash')
    data = type(data) == 'table' and data or {}
    if existing then
        if existing.type ~= 'stash' or existing.policyOwner then
            return
        end
        local slotCount = wholeNumber(data.slots)
        local weight = tonumber(data.maxWeight or data.maxweight)
        if not data.label and not slotCount and not weight then
            return
        end
        internal.lock({ existingKey }, function()
            local key, current = resolve(existingKey)
            if not current then
                return
            end
            current.label = data.label or current.label
            current.slots = slotCount or current.slots
            if weight and weight >= 0 then
                current.maxWeight = weight
            end
            internal.bump(key)
            internal.broadcast(key)
        end)
        return
    end
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
    if type(identifier) ~= 'string' or identifier == '' then
        return
    end
    local inventoryKey, inventory = resolve(identifier, 'stash')
    if not inventory or inventory.type == 'player' then
        return
    end
    -- The internal remover is intentionally authoritative: it evicts the
    -- in-memory record and removes durable secondary data together.
    return internal.removeSecondary(inventoryKey)
end

local function getInventory(identifier)
    if type(identifier) ~= 'string' or identifier == '' then
        return nil
    end
    local inventoryKey, inventory = resolve(identifier, 'stash')
    if not inventory then
        return nil
    end
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
        isOpen = internal.openedBy and internal.openedBy(inventoryKey) or false,
        items = internal.copy(inventory.items or {}),
    }
end

local function canAddItem(identifier, itemName, amount)
    local wanted = lower(itemName)
    if not wanted then
        return false
    end
    return internal.canAdd(identifier, wanted, amount)
end

local stashOnly = { stash = true }
local storageTypes = { stash = true, trunk = true, glovebox = true, drop = true, temporary = true }

local function qbHooks()
    return inventory.compat and inventory.compat.qbHooks
end

local function hookData(inv, identifier, item, slot, amount, reason, resource, side)
    local data = {
        item = item,
        amount = amount,
        reason = reason,
        resource = resource,
    }
    local snapshot = {
        label = inv.label,
        slots = inv.slots,
        maxweight = inv.maxWeight,
        items = internal.copy(inv.items or {}),
    }
    if side == 'to' then
        data.toId, data.toInventory, data.toType, data.toSlot = identifier, snapshot, inv.type, slot
    else
        data.fromId, data.fromInventory, data.fromType, data.fromSlot = identifier, snapshot, inv.type, slot
    end
    return data
end

---Adds to a trusted server-resolved secondary inventory. Placement, capacity,
---revision, broadcast and the createItem hook all stay behind the authority
---funnels; the caller only picks which of the allowed storage types it may
---reach. Shops are read only there, and evidence, confiscation and portable
---container inventories keep their own bounded domain APIs.
local function addToSecondary(identifier, itemName, amount, slot, info, reason, allowed)
    local wanted = lower(itemName)
    amount = wholeNumber(amount)
    if not wanted or not amount then
        return false, 'invalid item or amount'
    end
    local inventoryKey, inventory = resolve(identifier, 'stash')
    if not inventory or not allowed[inventory.type] then
        return false, 'inventory not found'
    end
    return internal.lock({ inventoryKey }, function()
        local key, current = resolve(inventoryKey)
        if not current or not allowed[current.type] then
            return false, 'inventory not found'
        end
        local metadata = info
        if
            QbInventory.weapons
            and QbInventory.weapons.isWeapon
            and QbInventory.weapons.prepareMetadata
            and QbInventory.weapons.isWeapon(wanted)
        then
            local prepared, prepareErr = QbInventory.weapons.prepareMetadata(wanted, internal.copy(info or {}))
            if not prepared then
                return false, prepareErr
            end
            metadata = prepared
        end
        local hookOK, hookInfo = internal.createItemHook(nil, key, wanted, amount, metadata)
        if not hookOK then
            return false, hookInfo
        end
        local ok, err = internal.addTo(key, wanted, amount, slot, hookInfo or {}, reason, slot ~= nil)
        if not ok then
            return false, err
        end
        internal.bump(key)
        internal.broadcast(key)
        return true
    end)
end

---Removes from a secondary inventory. A named slot is removed from directly and
---must already hold at least `amount` of the named item; otherwise matching
---slots are drained lowest first. The whole removal is refused up front if the
---inventory does not hold enough, rather than draining some slots and then
---reporting failure with the inventory half emptied.
local function removeFromSecondary(identifier, itemName, amount, slot, allowed)
    local wanted = lower(itemName)
    -- Whole units only: a fraction drained the whole stacks first and then
    -- failed on the remainder, leaving the stash half emptied.
    amount = wholeNumber(amount)
    if not wanted or not amount or amount <= 0 then
        return false, 'invalid item or amount'
    end
    local inventoryKey, inventory = resolve(identifier, 'stash')
    if not inventory or not allowed[inventory.type] then
        return false, 'inventory not found'
    end
    return internal.lock({ inventoryKey }, function()
        local key, current = resolve(inventoryKey)
        if not current or not allowed[current.type] then
            return false, 'inventory not found'
        end
        if slot ~= nil then
            slot = tonumber(slot)
            local item = slot and current.items[slot]
            if not item or lower(item.name) ~= wanted or item.amount < amount then
                return false, 'item not in slot'
            end
            local ok, err = internal.removeFrom(key, slot, amount)
            if not ok then
                return false, err
            end
            internal.bump(key)
            internal.broadcast(key)
            return true
        end
        local candidates = slotsByItem(current.items, wanted)
        local available = 0
        for _, candidateSlot in ipairs(candidates) do
            available = available + current.items[candidateSlot].amount
        end
        if available < amount then
            return false, 'not enough of item'
        end
        local remaining = amount
        for _, candidateSlot in ipairs(candidates) do
            if remaining <= 0 then
                break
            end
            local item = current.items[candidateSlot]
            local take = math.min(remaining, item.amount)
            local ok, err = internal.removeFrom(key, candidateSlot, take)
            if not ok then
                return false, err
            end
            remaining = remaining - take
        end
        internal.bump(key)
        internal.broadcast(key)
        return true
    end)
end

local function addToStash(stashId, itemName, amount, slot, info)
    return addToSecondary(stashId, itemName, amount, tonumber(slot) or nil, type(info) == 'table' and info or nil, nil, stashOnly)
end

local function removeFromStash(stashId, itemName, amount, slot)
    return removeFromSecondary(stashId, itemName, amount, slot, stashOnly)
end

---True when `identifier` addresses a player inventory (a server id).
local function playerSource(identifier)
    if type(identifier) ~= 'number' then
        return nil
    end
    local _, found = resolve(identifier)
    return found and found.type == 'player' and identifier or nil
end

---Stock AddItem(identifier, item, amount, slot, info, reason, isInternalMove).
---`identifier` is a player source or a stash/trunk/glovebox/drop identifier.
---The ItemAdded hook runs before the commit and may cancel it or replace the
---metadata; the listener runs after. Returns a bare boolean like upstream, with
---the refusal reason as a second value.
local function addItem(identifier, itemName, amount, slot, info, reason, isInternalMove)
    local wanted = lower(itemName)
    if not wanted then
        return false, 'invalid item'
    end
    amount = tonumber(amount) or 1
    slot = tonumber(slot) or nil
    info = type(info) == 'table' and info or nil

    local src = playerSource(identifier)
    local inventoryKey, target
    if src then
        inventoryKey, target = resolve(src)
    else
        inventoryKey, target = resolve(identifier, 'stash')
        if not target or not storageTypes[target.type] then
            return false, 'inventory not found'
        end
    end

    local hooks = qbHooks()
    local resource = GetInvokingResource and GetInvokingResource() or nil
    local data
    if not isInternalMove and hooks and hooks.active('ItemAdded') then
        local definition = internal.itemDef(wanted)
        local pending = definition and internal.buildItem(wanted, amount, slot, info) or nil
        if not pending then
            return false, 'unknown item'
        end
        data = hookData(target, identifier, pending, slot, amount, reason, resource or 'qb-inventory', 'to')
        local mutated = hooks.trigger('ItemAdded', pending.type, data)
        if mutated == false then
            return false, 'cancelled by hook'
        end
        if type(mutated) == 'table' then
            info = mutated
        end
    end

    local ok, err
    if src then
        ok, err = native.AddItem(src, wanted, amount, slot, info, reason)
    else
        ok, err = addToSecondary(inventoryKey, wanted, amount, slot, info, reason, storageTypes)
    end
    if ok and data and hooks then
        hooks.notify('ItemAdded', data.item.type, data)
    end
    return not not ok, err
end

---Stock RemoveItem(identifier, item, amount, slot, reason, isInternalMove).
---Same identifier forms as AddItem. Without a slot kora drains matching slots
---lowest first; upstream refuses unless the first matching slot alone holds
---enough, so kora accepts a superset of upstream's successful calls.
local function removeItem(identifier, itemName, amount, slot, reason, isInternalMove)
    local wanted = lower(itemName)
    if not wanted then
        return false, 'invalid item'
    end
    amount = tonumber(amount)
    if not amount then
        return false, 'invalid amount'
    end
    slot = tonumber(slot) or nil

    local src = playerSource(identifier)
    local target
    if src then
        _, target = resolve(src)
    else
        _, target = resolve(identifier, 'stash')
        if not target or not storageTypes[target.type] then
            return false, 'inventory not found'
        end
    end

    local hooks = qbHooks()
    local resource = GetInvokingResource and GetInvokingResource() or nil
    local data
    if not isInternalMove and hooks and hooks.active('ItemRemoved') then
        local chosen = slot or firstSlotByItem(target.items, wanted)
        local held = chosen and target.items[chosen]
        if not held or lower(held.name) ~= wanted then
            return false, 'item not in slot'
        end
        local copy = internal.copy(held)
        copy.amount = amount
        data = hookData(target, identifier, copy, chosen, amount, reason, resource or 'qb-inventory', 'from')
        if hooks.trigger('ItemRemoved', copy.type, data) == false then
            return false, 'cancelled by hook'
        end
    end

    local ok, err
    if src then
        ok, err = native.RemoveItem(src, wanted, amount, slot, reason)
    else
        ok, err = removeFromSecondary(identifier, wanted, amount, slot, storageTypes)
    end
    if ok and data and hooks then
        hooks.notify('ItemRemoved', data.item.type, data)
    end
    return not not ok, err
end

-- This module does NOT call exports(). It builds a table which
-- server/compat/providers.lua publishes under the `qb-inventory` identity
-- through __cfx_export_qb-inventory_<name> handlers -- a namespace entirely
-- separate from kora_inventory's own flat export table. That separation is what
-- lets GetInventory and CanAddItem keep their upstream qb-inventory return
-- shapes here while server.lua's native exports of the same names keep theirs.
-- (An earlier version of this file did call exports() and silently overwrote
-- the native ones; test/smoke/export_collisions.lua guards that regression.)
local api = {
    GetSlotsByItem = slotsByItem,
    GetFirstSlotByItem = firstSlotByItem,
    GetTotalWeight = function(items)
        return internal.totalWeight(items)
    end,
    GetSlots = slots,
    SetItemData = setItemData,
    ClearStash = clearStash,
    CreateInventory = createInventory,
    RemoveInventory = removeInventory,
    AddToStash = addToStash,
    RemoveFromStash = removeFromStash,
}

-- Full upstream qb-inventory compatibility uses the same authority methods,
-- but keeps its provider-specific return shapes separate from kora_inventory's
-- native exports (and from ox_inventory's identically named exports).

---Upstream: LoadInventory(source, citizenid) -> slot-keyed item table.
---An online `source` returns its live PlayerData.items; otherwise `citizenid` is
---read through kora_core, which owns player persistence (no inventory SQL here).
api.LoadInventory = function(source, citizenid)
    local items = native.GetInventory(tonumber(source) or -1)
    if items == nil and type(citizenid) == 'string' and citizenid ~= '' then
        local ok, data = pcall(function()
            return exports.kora_core:getOfflinePlayerData(citizenid)
        end)
        items = ok and type(data) == 'table' and data.items or nil
    end
    return inventory.copy(items or {})
end

---Upstream: SaveInventory(source, offline). Keep player persistence inside
---qbcore's authority; an offline snapshot may only replace its inventory field.
---Success has no return value, while durable failures remain observable.
api.SaveInventory = function(source, offline)
    local called, saved, err = pcall(function()
        if offline then
            if type(source) ~= 'table' or type(source.citizenid) ~= 'string'
                or (source.items ~= nil and type(source.items) ~= 'table') then
                return false, 'invalid offline player inventory'
            end
            return exports.kora_core:saveOfflinePlayer({ citizenid = source.citizenid,
                items = inventory.copy(source.items or {}) }, { 'items' })
        end
        return exports.kora_core:savePlayer(source, 'items')
    end)
    if not called then return false, tostring(saved) end
    if saved ~= true then
        if not offline and err == 'no such player' then return end
        return false, err or 'player inventory could not be saved'
    end
    if not offline then
        local flushed
        called, flushed, err = pcall(Kora.sql.flush, 'players')
        if not called then return false, tostring(flushed) end
        if flushed ~= true then return false, err or 'player inventory flush failed' end
    end
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
    if not inventory then
        return false
    end
    return internal.lock({ inventoryKey }, function()
        return internal.setInventoryItems(inventoryKey, items)
    end)
end

---Upstream: UseItem(itemName, ...) -- the first argument is the ITEM NAME and
---the varargs are forwarded to the registered handler, which upstream calls as
---(source, itemData). kora_inventory's own earlier compat shape was
---UseItem(source, item); both are accepted so neither caller breaks.
api.UseItem = function(first, second, third)
    if type(first) == 'string' then
        local source = tonumber(second)
        if not source then
            return false, 'UseItem requires a player source'
        end
        return native.useItem(source, (type(third) == 'table' and third.slot) or first)
    end
    return native.useItem(first, type(second) == 'table' and second.slot or second)
end

---Opens another player's inventory through the full access check: distance,
---routing bucket and the server's inspection policy still apply.
api.OpenInventoryById = function(source, target)
    target = tonumber(target)
    if not target or not playerSource(target) then
        return false, 'player not found'
    end
    return inventory.internal.open(source, 'player:' .. target)
end

---Upstream: CreateShop(shopData) -- ONE table. `shopData.name` names the shop;
---a table with no `name` is treated as a collection of shops keyed by name.
---The older CreateShop(name, data) form is still accepted.
local function shopWithSlots(shopData)
    local rows = shopData.items or shopData.inventory
    if type(rows) == 'table' then
        local highest = 0
        for slot in pairs(rows) do
            highest = math.max(highest, tonumber(slot) or 0)
        end
        shopData.slots = math.max(tonumber(shopData.slots) or 0, #rows, highest)
        if shopData.slots < 1 then
            shopData.slots = nil
        end
    end
    return shopData
end

api.CreateShop = function(first, second)
    if type(first) == 'string' then
        return native.RegisterShop(first, shopWithSlots(second or {}))
    end
    if type(first) ~= 'table' then
        return nil, 'CreateShop requires a shop table'
    end
    if first.name then
        return native.RegisterShop(first.name, shopWithSlots(first))
    end

    local last, err
    for shopName, shopData in pairs(first) do
        if type(shopData) == 'table' then
            last, err = native.RegisterShop(shopData.name or shopName, shopWithSlots(shopData))
            if not last then
                return nil, err
            end
        end
    end
    return last
end

api.OpenShop = function(source, name)
    return native.OpenInventory(source, name, { type = 'shop', id = name })
end
---Upstream: OpenInventory(source, identifier, data). A nil identifier opens the
---player's own inventory. A `trunk-`/`glovebox-`/`drop-` identifier that names an
---existing kora inventory opens that one through the full access check; any
---other string is a stash, created on demand by this trusted server call.
api.OpenInventory = function(source, identifier, data)
    if identifier == nil then
        return internal.openInventory(source, 'player', source)
    end
    if type(identifier) ~= 'string' or identifier == '' then
        return false, 'invalid inventory identifier'
    end
    local inventoryKey, found = resolve(identifier)
    local kind = identifier:match('^(%a+)%-')
    if found and prefixKinds[kind] and found.type == kind then
        return internal.open(source, inventoryKey, type(data) == 'table' and data or nil)
    end
    return native.OpenInventory(source, identifier, data)
end

---Upstream: CloseInventory(source, identifier). kora_inventory sessions are keyed
---by player, so the identifier is advisory -- closing the player's session is
---what actually releases the inventory either way. Kept as a WRAPPER rather
---than a direct `native.CloseInventory` reference: the value-copy form silently
---became nil under the `inventory.api or {}` fallback, and providers.lua's
---`type(fn) == 'function'` filter then dropped the export entirely.
api.CloseInventory = function(source, _identifier)
    return native.CloseInventory(source)
end

---Upstream: GetInventory(identifier) -> the whole inventory record, not just
---its items. Returns the detached descriptor built above.
api.GetInventory = getInventory
api.GetItemBySlot = function(source, slot)
    slot = tonumber(slot)
    if not slot or not playerSource(tonumber(source)) then
        return nil
    end
    return native.GetItemBySlot(tonumber(source), slot)
end
api.GetItemByName = function(source, itemName)
    if not playerSource(tonumber(source)) then
        return nil
    end
    return native.GetItemByName(tonumber(source), itemName)
end
---Upstream returns nil (not an empty list) for an unknown player.
api.GetItemsByName = function(source, itemName)
    if not playerSource(tonumber(source)) then
        return nil
    end
    return native.GetItemsByName(tonumber(source), itemName)
end
api.GetItemCount = function(source, items)
    if not playerSource(tonumber(source)) then
        return nil
    end
    return native.GetItemCount(tonumber(source), items)
end
---Upstream returns 0 when the player is missing; the native export would
---report a full inventory's worth of free weight.
api.GetFreeWeight = function(source)
    if not playerSource(tonumber(source)) then
        return 0
    end
    return native.GetFreeWeight(tonumber(source))
end
-- Upstream HasItem(source, items, amount) accepts a name, an array of names,
-- or a {name = count} map, and returns a plain boolean. A string goes straight
-- to the native check. Tables follow upstream: an explicit `amount` applies to
-- every entry and overrides the per-name counts of the map form, an array
-- without `amount` only needs each item present, and an empty table is false.
-- Counts are summed across slots, where upstream compares one slot at a time.
api.HasItem = function(source, items, amount)
    source = tonumber(source)
    if type(items) ~= 'table' then
        return native.HasItem(source, items, amount)
    end
    if not source or not playerSource(source) then
        return false
    end
    local isArray = #items > 0
    local wanted = 0
    for _ in pairs(items) do
        wanted = wanted + 1
    end
    if wanted == 0 then
        return false
    end
    local held = {}
    for _, item in pairs(native.GetInventory(source) or {}) do
        local name = lower(item.name)
        held[name] = (held[name] or 0) + (tonumber(item.amount) or 0)
    end
    for key, value in pairs(items) do
        local name = lower(isArray and value or key)
        local required = tonumber(amount) or (not isArray and tonumber(value)) or 1
        if not name or (held[name] or 0) < required then
            return false
        end
    end
    return true
end
---Upstream: CanAddItem(identifier, item, amount) -> true, or false plus a
---reason of exactly 'weight' or 'slots' (bare false for an unresolvable
---inventory or unknown item). internal.canAdd already speaks that vocabulary
---and, unlike the native canCarry, accepts a secondary inventory identifier
---rather than only a player source.
api.CanAddItem = function(identifier, item, amount)
    local ok, reason = canAddItem(identifier, item, amount)
    if ok then
        return true
    end
    if reason == 'weight' or reason == 'slots' then
        return false, reason
    end
    return false
end
api.ClearInventory = native.ClearInventory
api.AddItem = addItem
api.RemoveItem = removeItem

inventory.compat = inventory.compat or {}
inventory.compat.qb = api
