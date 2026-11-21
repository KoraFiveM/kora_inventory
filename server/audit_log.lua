-- Item-creation audit log.
--
-- Purpose: tell admins WHICH script created WHICH items, so duplication and
-- badly written scripts can be found. server.lua calls `auditLog.record` from
-- every place an item is created (never for transfers between inventories),
-- and server/admin_tools.lua serves the /invaudit viewer from `auditLog.query`.
--
-- Design rules:
--   * Recording never waits on SQL. Entries go to an in-memory ring and a
--     queue; a background tick writes the queue in batches (flushSeconds, or as
--     soon as BATCH_SIZE rows wait) through persistence.auditInsertBatch.
--   * The invoking resource is captured where an export ENTERS
--     (`withInvoker`, keyed by coroutine) because GetInvokingResource() is
--     unreliable once the call has gone deeper or yielded.
--   * All settings are read at call time from Config.kora_inventory.audit.
--   * Read-only toward the browser: this module has no net events.

KoraInventory = KoraInventory or {}
local inventory = KoraInventory
local auditLog = {}
inventory.auditLog = auditLog

local resourceName = GetCurrentResourceName()

local BATCH_SIZE = 200
local PAGE_SIZE = 100
local QUEUE_CAP = 5000 -- rows held while the database is unavailable
local PRUNE_INTERVAL = 3600
local RANGES = { ['1h'] = 3600, ['24h'] = 86400, ['7d'] = 604800 }
auditLog.PAGE_SIZE = PAGE_SIZE
auditLog.RANGES = RANGES

-- Overridable for tests.
auditLog.clock = os.time
auditLog.sink = nil -- function(rows) -> ok|nil, err ; defaults to persistence

local ring, queue = {}, {}
local lastFlush, lastPrune, flushing, flushScheduled = nil, nil, false, false
local contexts = {}
local anomalyState, anomalyFired = {}, {}
local lastSinkWarn = 0

local function settings()
    local config = Config and Config.kora_inventory
    return type(config) == 'table' and type(config.audit) == 'table' and config.audit or {}
end

local function anomalySettings()
    local value = settings().anomaly
    return type(value) == 'table' and value or {}
end

local function number(value, default, minimum, maximum)
    value = tonumber(value) or default
    if minimum and value < minimum then
        value = minimum
    end
    if maximum and value > maximum then
        value = maximum
    end
    return value
end

local function now()
    return math.floor(auditLog.clock())
end

---@return boolean enabled
function auditLog.enabled()
    return settings().enabled == true
end

local function persisting()
    return settings().persist == true
end

-- ---------------------------------------------------------------------------
-- Invoking resource, captured at the export boundary.
-- ---------------------------------------------------------------------------

---Runs `fn(...)` with `resource` recorded as the caller for this coroutine.
---Wrap every exported function that can create items. Nested calls keep the
---outermost non-nil caller, so an internal re-entry does not hide the origin.
function auditLog.withInvoker(resource, fn, ...)
    local thread = coroutine.running() or 'main'
    local previous = contexts[thread]
    if resource ~= nil then
        contexts[thread] = previous or tostring(resource)
    end
    local results = table.pack(pcall(fn, ...))
    contexts[thread] = previous
    if not results[1] then
        error(results[2], 0)
    end
    return table.unpack(results, 2, results.n)
end

---Wraps an export so its caller is captured when it enters.
function auditLog.wrapExport(fn)
    return function(...)
        return auditLog.withInvoker(GetInvokingResource and GetInvokingResource() or nil, fn, ...)
    end
end

---The captured caller for the running coroutine, or `fallback`.
function auditLog.invoker(fallback)
    return contexts[coroutine.running() or 'main'] or fallback or resourceName
end

-- ---------------------------------------------------------------------------
-- Rolling anomaly counters.
-- ---------------------------------------------------------------------------

local function counterAdd(key, amount, at, window)
    local state = anomalyState[key]
    if not state then
        state = { buckets = {}, total = 0 }
        anomalyState[key] = state
    end
    state.buckets[at] = (state.buckets[at] or 0) + amount
    state.total = state.total + amount
    local oldest = at - window
    for second, value in pairs(state.buckets) do
        if second <= oldest then
            state.buckets[second] = nil
            state.total = state.total - value
        end
    end
    return state.total
end

local function raiseAnomaly(kind, key, count, threshold, window, entry)
    local at = now()
    local gate = anomalyFired[key]
    -- Once per window per key.
    if gate and at < gate + window then
        return false
    end
    anomalyFired[key] = at
    local payload = {
        kind = kind,
        key = key,
        count = count,
        threshold = threshold,
        windowSeconds = window,
        resource = entry.resource,
        citizenid = entry.citizenid,
        source = entry.source,
        item = entry.item,
        at = at,
    }
    Kora.logging.warn('audit.anomaly', 'Unusual item creation', payload)
    TriggerEvent('kora_inventory:server:auditAnomaly', payload)
    return true
end

local function trackAnomaly(entry)
    local settingsTable = anomalySettings()
    if settingsTable.enabled ~= true or entry.action == 'omnipack' or entry.action == 'remove' then
        return
    end
    local window = number(settingsTable.windowSeconds, 300, 1, 86400)
    local at = entry.at
    -- Prune expired keys occasionally so counters for scripts that stopped do
    -- not accumulate forever.
    for key, state in pairs(anomalyState) do
        if state.total <= 0 or (state.last or 0) <= at - window then
            anomalyState[key] = nil
        end
    end
    for key, gate in pairs(anomalyFired) do
        if at >= gate + window then
            anomalyFired[key] = nil
        end
    end
    -- kora_inventory's own shops/crafting are many players' normal activity;
    -- a per-resource limit only makes sense for OTHER scripts.
    if entry.resource and entry.resource ~= resourceName then
        local key = 'resource:' .. entry.resource
        local total = counterAdd(key, entry.amount, at, window)
        anomalyState[key].last = at
        local threshold = number(settingsTable.perResourceThreshold, 500, 1)
        if total >= threshold then
            raiseAnomaly('resource', key, total, threshold, window, entry)
        end
    end
    local who = entry.citizenid or (entry.source and ('src' .. tostring(entry.source)))
    if who then
        local key = 'player:' .. who
        local total = counterAdd(key, entry.amount, at, window)
        anomalyState[key].last = at
        local threshold = number(settingsTable.perPlayerThreshold, 200, 1)
        if total >= threshold then
            raiseAnomaly('player', key, total, threshold, window, entry)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Recording and batching.
-- ---------------------------------------------------------------------------

local function clean(value, limit)
    if value == nil then
        return nil
    end
    value = tostring(value)
    return #value > limit and value:sub(1, limit) or value
end

local function ringLimit()
    return math.floor(number((Config.kora_inventory or {}).auditLimit, 1000, 100, 20000))
end

---Records one item creation (or, with trackRemovals, removal). Never yields.
---@param entry table { action, source, citizenid, item, amount, inventory, resource, reason }
---@return table|nil recorded the stored entry, nil when disabled or invalid
function auditLog.record(entry)
    if not auditLog.enabled() or type(entry) ~= 'table' then
        return nil
    end
    local action = clean(entry.action, 64)
    local item = clean(entry.item, 96)
    local amount = math.floor(tonumber(entry.amount) or 0)
    if not action or not item or amount < 1 then
        return nil
    end
    if action == 'remove' and settings().trackRemovals ~= true then
        return nil
    end
    local stored = {
        at = now(),
        action = action,
        source = tonumber(entry.source) and math.floor(tonumber(entry.source)) or nil,
        citizenid = clean(entry.citizenid, 50),
        item = item:lower(),
        amount = amount,
        inventory = clean(entry.inventory, 160),
        resource = clean(entry.resource or auditLog.invoker(), 96),
        reason = clean(entry.reason, 255),
    }
    ring[#ring + 1] = stored
    local overflow = #ring - ringLimit()
    if overflow > 0 then
        table.move(ring, overflow + 1, #ring, 1)
        for index = #ring, #ring - overflow + 1, -1 do
            ring[index] = nil
        end
    end
    if persisting() then
        queue[#queue + 1] = stored
        if #queue > QUEUE_CAP then
            table.remove(queue, 1)
        end
        if #queue >= BATCH_SIZE and not flushScheduled and CreateThread then
            flushScheduled = true
            CreateThread(function()
                flushScheduled = false
                auditLog.flush()
            end)
        end
    end
    -- Counting must never be able to break an item add.
    local ok, err = pcall(trackAnomaly, stored)
    if not ok then
        Kora.logging.warn('audit.anomaly_failed', 'Audit anomaly tracking failed', { error = tostring(err) })
    end
    return stored
end

local function defaultSink(rows)
    local persistence = inventory.persistence
    if not persistence or not persistence.auditInsertBatch then
        return nil, 'persistence unavailable'
    end
    return persistence.auditInsertBatch(rows)
end

---Writes every queued row, in batches of BATCH_SIZE. Yields while SQL runs, so
---call it from a thread (the tick does). A failed batch is put back at the
---front of the queue (bounded by QUEUE_CAP) and retried at the next tick.
---@return integer written
function auditLog.flush()
    if flushing or #queue == 0 then
        return 0
    end
    flushing = true
    lastFlush = now()
    local written = 0
    local sink = auditLog.sink or defaultSink
    while #queue > 0 do
        local batch = {}
        for index = 1, math.min(BATCH_SIZE, #queue) do
            batch[index] = queue[index]
        end
        local ok, result, err = pcall(sink, batch)
        if not ok then
            result, err = nil, result
        end
        if not result then
            -- Leave the rows queued (they are still at the front) and retry later.
            if now() - lastSinkWarn >= 60 then
                lastSinkWarn = now()
                Kora.logging.warn('audit.flush_failed', 'Audit rows could not be written', { error = tostring(err), queued = #queue })
            end
            break
        end
        local length = #queue
        table.move(queue, #batch + 1, length, 1)
        for index = length, length - #batch + 1, -1 do
            queue[index] = nil
        end
        written = written + #batch
    end
    flushing = false
    return written
end

---Number of rows waiting to be written (for tests and diagnostics).
function auditLog.pending()
    return #queue
end

---Oldest timestamp that is still kept: now minus retentionDays.
---@param at integer|nil unix seconds, defaults to the clock
---@return integer cutoff
function auditLog.retentionCutoff(at)
    local days = number(settings().retentionDays, 14, 1, 3650)
    return math.floor(at or now()) - math.floor(days * 86400)
end

---Deletes entries older than the retention cutoff from memory and, when the
---audit is persisted, from the table. Yields while SQL runs.
---@return integer cutoff
function auditLog.prune()
    local cutoff = auditLog.retentionCutoff()
    lastPrune = now()
    local kept = {}
    for _, entry in ipairs(ring) do
        if entry.at >= cutoff then
            kept[#kept + 1] = entry
        end
    end
    ring = kept
    if persisting() then
        local persistence = inventory.persistence
        if persistence and persistence.auditPrune then
            local ok, result, err = pcall(persistence.auditPrune, cutoff)
            if not ok or result == nil then
                Kora.logging.warn('audit.prune_failed', 'Audit prune failed', { error = tostring(ok and err or result) })
            end
        end
    end
    return cutoff
end

---One scheduler step: flush when flushSeconds elapsed, prune hourly. Called
---about once a second by the background thread; safe to call from tests.
function auditLog.tick()
    local at = now()
    if not auditLog.enabled() then
        return
    end
    if persisting() and #queue > 0 then
        local every = number(settings().flushSeconds, 10, 1, 3600)
        if lastFlush == nil or at - lastFlush >= every then
            auditLog.flush()
        end
    end
    if lastPrune == nil or at - lastPrune >= PRUNE_INTERVAL then
        auditLog.prune()
    end
end

-- ---------------------------------------------------------------------------
-- Reading (the /invaudit viewer).
-- ---------------------------------------------------------------------------

---Turns viewer input into a safe filter. Unknown fields are dropped.
---@param raw any
---@return table filter { since, range, citizenid, source, item, resource, page }
function auditLog.normaliseFilter(raw)
    raw = type(raw) == 'table' and raw or {}
    local range = type(raw.range) == 'string' and RANGES[raw.range] and raw.range or '24h'
    local filter = { range = range, since = now() - RANGES[range] }
    local player = clean(raw.player, 50)
    if player then
        player = player:match('^%s*(.-)%s*$')
        if player ~= '' then
            if player:match('^%d+$') and #player <= 6 then
                filter.source = tonumber(player)
            else
                filter.citizenid = player
            end
        end
    end
    local item = clean(raw.item, 96)
    if item and item:match('%S') then
        filter.item = item:match('^%s*(.-)%s*$'):lower()
    end
    local resource = clean(raw.resource, 96)
    if resource and resource:match('%S') then
        filter.resource = resource:match('^%s*(.-)%s*$')
    end
    filter.page = math.max(0, math.min(10000, math.floor(tonumber(raw.page) or 0)))
    return filter
end

local function matches(entry, filter)
    if entry.at < filter.since then
        return false
    end
    if filter.source and entry.source ~= filter.source then
        return false
    end
    if filter.citizenid and entry.citizenid ~= filter.citizenid then
        return false
    end
    if filter.item and not entry.item:find(filter.item, 1, true) then
        return false
    end
    if filter.resource and not (entry.resource or ''):lower():find(filter.resource:lower(), 1, true) then
        return false
    end
    return true
end

---Top resources and items by added amount since `since`, from entries.
---@param entries table[]
---@param since integer
---@param limit integer|nil
---@return table summary { resources = { { name, amount, count } }, items = ... }
function auditLog.summarise(entries, since, limit)
    limit = limit or 5
    local totals = { resources = {}, items = {} }
    for _, entry in ipairs(entries) do
        if entry.at >= since and entry.action ~= 'remove' then
            for field, bucket in pairs({ resource = totals.resources, item = totals.items }) do
                local name = entry[field]
                if name then
                    local row = bucket[name] or { name = name, amount = 0, count = 0 }
                    row.amount, row.count = row.amount + entry.amount, row.count + 1
                    bucket[name] = row
                end
            end
        end
    end
    local summary = { resources = {}, items = {} }
    for _, kind in ipairs({ 'resources', 'items' }) do
        for _, row in pairs(totals[kind]) do
            summary[kind][#summary[kind] + 1] = row
        end
        table.sort(summary[kind], function(a, b)
            if a.amount ~= b.amount then
                return a.amount > b.amount
            end
            return a.name < b.name
        end)
        for index = #summary[kind], limit + 1, -1 do
            summary[kind][index] = nil
        end
    end
    return summary
end

---Newest-first page of entries plus the last-hour summary. Yields (SQL) only
---when the audit is persisted and the database is ready.
---@param raw any viewer input; normalised here
---@return table result { rows, hasMore, page, pageSize, filter, summary, source }
function auditLog.query(raw)
    local filter = auditLog.normaliseFilter(raw)
    local result = { page = filter.page, pageSize = PAGE_SIZE, filter = filter, rows = {}, hasMore = false }
    local persistence = inventory.persistence
    local ready = persisting() and persistence and persistence.auditQuery
        and persistence.getStatus and persistence.getStatus().ready
    if ready then
        auditLog.flush()
        local rows, more = persistence.auditQuery(filter, PAGE_SIZE, filter.page * PAGE_SIZE)
        if rows then
            result.rows, result.hasMore, result.source = rows, more == true, 'database'
            local summary = persistence.auditSummary(now() - 3600, 5)
            result.summary = summary or { resources = {}, items = {} }
            return result
        end
        Kora.logging.warn('audit.query_failed', 'Audit query failed; showing recent in-memory entries', { error = tostring(more) })
    end
    result.source = 'memory'
    local skipped = filter.page * PAGE_SIZE
    for index = #ring, 1, -1 do
        local entry = ring[index]
        if matches(entry, filter) then
            if skipped > 0 then
                skipped = skipped - 1
            elseif #result.rows < PAGE_SIZE then
                result.rows[#result.rows + 1] = inventory.copy(entry)
            else
                result.hasMore = true
                break
            end
        end
    end
    result.summary = auditLog.summarise(ring, now() - 3600, 5)
    return result
end

---Console fallback: prints a short summary through Kora.logging.info.
---@param raw any same shape as the viewer filter
function auditLog.printSummary(raw)
    local result = auditLog.query(raw)
    local parts = {}
    for _, row in ipairs(result.summary.resources) do
        parts[#parts + 1] = ('%s=%d'):format(row.name, row.amount)
    end
    local items = {}
    for _, row in ipairs(result.summary.items) do
        items[#items + 1] = ('%s=%d'):format(row.name, row.amount)
    end
    Kora.logging.info('audit.summary', 'Item-creation audit summary', {
        range = result.filter.range,
        shown = #result.rows,
        hasMore = result.hasMore,
        source = result.source,
        topResourcesLastHour = table.concat(parts, ', '),
        topItemsLastHour = table.concat(items, ', '),
    })
    for index = 1, math.min(#result.rows, 10) do
        local row = result.rows[index]
        Kora.logging.info('audit.entry', 'Audit entry', {
            at = row.at, action = row.action, citizenid = row.citizenid, source = row.source,
            item = row.item, amount = row.amount, resource = row.resource, inventory = row.inventory,
            reason = row.reason,
        })
    end
    return result
end

---Test hook: forget all in-memory state.
function auditLog.reset()
    ring, queue = {}, {}
    lastFlush, lastPrune, flushing, flushScheduled = nil, nil, false, false
    contexts, anomalyState, anomalyFired = {}, {}, {}
    lastSinkWarn = 0
end

-- ---------------------------------------------------------------------------
-- Background work. A plain loop in a thread: nothing here blocks an item add.
-- ---------------------------------------------------------------------------

if CreateThread then
    CreateThread(function()
        while true do
            Wait(1000)
            local ok, err = pcall(auditLog.tick)
            if not ok then
                Kora.logging.warn('audit.tick_failed', 'Audit scheduler step failed', { error = tostring(err) })
            end
        end
    end)
end

if AddEventHandler then
    -- Clean up once the table exists, instead of waiting up to an hour.
    AddEventHandler('kora_inventory:server:persistenceReady', function()
        if auditLog.enabled() then
            CreateThread(auditLog.prune)
        end
    end)
    AddEventHandler('onResourceStop', function(stopped)
        if stopped == resourceName and #queue > 0 then
            CreateThread(auditLog.flush)
        end
    end)
end
