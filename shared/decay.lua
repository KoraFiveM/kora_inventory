-- Item decay / expiry: the pure maths. No state, no exports, no config reads
-- except the thin `*Config` wrappers at the bottom, so test/smoke/decay.lua can
-- drive every rule with explicit settings and a fixed clock.
--
-- Model (lazy, server-authoritative, no per-item timers):
--   * A decaying item carries `info.createdAt` (os.time() when it was made or
--     first seen) and `info.decayLifetime` (seconds, the lifetime it was
--     created with). remaining = lifetime - age, where age is measured up to
--     `info.decayPausedAt` while the item sits in a paused inventory.
--   * Items without a stamp are stamped on first sight (no retroactive spoiling).
--   * Stacks merge by the OLDEST member (`mergePolicy = 'oldest'`, default) or
--     never merge across different timestamps (`'separate'`).
KoraInventory = KoraInventory or {}
local inventory = KoraInventory

local D = {}
inventory.decay = D

-- Metadata keys owned by this feature. They are bookkeeping, not display
-- metadata, and are ignored when comparing stacks under the 'oldest' policy.
D.KEYS = { createdAt = true, decayLifetime = true, decayPausedAt = true }

-- Inventory types whose time can be paused (`pauseIn.<type>`). Player
-- inventories always count.
D.PAUSE_TYPES = { stash = true, trunk = true, glovebox = true, container = true, drop = true }

D.MIN_SWEEP_SECONDS = 30

local function finite(value)
    return type(value) == 'number' and value == value and value > -math.huge and value < math.huge
end

local function positive(value)
    value = tonumber(value)
    return finite(value) and value > 0 and value or nil
end

local function itemKey(name)
    return type(name) == 'string' and name:lower() or nil
end

---True when decay is switched on in `cfg` (Config.kora_inventory.decay).
function D.enabled(cfg)
    return type(cfg) == 'table' and cfg.enabled == true
end

---'oldest' (default) or 'separate'.
function D.mergePolicy(cfg)
    return type(cfg) == 'table' and cfg.mergePolicy == 'separate' and 'separate' or 'oldest'
end

---Seconds between online-player sweeps; 0 = off. Never below MIN_SWEEP_SECONDS
---so a typo cannot turn the sweep into a hot loop.
function D.sweepSeconds(cfg)
    if not D.enabled(cfg) then return 0 end
    local seconds = tonumber(cfg.sweepSeconds)
    if seconds == nil then seconds = 300 end
    if not finite(seconds) or seconds <= 0 then return 0 end
    return math.max(D.MIN_SWEEP_SECONDS, math.floor(seconds))
end

---Whether time stops counting inside an inventory of this type.
function D.paused(cfg, inventoryType)
    if type(cfg) ~= 'table' or type(cfg.pauseIn) ~= 'table' then return false end
    return D.PAUSE_TYPES[inventoryType] == true and cfg.pauseIn[inventoryType] == true
end

---The decay rule for an item, or nil when it does not decay.
---A `cfg.items[name]` entry wins over the item definition's own
---`decay = { lifetime, into }`. `cfg.items[name] = false` opts an item out.
---Result: { lifetime = seconds, action = 'convert' | 'remove', into = name|nil }.
---@param name string
---@param def table|nil kora_core item definition
---@param cfg table|nil
function D.rule(name, def, cfg)
    if not D.enabled(cfg) then return nil end
    name = itemKey(name)
    if not name then return nil end
    local entry
    if type(cfg.items) == 'table' and cfg.items[name] ~= nil then
        entry = cfg.items[name]
        if type(entry) ~= 'table' then return nil end
    elseif type(def) == 'table' and type(def.decay) == 'table' then
        entry = def.decay
    else
        return nil
    end
    local lifetime = positive(entry.lifetime)
    if not lifetime then return nil end
    local into = type(entry.into) == 'string' and entry.into ~= '' and entry.into:lower() or nil
    -- defaultAction = 'remove' makes every spoiled item vanish; 'convert'
    -- (default) converts when the rule names an `into` item and removes otherwise.
    if cfg.defaultAction == 'remove' or not into then
        return { lifetime = lifetime, action = 'remove' }
    end
    return { lifetime = lifetime, action = 'convert', into = into }
end

local function infoOf(item)
    if type(item) ~= 'table' then return nil end
    if type(item.info) ~= 'table' then
        item.info = {}
    end
    return item.info
end

-- `info` and `metadata` are two copies of the same table on a stored item.
local function syncMetadata(item)
    if item.metadata == item.info then return end
    if type(item.metadata) ~= 'table' then item.metadata = {} end
    for key in pairs(D.KEYS) do
        item.metadata[key] = item.info[key]
    end
end

---True when the info carries a usable stamp.
function D.stamped(info)
    return type(info) == 'table' and finite(info.createdAt)
end

---Seconds the item has aged at `now`. Time stops at `decayPausedAt`.
function D.age(info, now)
    if not D.stamped(info) then return nil end
    local upTo = finite(info.decayPausedAt) and info.decayPausedAt or now
    local age = upTo - info.createdAt
    return age > 0 and age or 0 -- a clock set back must not make items older
end

---Lifetime for this instance: the stamped snapshot wins over the current rule,
---so editing the config tunes newly created items without suddenly spoiling
---(or reviving) ones players already hold.
function D.lifetime(info, rule)
    return positive(type(info) == 'table' and info.decayLifetime) or (rule and rule.lifetime) or nil
end

---Clamps to 0..1 (1 = fresh, 0 = spoiled).
function D.fraction(remaining, lifetime)
    if not finite(remaining) or not positive(lifetime) then return 0 end
    local value = remaining / lifetime
    if value < 0 then return 0 end
    if value > 1 then return 1 end
    return value
end

---Evaluate an item at `now`.
---Returns nil for items that do not decay or are not stamped yet; otherwise
---{ remaining, fraction, lifetime, expired, paused }.
function D.status(info, rule, now)
    if not rule or not D.stamped(info) then return nil end
    local lifetime = D.lifetime(info, rule)
    if not lifetime then return nil end
    local remaining = lifetime - D.age(info, now)
    return {
        remaining = remaining > 0 and remaining or 0,
        fraction = D.fraction(remaining, lifetime),
        lifetime = lifetime,
        expired = remaining <= 0,
        paused = finite(info.decayPausedAt),
    }
end

---What to do with an expired item: nil (nothing yet), or the rule's action.
---@return string|nil action 'convert' | 'remove'
---@return string|nil into
function D.decision(info, rule, now)
    local status = D.status(info, rule, now)
    if not status or not status.expired then return nil end
    return rule.action, rule.into
end

---Stamp an item that has no stamp. `paused` = it sits in a paused inventory, so
---the clock starts stopped. Returns true when the item changed.
function D.stampItem(item, rule, now, paused)
    if not rule or type(item) ~= 'table' then return false end
    local info = infoOf(item)
    local changed = false
    if not D.stamped(info) then
        info.createdAt = now
        info.decayLifetime = rule.lifetime
        info.decayPausedAt = nil
        changed = true
    elseif not positive(info.decayLifetime) then
        info.decayLifetime = rule.lifetime
        changed = true
    end
    if paused and not finite(info.decayPausedAt) then
        info.decayPausedAt = now
        changed = true
    end
    if changed then syncMetadata(item) end
    return changed
end

---Start the pause clock (item enters a paused inventory).
function D.enterItem(item, now)
    local info = type(item) == 'table' and infoOf(item)
    if not info or not D.stamped(info) or finite(info.decayPausedAt) then return false end
    info.decayPausedAt = now
    syncMetadata(item)
    return true
end

---Stop the pause clock (item leaves a paused inventory): shift createdAt forward
---by the time spent paused so that time did not count.
function D.leaveItem(item, now)
    local info = type(item) == 'table' and infoOf(item)
    if not info or not finite(info.decayPausedAt) then return false end
    if D.stamped(info) then
        local paused = now - info.decayPausedAt
        if paused > 0 then info.createdAt = info.createdAt + paused end
    end
    info.decayPausedAt = nil
    syncMetadata(item)
    return true
end

---Apply the move into an inventory: pause when it is paused, resume otherwise.
---Moving within one paused inventory keeps the original pause start.
function D.placeItem(item, destinationPaused, now)
    if destinationPaused then return D.enterItem(item, now) end
    return D.leaveItem(item, now)
end

---Merge `incoming` into `target` (both full item tables, same name) under the
---policy: the merged stack takes the OLDEST member's stamp (largest age at
---`now`). An unstamped side adopts the stamped side's. Returns true when the
---target changed. Policy 'separate' never merges stamps (stack checks already
---keep differently stamped items apart), so this is a no-op there.
function D.mergeItems(target, incoming, now, policy)
    if policy == 'separate' or type(target) ~= 'table' or type(incoming) ~= 'table' then return false end
    local targetInfo, incomingInfo = infoOf(target), infoOf(incoming)
    local targetStamped, incomingStamped = D.stamped(targetInfo), D.stamped(incomingInfo)
    if not incomingStamped then return false end
    if targetStamped then
        -- "Oldest" = least life left (not raw age: lifetimes may differ). A tie
        -- keeps the target's stamp.
        local mineLeft = (D.lifetime(targetInfo) or 0) - D.age(targetInfo, now)
        local theirsLeft = (D.lifetime(incomingInfo) or 0) - D.age(incomingInfo, now)
        if mineLeft <= theirsLeft then return false end
    end
    targetInfo.createdAt = incomingInfo.createdAt
    targetInfo.decayLifetime = incomingInfo.decayLifetime
    targetInfo.decayPausedAt = incomingInfo.decayPausedAt
    syncMetadata(target)
    return true
end

---Copy of an info table without the decay bookkeeping keys.
function D.strip(info)
    if type(info) ~= 'table' then return info end
    if info.createdAt == nil and info.decayLifetime == nil and info.decayPausedAt == nil then return info end
    local out = {}
    for key, value in pairs(info) do
        if not D.KEYS[key] then out[key] = value end
    end
    return out
end

---Remove the decay stamp from an item (shop stock never ages).
function D.unstampItem(item)
    if type(item) ~= 'table' then return false end
    local had = false
    for _, field in ipairs({ 'info', 'metadata' }) do
        local table_ = item[field]
        if type(table_) == 'table' then
            for key in pairs(D.KEYS) do
                if table_[key] ~= nil then
                    table_[key] = nil
                    had = true
                end
            end
        end
    end
    return had
end

---The info to compare when deciding whether two stacks are the same item.
---'oldest' ignores the stamps (they are reconciled on merge); 'separate' keeps
---them so only identically stamped items stack.
function D.comparable(info, policy)
    if policy == 'separate' then return info end
    return D.strip(info)
end

local UNITS = { { 86400, 'd' }, { 3600, 'h' }, { 60, 'm' }, { 1, 's' } }

---Short duration text: '2d 4h', '1h 20m', '45m', '30s'. Two units at most;
---anything under a second reads '0s'.
function D.format(seconds)
    seconds = tonumber(seconds)
    if not finite(seconds) or seconds < 1 then return '0s' end
    seconds = math.floor(seconds)
    local parts = {}
    for _, unit in ipairs(UNITS) do
        local count = math.floor(seconds / unit[1])
        if count > 0 then
            parts[#parts + 1] = count .. unit[2]
            seconds = seconds - count * unit[1]
        end
        if #parts == 2 then break end
    end
    return table.concat(parts, ' ')
end

---The view-only `decay` field for an item: { remaining, fraction }, or nil.
function D.viewField(info, rule, now)
    local status = D.status(info, rule, now)
    if not status then return nil end
    return { remaining = math.floor(status.remaining), fraction = status.fraction }
end

-- Config wrappers: read Config.kora_inventory.decay at call time so /config
-- edits apply on the next call.
function D.config()
    local root = Config and Config.kora_inventory
    return root and root.decay or nil
end

return D
