-- Item-creation audit log: recording, batching, retention, anomaly windows and
-- the invoking resource captured at the export boundary. Runs the real
-- server/audit_log.lua and the real server.lua exports without an FXServer.
local logSpy = dofile('test/logging_spy.lua')
local H = dofile('test/harness.lua')
Config = {}
dofile('config.lua')
dofile('shared.lua')

local events, threads, registered = {}, {}, {}
local invokingResource
local data = { [7] = { citizenid = 'CID7', items = {} }, [8] = { citizenid = 'CID8', items = {} } }
local definitions = {
    bread = { name = 'bread', weight = 1 },
    wood = { name = 'wood', weight = 1 },
    weapon_pistol = { name = 'weapon_pistol', type = 'weapon', unique = true, weight = 1 },
}
local function noop() end
GetCurrentResourceName = function() return 'kora_inventory' end
GetInvokingResource = function() return invokingResource end
GetGameTimer = function() return 1000 end
GetPlayerPed = function(source) return source end
GetEntityCoords = function() return { x = 1, y = 2, z = 3 } end
GetPlayerRoutingBucket = function() return 0 end
CreateThread = function(callback) threads[#threads + 1] = callback end
Wait, RegisterCommand, TriggerClientEvent = noop, noop, noop
AddEventHandler = function(name, callback) events[name] = callback end
RegisterNetEvent = AddEventHandler
local fired = {}
TriggerEvent = function(name, ...)
    fired[#fired + 1] = { name = name, args = table.pack(...) }
    if events[name] then events[name](...) end
end
Kora = {
    util = { deepClone = function(value)
        local seen = {}
        local function clone(v)
            if type(v) ~= 'table' then return v end
            if seen[v] then return seen[v] end
            local copy = {}
            seen[v] = copy
            for k, vv in pairs(v) do copy[clone(k)] = clone(vv) end
            return copy
        end
        return clone(value)
    end, clamp = function(value, min, max) return math.max(min, math.min(max, value)) end },
    resources = { serverRegistry = function() return { track = noop, untrack = noop } end },
    callback = { register = noop },
    distance = { player = function() return true end },
    notify = { send = noop },
    sql = {},
}
exports = setmetatable({}, {
    __call = function(_, name, callback) registered[name] = callback end,
    __index = function(_, resource)
        return setmetatable({}, { __index = function(_, name)
            return function(_, ...)
                if resource == 'kora_core' then
                    local source, field, value = ...
                    if name == 'allShared' then return {} end
                    if name == 'registerPhysicalCash' then return true end
                    if name == 'getShared' then return definitions[field] end
                    if name == 'getPlayerData' then
                        local player = data[source]
                        if not player or not field then return player end
                        if field[1] == 'items' and field[2] then return player.items[field[2]] end
                        return player[field[1]]
                    end
                    if name == 'setPath' then
                        if field[2] then data[source].items[field[2]] = value else data[source].items = value end
                        TriggerEvent('kora_core:server:inventoryChanged', source)
                        return true
                    end
                end
                return registered[name] and registered[name](...)
            end
        end })
    end,
})

dofile('server/audit_log.lua')
dofile('server.lua')
dofile('server/compat/qb.lua')
dofile('server/compat/ox.lua')

local inventory = KoraInventory
local audit = inventory.auditLog

-- Deterministic clock and SQL sink.
local clock = 1000000
audit.clock = function() return clock end
local batches, sinkFails = {}, false
audit.sink = function(rows)
    if sinkFails then return nil, 'database down' end
    batches[#batches + 1] = rows
    return #rows
end
local function reset()
    audit.reset()
    batches, fired, sinkFails = {}, {}, false
    threads = {}
    logSpy.reset()
    clock = 1000000
    Config.kora_inventory.audit.enabled = true
    Config.kora_inventory.audit.persist = true
    Config.kora_inventory.audit.trackRemovals = false
    Config.kora_inventory.audit.anomaly.enabled = true
    Config.kora_inventory.audit.anomaly.perResourceThreshold = 500
    Config.kora_inventory.audit.anomaly.perPlayerThreshold = 200
end
local function anomalies()
    local list = {}
    for _, event in ipairs(fired) do
        if event.name == 'kora_inventory:server:auditAnomaly' then list[#list + 1] = event.args[1] end
    end
    return list
end

-- ---------------------------------------------------------------------------
-- Defaults match the specification.
-- ---------------------------------------------------------------------------
local cfg = Config.kora_inventory.audit
H.equal(cfg.enabled, true, 'audit defaults on')
H.equal(cfg.persist, true, 'audit persists by default')
H.equal(cfg.flushSeconds, 10, 'flush every 10 seconds')
H.equal(cfg.retentionDays, 14, 'retention defaults to 14 days')
H.equal(cfg.trackRemovals, false, 'removals are not tracked by default')
H.equal(cfg.anomaly.windowSeconds, 300, 'anomaly window is 5 minutes')
H.equal(cfg.anomaly.perResourceThreshold, 500, 'per-resource threshold default')
H.equal(cfg.anomaly.perPlayerThreshold, 200, 'per-player threshold default')
H.equal(cfg.ace, 'kora_inventory.audit', 'audit ACE name')

-- ---------------------------------------------------------------------------
-- Invoking resource is captured where the export ENTERS.
-- ---------------------------------------------------------------------------
reset()
invokingResource = 'kora_drugs'
H.ok(registered.addItem(7, 'bread', 3, nil, {}, 'harvest'), 'addItem export succeeds')
invokingResource = nil
H.ok(registered.AddItem(8, 'wood', 2), 'AddItem alias succeeds')
local entries = audit.query({ range = '1h' }).rows
H.equal(#entries, 2, 'both adds are recorded')
local byItem = {}
for _, row in ipairs(entries) do byItem[row.item] = row end
H.equal(byItem.bread.resource, 'kora_drugs', 'the export boundary records the invoking resource')
H.equal(byItem.bread.citizenid, 'CID7', 'citizenid is resolved server-side')
H.equal(byItem.bread.source, 7, 'server id is recorded')
H.equal(byItem.bread.amount, 3, 'amount is recorded')
H.equal(byItem.bread.reason, 'harvest', 'the reason string is kept')
H.equal(byItem.bread.inventory, 'player:7', 'the inventory key is recorded')
H.equal(byItem.bread.action, 'add', 'plain adds use the add action')
H.equal(byItem.wood.resource, 'kora_inventory', 'an unknown caller falls back to the resource itself')

-- The global is only read at the boundary: later changes do not leak in.
reset()
local calls = 0
GetInvokingResource = function() calls = calls + 1; return calls == 1 and 'late_script' or 'someone_else' end
H.ok(registered.addItem(7, 'bread', 1), 'add through the wrapper')
GetInvokingResource = function() return invokingResource end
entries = audit.query({ resource = 'late_script' }).rows
H.equal(#entries, 1, 'a later GetInvokingResource() answer does not change the captured caller')

-- The context is per coroutine and is restored (also after an error).
local co = coroutine.wrap(function()
    audit.withInvoker('other', function() coroutine.yield('inside') end)
    return 'done'
end)
H.equal(co(), 'inside', 'a coroutine can yield inside an export')
H.equal(audit.invoker(), 'kora_inventory', 'another coroutine does not see that caller')
local okErr = pcall(audit.withInvoker, 'broken', function() error('boom') end)
H.equal(okErr, false, 'errors propagate through the wrapper')
H.equal(audit.invoker(), 'kora_inventory', 'the context is restored after an error')
H.equal(audit.withInvoker('a', function() return audit.withInvoker('b', function() return audit.invoker() end) end), 'a',
    'a nested export call keeps the outermost caller')

-- compat providers capture the caller the same way (providers.lua wraps these).
reset()
invokingResource = 'qb_script'
local qb = inventory.compat.qb
local wrappedQb = audit.wrapExport(qb.AddItem)
H.ok(wrappedQb(7, 'bread', 2, nil, nil, 'qb-reason'), 'qb AddItem works through the wrapper')
inventory.api.RegisterStash('audit_stash', 'Stash', 10, 100000)
H.ok(wrappedQb('audit_stash', 'wood', 5, nil, nil, 'fill'), 'a stash add through the qb layer')
invokingResource = nil
entries = audit.query({ resource = 'qb_script' }).rows
H.equal(#entries, 2, 'qb compat adds (player and stash) record the calling resource')
local stashRow
for _, row in ipairs(entries) do if row.item == 'wood' then stashRow = row end end
H.equal(stashRow.inventory, 'stash:audit_stash', 'a stash add names the stash')
H.equal(stashRow.citizenid, nil, 'a script filling a stash has no player')
H.equal(stashRow.reason, 'fill', 'the reason is kept')
local providers = assert(io.open('server/compat/providers.lua', 'r')):read('*a')
H.ok(providers:find('auditLog.wrapExport(fn)', 1, true), 'providers.lua wraps the provider exports')

-- ---------------------------------------------------------------------------
-- Disabled config records nothing and never errors.
-- ---------------------------------------------------------------------------
reset()
Config.kora_inventory.audit.enabled = false
H.ok(registered.addItem(7, 'bread', 1), 'adds still work with the audit disabled')
H.equal(#audit.query({}).rows, 0, 'nothing is recorded when disabled')
H.equal(audit.pending(), 0, 'nothing is queued when disabled')
H.equal(audit.record({ action = 'add', item = 'bread', amount = 1 }), nil, 'record() returns nil when disabled')
Config.kora_inventory.audit.enabled = true
H.equal(audit.record({ action = 'add', item = 'bread', amount = 0 }), nil, 'a zero amount is not recorded')
H.equal(audit.record({ action = 'add', amount = 1 }), nil, 'an entry without an item is not recorded')

-- ---------------------------------------------------------------------------
-- Removals only when trackRemovals is on.
-- ---------------------------------------------------------------------------
reset()
H.ok(registered.addItem(7, 'wood', 5))
H.ok(registered.removeItem(7, 'wood', 2))
H.equal(#audit.query({ range = '1h' }).rows, 1, 'removals are ignored by default')
Config.kora_inventory.audit.trackRemovals = true
H.ok(registered.removeItem(7, 'wood', 1))
local rows = audit.query({ range = '1h' }).rows
H.equal(#rows, 2, 'removals are logged when trackRemovals is on')
H.equal(rows[1].action, 'remove', 'newest first, and the action says remove')

-- ---------------------------------------------------------------------------
-- Batching: nothing waits on SQL; flush on the interval or at 200 rows.
-- ---------------------------------------------------------------------------
reset()
for _ = 1, 5 do audit.record({ action = 'add', item = 'bread', amount = 1, source = 7, citizenid = 'CID7', resource = 'x' }) end
H.equal(#batches, 0, 'recording never writes synchronously')
H.equal(audit.pending(), 5, 'rows wait in the queue')
audit.tick()
H.equal(#batches, 1, 'the first tick flushes')
H.equal(#batches[1], 5, 'one batch carries every queued row')
H.equal(audit.pending(), 0, 'the queue is empty after a flush')
audit.record({ action = 'add', item = 'bread', amount = 1, resource = 'x' })
clock = clock + 5
audit.tick()
H.equal(#batches, 1, 'no flush before flushSeconds has passed')
clock = clock + 5
audit.tick()
H.equal(#batches, 2, 'flush once flushSeconds (10) has passed')

reset()
for _ = 1, 199 do audit.record({ action = 'add', item = 'bread', amount = 1, resource = 'x' }) end
H.equal(#threads, 0, '199 rows do not trigger an early flush')
audit.record({ action = 'add', item = 'bread', amount = 1, resource = 'x' })
H.equal(#threads, 1, 'the 200th row schedules a flush in a thread, not inline')
H.equal(#batches, 0, 'the add itself still did not wait')
threads[1]()
H.equal(#batches, 1, 'the scheduled flush writes the batch')
H.equal(#batches[1], 200, 'the batch is 200 rows')

reset()
for _ = 1, 450 do audit.record({ action = 'add', item = 'bread', amount = 1, resource = 'x' }) end
audit.flush()
H.equal(#batches, 3, '450 queued rows are written as 200 + 200 + 50')
H.equal(#batches[3], 50, 'the last batch holds the remainder')

-- A failing database keeps the rows for the next tick instead of losing them.
reset()
audit.record({ action = 'add', item = 'bread', amount = 1, resource = 'x' })
sinkFails = true
audit.flush()
H.equal(audit.pending(), 1, 'a failed write keeps the row queued')
H.ok(logSpy.find('warn', 'audit.flush_failed'), 'the failure is logged')
sinkFails = false
audit.flush()
H.equal(audit.pending(), 0, 'the retry succeeds')
H.equal(#batches, 1, 'and the row arrives exactly once')

-- persist = false keeps the ring only.
reset()
Config.kora_inventory.audit.persist = false
audit.record({ action = 'add', item = 'bread', amount = 1, resource = 'x' })
H.equal(audit.pending(), 0, 'nothing is queued when persistence is off')
H.equal(#audit.query({}).rows, 1, 'but the in-memory ring still answers')
Config.kora_inventory.audit.persist = true

-- ---------------------------------------------------------------------------
-- Retention cutoff maths and pruning.
-- ---------------------------------------------------------------------------
reset()
H.equal(audit.retentionCutoff(2000000), 2000000 - 14 * 86400, '14 days of retention')
Config.kora_inventory.audit.retentionDays = 1
H.equal(audit.retentionCutoff(2000000), 2000000 - 86400, 'retention follows the config at call time')
Config.kora_inventory.audit.retentionDays = 0
H.equal(audit.retentionCutoff(2000000), 2000000 - 86400, 'retention never drops below one day')
Config.kora_inventory.audit.retentionDays = 14
local pruned
inventory.persistence = {
    auditPrune = function(cutoff) pruned = cutoff; return 3 end,
    getStatus = function() return { ready = false } end,
}
Config.kora_inventory.audit.anomaly.enabled = false
clock = 5000000
audit.record({ action = 'add', item = 'bread', amount = 1, resource = 'old' })
clock = clock + 14 * 86400 + 10
audit.record({ action = 'add', item = 'bread', amount = 1, resource = 'new' })
local cutoff = audit.prune()
H.equal(cutoff, clock - 14 * 86400, 'prune returns the cutoff')
H.equal(pruned, cutoff, 'the table is pruned with the same cutoff')
rows = audit.query({ range = '7d' }).rows
H.equal(#rows, 1, 'entries older than the cutoff leave the ring')
H.equal(rows[1].resource, 'new', 'newer entries stay')
pruned = nil
audit.tick()
H.equal(pruned, nil, 'a second prune within the hour is skipped')
clock = clock + 3601
audit.tick()
H.ok(pruned ~= nil, 'prune runs again after an hour')
inventory.persistence = nil

-- ---------------------------------------------------------------------------
-- Anomaly windows fire once per window per key.
-- ---------------------------------------------------------------------------
reset()
Config.kora_inventory.audit.anomaly.perResourceThreshold = 50
Config.kora_inventory.audit.anomaly.perPlayerThreshold = 100000
local function burst(times, resource)
    for _ = 1, times do
        audit.record({ action = 'add', item = 'bread', amount = 10, resource = resource or 'dupe_script', source = 7, citizenid = 'CID7' })
    end
end
burst(4)
H.equal(#anomalies(), 0, 'below the threshold nothing fires')
burst(1)
local fireds = anomalies()
H.equal(#fireds, 1, 'crossing the per-resource threshold fires the event once')
H.equal(fireds[1].kind, 'resource', 'it is a resource anomaly')
H.equal(fireds[1].resource, 'dupe_script', 'it names the resource')
H.equal(fireds[1].count, 50, 'it carries the count')
H.equal(fireds[1].threshold, 50, 'and the threshold')
H.ok(logSpy.find('warn', 'audit.anomaly'), 'a Kora.logging.warn is written')
burst(5)
H.equal(#anomalies(), 1, 'it does not fire again inside the same window')
clock = clock + 301
burst(1)
H.equal(#anomalies(), 1, 'old amounts roll off the window, so one add is far from the threshold')
burst(4)
H.equal(#anomalies(), 2, 'it fires again in the next window')
burst(5, 'another_script')
fireds = anomalies()
H.equal(#fireds, 3, 'each resource has its own once-per-window gate')
H.equal(fireds[3].resource, 'another_script', 'the third alert is the other resource')

-- Rolling, not bucketed: amounts spread across the window still add up.
reset()
Config.kora_inventory.audit.anomaly.perResourceThreshold = 100
for _ = 1, 10 do
    audit.record({ action = 'add', item = 'wood', amount = 10, resource = 'slow_script' })
    clock = clock + 20 -- 200 s in total, inside the 300 s window
end
H.equal(#anomalies(), 1, 'a slow trickle inside the window still trips the counter')

-- Per-player counter, independent of the resource.
reset()
Config.kora_inventory.audit.anomaly.perResourceThreshold = 100000
Config.kora_inventory.audit.anomaly.perPlayerThreshold = 30
for _ = 1, 3 do audit.record({ action = 'add', item = 'bread', amount = 10, resource = 'shop_a', citizenid = 'CID9', source = 9 }) end
fireds = anomalies()
H.equal(#fireds, 1, 'the per-player threshold fires')
H.equal(fireds[1].kind, 'player', 'as a player anomaly')
H.equal(fireds[1].citizenid, 'CID9', 'naming the citizen')

-- kora_inventory's own adds and omnipack takes never trip the resource counter.
reset()
Config.kora_inventory.audit.anomaly.perResourceThreshold = 5
Config.kora_inventory.audit.anomaly.perPlayerThreshold = 100000
audit.record({ action = 'purchase', item = 'bread', amount = 50, resource = 'kora_inventory', source = 7, citizenid = 'CID7' })
audit.record({ action = 'omnipack', item = 'bread', amount = 50, resource = 'other', source = 7, citizenid = 'CID7' })
H.equal(#anomalies(), 0, "the inventory's own activity and admin omnipack takes are not anomalies")
Config.kora_inventory.audit.anomaly.enabled = false
audit.record({ action = 'add', item = 'bread', amount = 500, resource = 'noisy', source = 7, citizenid = 'CID7' })
H.equal(#anomalies(), 0, 'disabled anomaly detection fires nothing')

-- ---------------------------------------------------------------------------
-- Filters and summary (viewer data).
-- ---------------------------------------------------------------------------
reset()
Config.kora_inventory.audit.anomaly.enabled = false
audit.record({ action = 'add', item = 'bread', amount = 5, resource = 'a', source = 7, citizenid = 'CID7' })
clock = clock + 100
audit.record({ action = 'add', item = 'wood', amount = 50, resource = 'b', source = 8, citizenid = 'CID8' })
clock = clock + 100
audit.record({ action = 'purchase', item = 'bread', amount = 1, resource = 'kora_inventory', source = 8, citizenid = 'CID8' })
local result = audit.query({ range = '1h' })
H.equal(#result.rows, 3, 'all rows in range')
H.equal(result.rows[1].action, 'purchase', 'newest first')
H.equal(#audit.query({ player = 'CID8' }).rows, 2, 'filter by citizenid')
H.equal(#audit.query({ player = '7' }).rows, 1, 'filter by server id')
H.equal(#audit.query({ item = 'bre' }).rows, 2, 'filter by item (contains)')
H.equal(#audit.query({ resource = 'B' }).rows, 1, 'filter by resource (case-insensitive contains)')
H.equal(result.summary.resources[1].name, 'b', 'top resource by amount')
H.equal(result.summary.items[1].name, 'wood', 'top item by amount')
clock = clock + 4000
H.equal(#audit.query({ range = '1h' }).rows, 0, 'the 1h range excludes old rows')
H.equal(#audit.query({ range = '24h' }).rows, 3, 'the 24h range includes them')
H.equal(#audit.query({ range = 'forever' }).rows, 3, 'an unknown range falls back to 24h')
local filter = audit.normaliseFilter({ player = ' CID8 ', item = ' Bread ', evil = 'x', page = -5 })
H.equal(filter.citizenid, 'CID8', 'filters are trimmed')
H.equal(filter.item, 'bread', 'item filters are lower-cased')
H.equal(filter.page, 0, 'pages never go negative')
H.equal(filter.evil, nil, 'unknown fields are dropped')

-- Paging at 100.
reset()
Config.kora_inventory.audit.anomaly.enabled = false
Config.kora_inventory.auditLimit = 1000
for index = 1, 250 do
    audit.record({ action = 'add', item = 'bread', amount = 1, resource = 'p' .. index })
    clock = clock + 1
end
result = audit.query({ range = '1h' })
H.equal(#result.rows, 100, 'a page holds 100 rows')
H.equal(result.hasMore, true, 'there is another page')
H.equal(result.rows[1].resource, 'p250', 'page 0 starts with the newest')
result = audit.query({ range = '1h', page = 2 })
H.equal(#result.rows, 50, 'the last page holds the remainder')
H.equal(result.hasMore, false, 'and says it is the last')
H.equal(result.rows[1].resource, 'p50', 'page 2 continues in order')

-- The ring is bounded by Config.kora_inventory.auditLimit.
reset()
Config.kora_inventory.audit.anomaly.enabled = false
Config.kora_inventory.auditLimit = 100
for index = 1, 130 do audit.record({ action = 'add', item = 'bread', amount = 1, resource = 'r' .. index }) end
H.equal(#audit.query({ range = '1h' }).rows, 100, 'the in-memory ring is capped')
Config.kora_inventory.auditLimit = 1000

-- ---------------------------------------------------------------------------
-- Other creation paths route through the same helper.
-- ---------------------------------------------------------------------------
reset()
Config.kora_inventory.audit.anomaly.enabled = false
local internal = inventory.internal
internal.auditAdd('craft', 7, 'player:7', 'bread', 2, 'recipe_1', 'kora_crafter')
internal.auditAdd('exchange', 7, nil, 'wood', 4, 'dealer:key', 'kora_drugs')
rows = audit.query({}).rows
H.equal(#rows, 2, 'craft and exchange entries are recorded')
H.equal(rows[2].action, 'craft', 'the craft action is kept')
H.equal(rows[2].resource, 'kora_crafter', 'the crafting caller is the resource')
H.equal(rows[1].resource, 'kora_drugs', 'the exchange provider is the resource')
H.equal(rows[1].inventory, 'player:7', 'exchange entries default to the recipient inventory')

-- Public SetInventory records only what it ADDED.
reset()
Config.kora_inventory.audit.anomaly.enabled = false
data[7].items = { [1] = internal.buildItem('bread', 2, 1, {}) }
invokingResource = 'set_script'
H.ok(registered.SetInventory(7, { [1] = internal.buildItem('bread', 5, 1, {}), [2] = internal.buildItem('wood', 1, 2, {}) }))
invokingResource = nil
rows = audit.query({}).rows
local added = {}
for _, row in ipairs(rows) do
    added[row.item] = row.amount
    H.equal(row.action, 'set', 'set diffs use the set action')
    H.equal(row.resource, 'set_script', 'set diffs name the caller')
end
H.equal(added.bread, 3, 'SetInventory records the increase, not the total')
H.equal(added.wood, 1, 'and brand new items')

-- The creation paths are wired through the one helper.
local server = assert(io.open('server.lua', 'r')):read('*a')
for _, needle in ipairs({
    "ext.auditAdd('add', src, playerKey(src), name, amount, reason)",
    "ext.auditAdd('purchase', src, playerKey(src), currentItem.name",
    "ext.auditAdd('purchase', src, playerKey(src), item.name",
    "ext.auditAdd('omnipack', src",
}) do
    H.ok(server:find(needle, 1, true), 'creation path wired: ' .. needle)
end
H.ok(server:find('auditedExports[name] and captureInvoker(fn)', 1, true), 'exports capture the invoker at the boundary')
local manifest = assert(io.open('fxmanifest.lua', 'r')):read('*a')
H.ok(manifest:find("'server/audit_log.lua',\n    'server.lua'", 1, true), 'audit_log.lua loads before server.lua')
local schema = assert(io.open('server/schema.lua', 'r')):read('*a')
H.ok(schema:find("name = 'resource'", 1, true) and schema:find("name = 'item'", 1, true), 'the audit table has item-creation columns')

-- ---------------------------------------------------------------------------
-- SQL layer (server/persistence.lua): one multi-row INSERT per batch, parameters
-- only, newest-first paging, and the retention DELETE. No database needed.
-- ---------------------------------------------------------------------------
local statements = {}
Kora.sql = {
    NULL = {},
    NOW = nil,
    ready = function() return true end,
    ensureTables = function(schema)
        statements.schema = schema
        return {}
    end,
    execute = function(sql, params) statements[#statements + 1] = { sql = sql, params = params }; return 1 end,
    query = function(sql, params)
        statements[#statements + 1] = { sql = sql, params = params }
        return { { at = 1, action = 'add', item = 'bread', amount = 1, inventory_type = 'player', inventory_id = '7' } }
    end,
}
json = json or { encode = function(value)
    local parts = {}
    for key, entry in pairs(value) do parts[#parts + 1] = ('%q:%q'):format(tostring(key), tostring(entry)) end
    table.sort(parts)
    return '{' .. table.concat(parts, ',') .. '}'
end, decode = function() return {} end }
local schemaThreads = {}
CreateThread = function(callback) schemaThreads[#schemaThreads + 1] = callback end
dofile('server/schema.lua')
dofile('server/persistence.lua')
for _, thread in ipairs(schemaThreads) do
    -- Only the one-shot bootstrap; the periodic flusher loops forever.
    if thread == schemaThreads[1] then thread() end
end
local persistence = inventory.persistence
H.ok(persistence.getStatus().ready, 'the persistence layer is ready for the SQL checks')

local columns = {}
for _, tableDef in ipairs(KoraInventorySchema) do
    if tableDef.name == 'kora_inventory_audit' then
        for _, column in ipairs(tableDef.columns) do columns[column.name] = true end
    end
end
for _, name in ipairs({ 'created_at', 'citizenid', 'source', 'item', 'amount', 'resource', 'reason', 'action' }) do
    H.ok(columns[name], 'kora_inventory_audit has the ' .. name .. ' column')
end

statements = {}
local written = persistence.auditInsertBatch({
    { at = 100, action = 'add', citizenid = 'CID7', source = 7, item = 'bread', amount = 3, inventory = 'player:7', resource = 'kora_drugs', reason = "x'; DROP TABLE y;--" },
    { at = 101, action = 'purchase', item = 'wood', amount = 1, inventory = 'stash:s1', resource = 'kora_inventory' },
})
H.equal(written, 1, 'the batch is one statement')
H.equal(#statements, 1, 'two rows are written with a single INSERT')
H.ok(statements[1].sql:find('INSERT INTO `kora_inventory_audit`', 1, true), 'it inserts into the audit table')
H.equal(select(2, statements[1].sql:gsub('%(FROM_UNIXTIME%(%?%)', '')), 2, 'one value group per row')
H.ok(not statements[1].sql:find('DROP TABLE', 1, true), 'values are parameters, never part of the statement')
H.equal(#statements[1].params, 24, 'twelve parameters per row')
H.equal(statements[1].params[1], 100, 'the original timestamp is kept')
H.equal(statements[1].params[3], 'add', 'the action is bound')
H.equal(statements[1].params[4], 'player', 'the inventory type is split from the key')
H.equal(statements[1].params[5], '7', 'and the inventory id')
H.equal(statements[1].params[11], 'kora_drugs', 'the resource is bound')
H.equal(statements[1].params[12], "x'; DROP TABLE y;--", 'the reason is a bound parameter')

statements = {}
persistence.auditPrune(12345)
H.ok(statements[1].sql:find('DELETE FROM `kora_inventory_audit` WHERE `created_at` < FROM_UNIXTIME(?)', 1, true), 'prune deletes by the cutoff')
H.equal(statements[1].params[1], 12345, 'the cutoff is bound')

statements = {}
local queried, more = persistence.auditQuery({ since = 50, citizenid = 'CID7', source = 7, item = '50%_off', resource = 'kora' }, 100, 200)
H.equal(#queried, 1, 'rows come back')
H.equal(more, false, 'a short page has no next page')
H.equal(queried[1].inventory, 'player:7', 'the inventory key is rebuilt')
local sql = statements[1].sql
H.ok(sql:find('ORDER BY `created_at` DESC,`id` DESC LIMIT ? OFFSET ?', 1, true), 'newest first with a limit and offset')
H.ok(sql:find('`citizenid` = ?', 1, true) and sql:find('`source` = ?', 1, true), 'player filters are bound')
H.equal(statements[1].params[#statements[1].params - 1], 101, 'one extra row is fetched to know whether there is another page')
H.equal(statements[1].params[#statements[1].params], 200, 'the offset is bound')
local likes = {}
for _, value in ipairs(statements[1].params) do if type(value) == 'string' and value:find('^%%') then likes[#likes + 1] = value end end
H.equal(likes[1], '%50\\%\\_off%', 'LIKE wildcards in a filter are escaped')

statements = {}
local summary = persistence.auditSummary(10, 5)
H.equal(#statements, 2, 'the summary asks for resources and items')
H.ok(statements[1].sql:find('GROUP BY `resource`', 1, true) and statements[2].sql:find('GROUP BY `item`', 1, true), 'grouped by resource and by item')
H.ok(summary.resources and summary.items, 'both lists are returned')
H.equal(persistence.audit ~= nil, true, 'the original generic audit writer is untouched')

H.finish()
