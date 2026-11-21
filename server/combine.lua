-- Drag-one-item-onto-another combining ("rolling paper + weed = joint").
--
-- The server owns the only recipe registry: Config.kora_inventory.combine.recipes
-- plus whatever other server resources add through `registerCombination`. The
-- browser is told each pair's item names and label (a presentation list, so it
-- can ask "Roll a joint? Combine / Cancel" rather than swap the slots) and sends
-- back only `{ inventory, fromSlot, toSlot, revision }`. Which recipe applies,
-- how much is used, and what comes out are all resolved here from the two real
-- slots; nothing a client says about a recipe, item or amount is believed.
--
-- The `combine` intent goes through the same session/lease/revision/access
-- path as `use` and `drop` (validSession), refuses cuffed/downed players,
-- respects the mid-use slot lock, and -- when the recipe has a time -- waits on
-- the client's kora_lib progress bar exactly as the parachute does, with both
-- slots locked against drop/give/move until it ends. The two slots are then
-- re-read and the removal of A and B plus the addition of the result are
-- applied together, rolled back if any step fails.

KoraInventory = KoraInventory or {}
local inventory = KoraInventory
local internal = assert(inventory.internal, 'kora_inventory authority must load before combine')
local combine = {}
inventory.combine = combine

local PROGRESS_CALLBACK = 'kora_inventory:client:combineProgress'
-- A real bar cannot come back sooner than its duration; allow some slack
-- (same tolerance as the parachute).
local FINISH_TOLERANCE = 500
local MAX_AMOUNT = 10000
-- Kept well inside the 30 s the client waits for an answer
-- (client.lua DIRECT_DEADLINE) and the default mid-use lock (config.busyTimeout).
local MAX_TIME = 20000
local MAX_LABEL = 80
local DEFAULT_LABEL = 'Combine'

local registered, registeredOrder, owners = {}, {}, {}
local active = {}
local warned = {}

local function settings()
    local root = Config and Config.kora_inventory
    return type(root) == 'table' and type(root.combine) == 'table' and root.combine or {}
end

local function enabled()
    return settings().enabled == true
end

local function resourceName()
    return type(GetInvokingResource) == 'function' and GetInvokingResource()
        or type(GetCurrentResourceName) == 'function' and GetCurrentResourceName()
        or 'kora_inventory'
end

local function whole(value, min, max)
    return type(value) == 'number'
        and value == value
        and value >= min
        and value <= max
        and value == math.floor(value)
end

local function itemName(value)
    if type(value) ~= 'string' or value == '' or #value > 64 then
        return nil
    end
    return value:lower()
end

local function pairKey(a, b)
    if a > b then
        a, b = b, a
    end
    return a .. '|' .. b
end

local ALLOWED_KEYS = {
    id = true, a = true, b = true, result = true, amount = true,
    consumeA = true, consumeB = true, time = true, label = true,
}

---Shape check shared by config entries and exported recipes. Unknown keys are
---refused, not ignored: a caller that passes `job = 'police'` must be told it
---is not supported rather than silently publishing the recipe to everyone.
---@return table|nil recipe
---@return string|nil err
local function normalise(raw, id)
    if type(raw) ~= 'table' then
        return nil, 'combination must be a table'
    end
    for key in pairs(raw) do
        if not ALLOWED_KEYS[key] then
            return nil, ('unsupported combination field: %s'):format(tostring(key))
        end
    end
    local a, b, result = itemName(raw.a), itemName(raw.b), itemName(raw.result)
    if not a or not b then
        return nil, 'combination needs item names a and b'
    end
    if not result then
        return nil, 'combination needs a result item'
    end
    local amount = raw.amount == nil and 1 or raw.amount
    local consumeA = raw.consumeA == nil and 1 or raw.consumeA
    local consumeB = raw.consumeB == nil and 1 or raw.consumeB
    local time = raw.time == nil and 0 or raw.time
    if not whole(amount, 1, MAX_AMOUNT) then
        return nil, 'invalid result amount'
    end
    if not whole(consumeA, 0, MAX_AMOUNT) or not whole(consumeB, 0, MAX_AMOUNT) then
        return nil, 'invalid consumed amount'
    end
    -- A recipe that consumes nothing would be a free item printer.
    if consumeA + consumeB < 1 then
        return nil, 'combination must consume at least one item'
    end
    if not whole(time, 0, MAX_TIME) then
        return nil, 'invalid combination time'
    end
    local label = raw.label == nil and DEFAULT_LABEL or raw.label
    if type(label) ~= 'string' or label == '' or #label > MAX_LABEL then
        return nil, 'invalid combination label'
    end
    return {
        id = id,
        a = a,
        b = b,
        result = result,
        amount = amount,
        consumeA = consumeA,
        consumeB = consumeB,
        time = time,
        label = label,
    }
end

local function validId(id)
    return type(id) == 'string' and id ~= '' and #id <= 96 and id:match('^[%w_.:+%-]+$') ~= nil
end

---Config recipes, normalised on every read so a live /config edit applies at
---once. A malformed entry is skipped (and reported once) rather than breaking
---the others.
local function configRecipes()
    local out = {}
    local list = settings().recipes
    if type(list) ~= 'table' then
        return out
    end
    for index = 1, #list do
        local recipe, err = normalise(list[index], 'config:' .. index)
        if recipe then
            out[#out + 1] = recipe
        else
            local note = index .. ':' .. tostring(err)
            if not warned[note] then
                warned[note] = true
                Kora.logging.warn('combine.bad_config', 'Ignoring invalid combine recipe', { index = index, error = err })
            end
        end
    end
    return out
end

---The recipe for a pair of item names, in either order, or nil.
---@param first string name of the dragged item
---@param second string name of the item it was dropped on
---@return table|nil recipe copy with consumeFrom (for `first`) and consumeTo (for `second`)
function combine.find(first, second)
    first, second = itemName(first), itemName(second)
    if not first or not second or not enabled() then
        return nil
    end
    local key = pairKey(first, second)
    local found
    for _, recipe in ipairs(configRecipes()) do
        if pairKey(recipe.a, recipe.b) == key then
            found = recipe
            break
        end
    end
    if not found then
        for _, id in ipairs(registeredOrder) do
            local recipe = registered[id]
            if recipe and pairKey(recipe.a, recipe.b) == key then
                found = recipe
                break
            end
        end
    end
    if not found then
        return nil
    end
    local out = internal.copy(found)
    if found.a == first then
        out.consumeFrom, out.consumeTo = found.consumeA, found.consumeB
    else
        out.consumeFrom, out.consumeTo = found.consumeB, found.consumeA
    end
    return out
end

---Names and labels only, for the browser's confirm popover. `registeredOnly`
---returns just the recipes other resources added (the client already has the
---config list).
function combine.presentation(registeredOnly)
    local list = {}
    if not registeredOnly then
        for _, recipe in ipairs(configRecipes()) do
            list[#list + 1] = { a = recipe.a, b = recipe.b, label = recipe.label }
        end
    end
    for _, id in ipairs(registeredOrder) do
        local recipe = registered[id]
        if recipe then
            list[#list + 1] = { a = recipe.a, b = recipe.b, label = recipe.label }
        end
    end
    return list
end

local function announce()
    if type(TriggerClientEvent) == 'function' then
        TriggerClientEvent('kora_inventory:client:combinations', -1, combine.presentation(true))
    end
end

---Add a recipe at runtime (server only; there is no net event for this).
---@param recipe table { a, b, result, amount?, consumeA?, consumeB?, time?, label?, id? }
---@return boolean ok
---@return string idOrErr the recipe id, or the reason it was refused
function combine.register(recipe)
    if type(recipe) ~= 'table' then
        return false, 'combination must be a table'
    end
    local id = recipe.id
    if id ~= nil and not validId(id) then
        return false, 'invalid combination id'
    end
    local parsed, err = normalise(recipe, id)
    if not parsed then
        return false, err
    end
    for _, name in ipairs({ parsed.a, parsed.b, parsed.result }) do
        if not internal.itemDef(name) then
            return false, 'unknown item: ' .. name
        end
    end
    if not id then
        local low, high = parsed.a, parsed.b
        if low > high then
            low, high = high, low
        end
        parsed.id = low .. '+' .. high
    end
    if registered[parsed.id] or tostring(parsed.id):match('^config:') then
        return false, 'duplicate combination id'
    end
    local key = pairKey(parsed.a, parsed.b)
    for _, existing in ipairs(configRecipes()) do
        if pairKey(existing.a, existing.b) == key then
            return false, 'a combination for that pair already exists'
        end
    end
    for _, other in pairs(registered) do
        if pairKey(other.a, other.b) == key then
            return false, 'a combination for that pair already exists'
        end
    end
    registered[parsed.id] = parsed
    registeredOrder[#registeredOrder + 1] = parsed.id
    owners[parsed.id] = resourceName()
    announce()
    return true, parsed.id
end

---Remove a recipe added with register. Only the resource that added it may.
function combine.remove(id)
    if type(id) ~= 'string' or not registered[id] then
        return false, 'unknown combination'
    end
    if owners[id] ~= resourceName() then
        return false, 'not combination owner'
    end
    registered[id], owners[id] = nil, nil
    for index, existing in ipairs(registeredOrder) do
        if existing == id then
            table.remove(registeredOrder, index)
            break
        end
    end
    announce()
    return true
end

local function dropOwned(resource)
    local changed = false
    for id, owner in pairs(owners) do
        if owner == resource then
            registered[id], owners[id] = nil, nil
            for index, existing in ipairs(registeredOrder) do
                if existing == id then
                    table.remove(registeredOrder, index)
                    break
                end
            end
            changed = true
        end
    end
    if changed then
        announce()
    end
end

local function slotNumber(value, slots)
    local number = tonumber(value)
    if not number or number ~= number or number < 1 or number > slots or number ~= math.floor(number) then
        return nil
    end
    return number
end

local function snapshot(item)
    return { name = item.name, amount = item.amount, info = internal.copy(item.info or {}) }
end

---True (after telling the player) when either ingredient may not be combined:
---a spoiled stack (decay) or a water damaged item. Same guards use / move use.
---Reads the slots fresh from the inventory.
local function ingredientBlocked(src, key, fromSlot, toSlot)
    local current = internal.getInventory(key)
    local decayRuntime = inventory.decayRuntime
    if decayRuntime and (decayRuntime.guard(key, fromSlot, src) or decayRuntime.guard(key, toSlot, src)) then
        return true, 'this item has spoiled'
    end
    local water = inventory.waterDamage
    if water and current then
        for _, slot in ipairs({ fromSlot, toSlot }) do
            local item = current.items[slot]
            if item and water.blocksUse(src, item) then
                return true, 'this item is water damaged'
            end
        end
    end
    return false
end

-- The slot still holds the very item the player chose and enough of it.
local function unchanged(item, snap, need)
    return item ~= nil
        and item.name == snap.name
        and (tonumber(item.amount) or 0) >= need
        and internal.sameInfo(item.info or {}, snap.info)
end

---Apply the combination. Caller holds no lock. Everything is re-read inside the
---inventory lock; the three mutations are undone if any one fails.
local function commit(src, key, fromSlot, toSlot, recipe, fromSnap, toSnap)
    return internal.lock({ key }, function()
        local inv = internal.getInventory(key)
        if not inv then
            return false, 'inventory not found'
        end
        if not unchanged(inv.items[fromSlot], fromSnap, recipe.consumeFrom)
            or not unchanged(inv.items[toSlot], toSnap, recipe.consumeTo)
        then
            return false, 'items changed'
        end

        local info = {}
        if internal.createItemHook then
            local _, hooked = internal.createItemHook(src, key, recipe.result, recipe.amount, {})
            info = type(hooked) == 'table' and hooked or {}
        end

        local removed = {}
        local function rollback()
            for index = #removed, 1, -1 do
                local entry = removed[index]
                local restored, restoreErr = internal.addTo(
                    key, entry.item.name, entry.item.amount, entry.slot, entry.item.info, 'combine-rollback', true
                )
                if not restored then
                    Kora.logging.error('combine.rollback_failed', 'Combine rollback failed', {
                        playerId = src, item = entry.item.name, error = tostring(restoreErr),
                    })
                end
            end
        end
        local function take(slot, amount)
            if amount < 1 then
                return true
            end
            local ok, err, item = internal.removeFrom(key, slot, amount)
            if not ok then
                return false, err
            end
            removed[#removed + 1] = { slot = slot, item = item }
            return true
        end

        local ok, err = take(fromSlot, recipe.consumeFrom)
        if ok then
            ok, err = take(toSlot, recipe.consumeTo)
        end
        if not ok then
            rollback()
            return false, err
        end
        local added, addErr = internal.addTo(key, recipe.result, recipe.amount, nil, info, 'combine')
        if not added then
            rollback()
            return false, addErr or 'no room for the result'
        end
        internal.bump(key)
        internal.broadcast(key)
        return true, info
    end)
end

local function release(src, fromSlot, toSlot)
    active[src] = nil
    if internal.setSlotBusy then
        internal.setSlotBusy(src, fromSlot, false)
        internal.setSlotBusy(src, toSlot, false)
    end
end

---The `combine` UI intent. `request` is handleIntent's envelope:
---{ token, action = 'combine', payload = { inventory, fromSlot, toSlot, revision }, primaryRevision }.
function combine.intent(src, request)
    if not enabled() then
        return false, 'combining is disabled'
    end
    local session = internal.sessionOf(src)
    local payload = type(request) == 'table' and request.payload
    if not session or type(payload) ~= 'table' then
        return false, 'invalid session action'
    end
    if payload.inventory ~= nil and payload.inventory ~= session.primary then
        return false, 'items can only be combined in your inventory'
    end
    local expected = tonumber(payload.revision)
    if expected == nil then
        expected = tonumber(request.primaryRevision)
    end
    if expected == nil then
        return false, 'stale inventory'
    end
    local key = session.primary
    local _, primary = internal.validSession(src, request.token, key, key, expected, expected)
    if not primary then
        return false, 'stale inventory'
    end
    local fromSlot, toSlot = slotNumber(payload.fromSlot, primary.slots), slotNumber(payload.toSlot, primary.slots)
    if not fromSlot or not toSlot or fromSlot == toSlot then
        return false, 'invalid item slot'
    end
    local first, second = primary.items[fromSlot], primary.items[toSlot]
    if not first or not second then
        return false, 'invalid item slot'
    end
    if active[src] or internal.isSlotBusy(src, fromSlot) or internal.isSlotBusy(src, toSlot) then
        internal.notifyBusyBlocked(src)
        return false, internal.busyError
    end

    local recipe = combine.find(first.name, second.name)
    if not recipe then
        return false, 'these items cannot be combined'
    end
    if not internal.itemDef(recipe.result) then
        return false, 'unknown result item'
    end
    if (tonumber(first.amount) or 0) < recipe.consumeFrom or (tonumber(second.amount) or 0) < recipe.consumeTo then
        return false, 'not enough items'
    end
    -- Early capacity answer, before the player waits through a bar. Read-only;
    -- the commit below is the real check.
    local crafting = inventory.crafting
    if crafting and crafting.canCraftItems then
        local needed = {}
        if recipe.consumeFrom > 0 then
            needed[#needed + 1] = { name = first.name, amount = recipe.consumeFrom }
        end
        if recipe.consumeTo > 0 then
            needed[#needed + 1] = { name = second.name, amount = recipe.consumeTo }
        end
        local fits, fitErr = crafting.canCraftItems(src, needed, { { name = recipe.result, amount = recipe.amount } })
        if not fits then
            return false, fitErr or 'no room for the result'
        end
    end

    local blocked, blockedReason = ingredientBlocked(src, key, fromSlot, toSlot)
    if blocked then
        return false, blockedReason
    end

    local fromSnap, toSnap = snapshot(first), snapshot(second)
    local waited = false
    active[src] = true
    if internal.setSlotBusy then
        internal.setSlotBusy(src, fromSlot, true)
        internal.setSlotBusy(src, toSlot, true)
    end
    local ran, ok, result = pcall(function()
        if recipe.time > 0 and settings().progress ~= false then
            waited = true
            local startedAt = GetGameTimer()
            local called, finished = pcall(Kora.callback.trigger, src, PROGRESS_CALLBACK, {
                time = recipe.time,
                label = recipe.label,
            })
            if not called or finished ~= true then
                return false, 'combine cancelled'
            end
            -- The client reports its own result, so a modified client could
            -- answer at once.
            if GetGameTimer() - startedAt < recipe.time - FINISH_TOLERANCE then
                return false, 'combine cancelled'
            end
        end
        -- The wait yielded: ask again whether the session, access and the
        -- player's state (cuffed, downed) still hold. The revision is not
        -- compared after a wait (other changes may legitimately have happened);
        -- the slots themselves are compared in commit().
        local currentSession = internal.validSession(src, request.token, key, key, (not waited) and expected or nil, nil)
        if not currentSession then
            return false, 'stale inventory'
        end
        -- Ingredients can spoil or get wet while the bar runs.
        local nowBlocked, nowReason = ingredientBlocked(src, key, fromSlot, toSlot)
        if nowBlocked then
            return false, nowReason
        end
        return commit(src, key, fromSlot, toSlot, recipe, fromSnap, toSnap)
    end)
    release(src, fromSlot, toSlot)
    if not ran then
        Kora.logging.error('combine.failed', 'Combine failed', { playerId = src, error = tostring(ok) })
        return false, 'combine failed'
    end
    if not ok then
        return false, result
    end

    -- Item-creation audit (server/audit_log.lua): the result item was minted.
    if internal.auditAdd then
        internal.auditAdd('combine', src, key, recipe.result, recipe.amount, recipe.id)
    end
    internal.recordAudit('combine', src, {
        recipe = recipe.id,
        from = first.name,
        to = second.name,
        consumed = { [first.name] = recipe.consumeFrom, [second.name] = recipe.consumeTo },
        result = recipe.result,
        amount = recipe.amount,
    })
    TriggerEvent('kora_inventory:server:combined', src, {
        recipe = recipe.id,
        result = recipe.result,
        amount = recipe.amount,
    })
    if internal.showItemBox then
        pcall(internal.showItemBox, src, recipe.result, recipe.amount, 'add', { name = recipe.result, info = result })
    end
    return true
end

if type(AddEventHandler) == 'function' then
    AddEventHandler('onResourceStop', dropOwned)
    AddEventHandler('playerDropped', function()
        active[source] = nil
    end)
end

-- Presentation list of runtime-registered recipes for a (re)connecting client.
if Kora and Kora.callback and Kora.callback.register then
    Kora.callback.register('kora_inventory:server:combinations', function()
        return combine.presentation(true)
    end)
end

exports('registerCombination', combine.register)
exports('removeCombination', combine.remove)

return combine
