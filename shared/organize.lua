-- Sort and stack-all planning: a PURE function over a slot table.
--
-- Nothing here touches an inventory. `plan` takes the current items and returns
-- a brand new slot table; server.lua then commits that table in one write under
-- the inventory lock (a single kora_core setPath for a player, an in-place swap
-- for a secondary inventory). Keeping the planning pure is what lets
-- test/smoke/organize.lua prove, without FXServer, that an organize can never
-- create or destroy an item.
--
-- Rules
--   stack  merge every stackable stack of the same name AND identical metadata
--          (the very rule a drag-drop uses: KoraInventory.canStack) into the
--          lowest slots of that group, filling each to its max stack size, if
--          any. Unique items and items whose metadata differs never merge.
--   sort   stack first, then reorder everything past the protected hotbar by
--          category (opts.order), then label (case-insensitive), then item
--          name, then original slot, so equal items keep their order. Items
--          close up to the lowest free slots, so no gaps are left after the
--          hotbar.
--
-- With `keepSlots = N` slots 1..N are never moved or emptied. They are the
-- lowest slots, so a stack there is only ever a merge TARGET (it can only
-- grow), which keeps hotbar bindings and visible weapon carry exactly as they
-- were. Two stacks of one item inside the protected slots are both left alone.

KoraInventory = KoraInventory or {}

local organize = {}
KoraInventory.organize = organize

organize.DEFAULT_ORDER = { 'weapon', 'ammo', 'useable', 'other' }

local function deepCopy(value, depth)
    if type(value) ~= 'table' then
        return value
    end
    depth = (depth or 0) + 1
    if depth > 16 then
        return value
    end
    local out = {}
    for key, inner in pairs(value) do
        out[key] = deepCopy(inner, depth)
    end
    return out
end

-- Same content comparison as KoraInventory.sameInfo (shared.lua), repeated here
-- so this file stays loadable on its own. The two MUST stay in step: that is
-- the single "can these stack" rule moves use.
local function sameValue(left, right, depth)
    if left == right then
        return true
    end
    if type(left) ~= 'table' or type(right) ~= 'table' or depth > 8 then
        return false
    end
    for key, value in pairs(left) do
        if not sameValue(value, right[key], depth + 1) then
            return false
        end
    end
    for key in pairs(right) do
        if left[key] == nil then
            return false
        end
    end
    return true
end

local function canStack(left, right)
    local shared = KoraInventory
    if shared and type(shared.canStack) == 'function' then
        return shared.canStack(left, right)
    end
    return left.name == right.name
        and not left.unique
        and not right.unique
        and sameValue(left.info or {}, right.info or {}, 0)
end

---Default category for an item: 'weapon', 'ammo', 'useable' or 'other'.
---The server passes its own classifier (which can read the item definition).
---@param item table
---@return string
function organize.category(item)
    local name = type(item.name) == 'string' and item.name:lower() or ''
    if item.type == 'weapon' or name:sub(1, 7) == 'weapon_' then
        return 'weapon'
    end
    if item.type == 'ammo' or name:find('ammo', 1, true) then
        return 'ammo'
    end
    if item.useable == true then
        return 'useable'
    end
    return 'other'
end

local function sortLabel(item)
    local info = type(item.info) == 'table' and item.info or {}
    local label = type(info.label) == 'string' and info.label or item.label or item.name or ''
    return tostring(label):lower()
end

local function maxStackOf(item, maxStack)
    if type(maxStack) ~= 'function' then
        return math.huge
    end
    local limit = tonumber(maxStack(item))
    if not limit or limit < 1 then
        return math.huge
    end
    return math.floor(limit)
end

---Reads `items` into an ascending list of { slot, item } with every entry
---checked. Anything odd (a slot outside 1..slots, a fractional key, a missing
---name, a non-positive or fractional amount) refuses the whole plan: an
---inventory this function does not fully understand is left exactly as it is.
local function collect(items, slots)
    if type(items) ~= 'table' then
        return nil, 'invalid inventory'
    end
    local list = {}
    for slot, item in pairs(items) do
        if type(slot) ~= 'number' or slot % 1 ~= 0 or slot < 1 or slot > slots then
            return nil, 'invalid inventory'
        end
        if type(item) ~= 'table' or type(item.name) ~= 'string' then
            return nil, 'invalid inventory'
        end
        local amount = tonumber(item.amount)
        if not amount or amount < 1 or amount % 1 ~= 0 then
            return nil, 'invalid inventory'
        end
        list[#list + 1] = { slot = slot, item = deepCopy(item) }
    end
    table.sort(list, function(a, b) return a.slot < b.slot end)
    return list
end

---Merges stackable groups into their lowest slots. `list` is modified in place
---and returned without the entries that were emptied.
local function stackList(list, maxStack, keep)
    local groups = {}
    for _, entry in ipairs(list) do
        local item = entry.item
        if not item.unique then
            local placed = false
            for _, group in ipairs(groups) do
                if canStack(group.first, item) then
                    -- A second stack inside the protected slots is left exactly
                    -- as it is: it is never emptied, and it is not a source.
                    if entry.slot > keep then
                        group.entries[#group.entries + 1] = entry
                        group.total = group.total + item.amount
                    end
                    placed = true
                    break
                end
            end
            if not placed then
                groups[#groups + 1] = { first = item, entries = { entry }, total = item.amount }
            end
        end
    end
    local emptied = {}
    for _, group in ipairs(groups) do
        if #group.entries > 1 then
            local limit = maxStackOf(group.first, maxStack)
            -- Stacks already above the cap (an item whose cap was lowered
            -- later) need more slots than they use: leave that group alone
            -- rather than lose the surplus.
            if math.ceil(group.total / limit) <= #group.entries then
                local left = group.total
                for _, entry in ipairs(group.entries) do
                    local take = math.min(left, limit)
                    if take > 0 then
                        entry.item.amount = take
                        left = left - take
                    else
                        emptied[entry] = true
                    end
                end
            end
        end
    end
    local kept = {}
    for _, entry in ipairs(list) do
        if not emptied[entry] then
            kept[#kept + 1] = entry
        end
    end
    return kept
end

local function totals(list)
    local count, amount = 0, 0
    for _, entry in ipairs(list) do
        count = count + 1
        amount = amount + entry.item.amount
    end
    return count, amount
end

---Plans an organize.
---@param items table slot -> item (never modified)
---@param slots integer slot count of the inventory
---@param mode 'sort'|'stack'
---@param opts table|nil
---   keepSlots integer  slots 1..keepSlots are never moved or emptied (default 0)
---   order string[]     category order for 'sort' (default organize.DEFAULT_ORDER)
---   classify fun(item): string  category of an item (default organize.category)
---   maxStack fun(item): number|nil  largest stack for an item (default unbounded)
---@return table|nil result { items = slot -> item, changed = boolean }
---@return string|nil err
function organize.plan(items, slots, mode, opts)
    opts = opts or {}
    slots = math.floor(tonumber(slots) or 0)
    if slots < 1 then
        return nil, 'invalid inventory'
    end
    if mode ~= 'sort' and mode ~= 'stack' then
        return nil, 'invalid organize mode'
    end
    local keep = math.max(0, math.min(slots, math.floor(tonumber(opts.keepSlots) or 0)))

    local list, err = collect(items, slots)
    if not list then
        return nil, err
    end
    local beforeCount, beforeAmount = totals(list)

    list = stackList(list, opts.maxStack, keep)

    if mode == 'sort' then
        local order = {}
        for index, category in ipairs(opts.order or organize.DEFAULT_ORDER) do
            if order[category] == nil then
                order[category] = index
            end
        end
        local classify = opts.classify or organize.category
        local fallback = #(opts.order or organize.DEFAULT_ORDER) + 1

        local fixed, movable = {}, {}
        for _, entry in ipairs(list) do
            if entry.slot <= keep then
                fixed[#fixed + 1] = entry
            else
                local category = classify(entry.item)
                entry.rank = order[category] or fallback
                entry.label = sortLabel(entry.item)
                entry.sortName = tostring(entry.item.name):lower()
                movable[#movable + 1] = entry
            end
        end
        table.sort(movable, function(a, b)
            if a.rank ~= b.rank then return a.rank < b.rank end
            if a.label ~= b.label then return a.label < b.label end
            if a.sortName ~= b.sortName then return a.sortName < b.sortName end
            return a.slot < b.slot
        end)
        for index, entry in ipairs(movable) do
            entry.slot = keep + index
        end
        list = {}
        for _, entry in ipairs(fixed) do list[#list + 1] = entry end
        for _, entry in ipairs(movable) do list[#list + 1] = entry end
    end

    -- Build the result and prove nothing was created, destroyed or doubled.
    local result, afterAmount, afterCount = {}, 0, 0
    for _, entry in ipairs(list) do
        if entry.slot < 1 or entry.slot > slots or result[entry.slot] then
            return nil, 'plan mismatch'
        end
        entry.item.slot = entry.slot
        result[entry.slot] = entry.item
        afterAmount = afterAmount + entry.item.amount
        afterCount = afterCount + 1
    end
    if afterAmount ~= beforeAmount or afterCount > beforeCount then
        return nil, 'plan mismatch'
    end

    local changed = not sameValue(result, items, 0)
    return { items = result, changed = changed, before = beforeCount, after = afterCount }
end
