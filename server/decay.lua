-- Item decay runtime. Server-only, no NUI, no net event entry point and no
-- client input: a client can neither stamp, age nor spoil an item. Everything
-- here reads the item records the server already owns and changes them through
-- the same funnel as every other mutation (kora_core setPath for players via
-- playerSetPath, removeFrom for removals, bump + broadcast for revisions).
--
-- Lazy by design (no per-item timers). An inventory is evaluated when it is
--   * VIEWED   (server.lua view() -> refresh),
--   * USED or MOVED (server.lua useItem()/transfer() -> guard), and
--   * swept: a low-frequency, batched pass over ONLINE players only
--     (Config.kora_inventory.decay.sweepSeconds).
-- The pure rules (lifetime, merge, pause) live in shared/decay.lua.

local inventory = KoraInventory
local I = assert(inventory and inventory.internal, 'kora_inventory server authority must load first')
local D = assert(inventory.decay, 'shared/decay.lua must load before server/decay.lua')

local R = {}
inventory.decayRuntime = R

-- Shelf stock never ages and evidence is locked away from every player.
local SKIP_TYPES = { shop = true, confiscation = true }

local processing = {}

local function sortedSlots(items)
    local slots = {}
    for slot in pairs(items or {}) do
        slots[#slots + 1] = slot
    end
    table.sort(slots, function(left, right)
        if type(left) == 'number' and type(right) == 'number' then
            return left < right
        end
        return tostring(left) < tostring(right)
    end)
    return slots
end

local function eligible(inv)
    return type(inv) == 'table' and type(inv.items) == 'table' and not SKIP_TYPES[inv.type]
        and not inv.blocked and not inv.durablePending
end

local function markDirty(inv)
    if inv.type ~= 'player' and inventory.persistence and inventory.persistence.markDirty then
        inventory.persistence.markDirty(inv)
    end
end

---Walks an inventory and works out what decay has to do. Pure planner: it never
---writes. Returns { stamps = {...}, expired = {...} }; both empty means no work.
local function plan(inv, cfg, now)
    local paused = D.paused(cfg, inv.type)
    local rules, result = {}, { stamps = {}, expired = {} }
    for _, slot in ipairs(sortedSlots(inv.items)) do
        local item = inv.items[slot]
        if type(item) == 'table' and type(item.name) == 'string' then
            local rule = rules[item.name]
            if rule == nil then
                rule = D.rule(item.name, I.itemDef(item.name), cfg) or false
                rules[item.name] = rule
            end
            if rule then
                local info = item.info or item.metadata
                -- Fast path: already stamped and in the right pause state, so
                -- nothing to write unless it has expired. No copy needed.
                local settled = D.stamped(info) and type(info.decayLifetime) == 'number'
                    and (type(info.decayPausedAt) == 'number') == paused
                local status = settled and D.status(info, rule, now)
                if status and not status.expired then
                    goto continue
                end
                local copy = I.copy(item)
                local changed = D.stampItem(copy, rule, now, paused)
                changed = D.placeItem(copy, paused, now) or changed
                status = D.status(copy.info or copy.metadata, rule, now)
                if status and status.expired then
                    result.expired[#result.expired + 1] = { slot = slot, item = copy, rule = rule }
                elseif changed then
                    result.stamps[#result.stamps + 1] = { slot = slot, item = copy }
                end
            end
            ::continue::
        end
    end
    return result
end

local function write(inv, slot, item)
    if inv.type == 'player' then
        return I.playerSetPath(inv.source, { 'items', slot }, item)
    end
    inv.items[slot] = item
    markDirty(inv)
    return true
end

---Applies one spoiled stack: convert in place (same slot and amount) or remove.
---Returns the outcome record, or nil if nothing could be changed.
local function expire(inventoryKey, inv, entry, cfg, now)
    local item, rule, slot = entry.item, entry.rule, entry.slot
    local amount = math.max(1, math.floor(tonumber(item.amount) or 1))
    local outcome = { slot = slot, item = item.name, amount = amount, action = 'remove' }
    if rule.action == 'convert' and rule.into then
        local intoDef = I.itemDef(rule.into)
        -- A unique/weapon target cannot take a whole stack in one slot.
        if intoDef and not intoDef.unique and intoDef.type ~= 'weapon' then
            local fresh = I.buildItem(rule.into, amount, slot, {})
            if fresh and (not I.placement or #I.placement(inv, fresh, slot, 1, item.gridRotated, slot) == 1) then
                D.placeItem(fresh, D.paused(cfg, inv.type), now)
                local ok = write(inv, slot, fresh)
                if not ok then
                    return nil
                end
                outcome.action, outcome.into, outcome.created = 'convert', rule.into, fresh
                return outcome
            end
        else
            Kora.logging.warn('inventory.decay_bad_target', 'Decay target item is unknown or cannot stack; removing instead', {
                item = item.name, into = rule.into,
            })
        end
    end
    local ok = I.removeFrom(inventoryKey, slot, amount)
    if not ok then
        return nil
    end
    outcome.removed = item
    return outcome
end

---Evaluate one inventory: stamp unseen items, apply pause/resume, and spoil
---expired stacks. Returns true when it changed the inventory's contents (so the
---caller should re-read it). `viewer` is the player looking at it, if any.
---@param inventoryKey string
---@param inv table|nil
---@param viewer integer|nil
---@return boolean changed
function R.process(inventoryKey, inv, viewer)
    local cfg = D.config()
    if not D.enabled(cfg) or processing[inventoryKey] then
        return false
    end
    inv = inv or I.getInventory(inventoryKey)
    if not eligible(inv) then
        return false
    end
    local now = os.time()
    local dry = plan(inv, cfg, now)
    if #dry.stamps == 0 and #dry.expired == 0 then
        return false
    end
    processing[inventoryKey] = true
    local ok, changed, results = pcall(I.lock, { inventoryKey }, function()
        -- Re-plan inside the critical section: the dry run was unlocked.
        local current = I.getInventory(inventoryKey)
        if not eligible(current) then
            return false
        end
        local work = plan(current, cfg, now)
        local owner = current.type == 'player' and current.source or nil
        for _, entry in ipairs(work.stamps) do
            write(current, entry.slot, entry.item)
        end
        local outcomes = {}
        for _, entry in ipairs(work.expired) do
            -- Never pull an item out from under a running use handler.
            if not (owner and I.isSlotBusy(owner, entry.slot)) then
                local outcome = expire(inventoryKey, current, entry, cfg, now)
                if outcome then
                    outcomes[#outcomes + 1] = outcome
                end
            end
        end
        if #outcomes > 0 then
            I.bump(inventoryKey)
            I.broadcast(inventoryKey)
            if current.type == 'drop' then
                I.removeEmptyDrop(I.getInventory(inventoryKey) or current, viewer)
            end
        end
        return #outcomes > 0, outcomes
    end)
    processing[inventoryKey] = nil
    if not ok then
        Kora.logging.error('inventory.decay_failed', 'Item decay evaluation failed', { error = tostring(changed) })
        return false
    end
    if not changed then
        return false
    end
    local owner = inv.type == 'player' and inv.source or nil
    for _, outcome in ipairs(results or {}) do
        I.recordAudit('decay', owner or viewer, {
            inventory = inventoryKey, item = outcome.item, amount = outcome.amount, slot = outcome.slot,
            action = outcome.action, into = outcome.into,
        })
        if owner then
            -- The normal item receipt: the spoiled stack goes out, its
            -- replacement (if any) comes in.
            I.showItemBox(owner, outcome.item, outcome.amount, 'remove', outcome.removed or { name = outcome.item })
            if outcome.created then
                I.showItemBox(owner, outcome.into, outcome.amount, 'add', outcome.created)
            end
        end
        -- The converted item is a creation: item-creation audit (audit_log.lua).
        if outcome.created and I.auditAdd then
            I.auditAdd('decay', owner, inventoryKey, outcome.into, outcome.amount, 'decay:' .. tostring(outcome.item))
        end
        TriggerEvent('kora_inventory:server:itemDecayed', owner or viewer, {
            inventory = inventoryKey, item = outcome.item, amount = outcome.amount, slot = outcome.slot,
            action = outcome.action, into = outcome.into,
        })
    end
    return true
end

---The view hook: evaluate before the view is built.
---@return boolean changed
function R.refresh(inventoryKey, inv)
    return R.process(inventoryKey, inv, nil)
end

---The use/move hook. True when the item in `slot` has spoiled (it is converted
---or removed here), so the caller must refuse the action.
---@param inventoryKey string
---@param slot integer
---@param src integer|nil
---@return boolean spoiled
function R.guard(inventoryKey, slot, src)
    local cfg = D.config()
    if not D.enabled(cfg) or type(slot) ~= 'number' then
        return false
    end
    local inv = I.getInventory(inventoryKey)
    if not eligible(inv) then
        return false
    end
    local item = inv.items[slot]
    if type(item) ~= 'table' then
        return false
    end
    local rule = D.rule(item.name, I.itemDef(item.name), cfg)
    local status = rule and D.status(item.info or item.metadata, rule, os.time())
    if not (status and status.expired) then
        return false
    end
    R.process(inventoryKey, inv, src)
    return true
end

-- Sweep: ONLINE players' inventories only, a few per tick so a large server
-- never stalls. Secondary inventories are evaluated when someone views them.
local SWEEP_BATCH = 5

function R.sweep()
    if not D.enabled(D.config()) then
        return 0
    end
    local visited = 0
    for _, player in ipairs(GetPlayers()) do
        local src = tonumber(player)
        local key = src and I.playerKey(src)
        if key and I.getInventory(key) then
            R.process(key, nil, src)
            visited = visited + 1
            if visited % SWEEP_BATCH == 0 then
                Wait(50)
            end
        end
    end
    return visited
end

CreateThread(function()
    local lastRun = GetGameTimer()
    while true do
        Wait(5000)
        -- Read every pass so /config edits (including turning it off) apply live.
        local interval = D.sweepSeconds(D.config())
        if interval > 0 and GetGameTimer() - lastRun >= interval * 1000 then
            lastRun = GetGameTimer()
            local ok, err = pcall(R.sweep)
            if not ok then
                Kora.logging.error('inventory.decay_sweep_failed', 'Item decay sweep failed', { error = tostring(err) })
            end
        end
    end
end)
