-- Actual authority, persistence and kora_sql Lua adapter with controlled durable
-- callbacks. Exercise the fixed SQL command across hydration/save boundaries.
local H = dofile('test/harness.lua')
dofile('../kora_core/test/mocks.lua').install()

local function record(amount)
    return { inventory_type = 'stash', inventory_id = 'policetrash', label = 'Trash', slots = 10,
        max_weight = 100000, revision = 2,
        items = json.encode({ [1] = { name = 'water_bottle', amount = amount, slot = 1, info = {} } }), properties = '{}' }
end

local function setup(initial, boot)
    local f = { threads = {}, handlers = {}, exports = {}, rows = {}, calls = {}, time = 0, replies = {} }
    if initial then f.rows['stash:policetrash'] = record(initial) end
    local env = {}; for k, v in pairs(_G) do env[k] = v end
    env.Config, env.QbInventory = {}, nil
    env.Kora = { resources = { serverRegistry = function() return { track = function() end, untrack = function() end } end }, callback = { register = function() end } }
    env.GetCurrentResourceName = function() return 'kora_inventory' end
    env.GetInvokingResource = function() return f.invoker or 'kora_sql' end
    env.GetGameTimer = function() return f.time end
    env.Wait = function() coroutine.yield('wait') end
    env.CreateThread = function(fn) f.threads[#f.threads + 1] = coroutine.create(fn) end
    env.RegisterCommand, env.RegisterNetEvent, env.TriggerClientEvent, env.print = function() end, function() end, function() end, function() end
    env.AddEventHandler = function(name, fn)
        f.handlers[name] = f.handlers[name] or {}; table.insert(f.handlers[name], fn)
    end
    env.TriggerEvent = function(name, ...)
        for _, fn in ipairs(f.handlers[name] or {}) do fn(...) end
    end
    env.LoadResourceFile = function(_, path)
        local file = assert(io.open(path)); local value = file:read('*a'); file:close(); return value
    end
    env.promise = { new = function() return {
        resolve = function(p, value) p.done, p.value = true, value end,
        reject = function(p, err) p.done, p.err = true, err end,
    } end }
    env.Citizen = { Await = function(p)
        if not p.done then coroutine.yield('sql') end
        assert(p.done, 'SQL callback must settle before resume')
        if p.err then error(p.err, 0) end
        return p.value
    end }
    local function copy(value) return env.QbInventory.copy(value) end
    local function submit(kind, work, callback)
        f.calls[#f.calls + 1] = kind
        local request = { kind = kind, work = work, callback = callback }
        if f.throw == kind then f.throw = nil; work(); error('controlled export failure')
        elseif f.hold == kind then f.hold, f.pending = nil, request
        elseif f.fail == kind then f.fail = nil; callback(nil, 'controlled SQL failure')
        else callback(work()) end
    end
    local driver = { isReady = function() return true end, ensureTables = function(_, _, _, cb) cb({ { warnings = {} } }) end }
    function driver.query(_, sql, params, cb)
        local kind = sql:find('ORDER BY `updated_at`', 1, true) and 'restore'
            or sql:find('WHERE `inventory_type` = ?', 1, true) and 'load'
            or sql:find('WHERE `source_name` = ?', 1, true) and 'marker' or 'query'
        submit(kind, function()
            if kind == 'restore' then local out = {}; for _, row in pairs(f.rows) do out[#out + 1] = copy(row) end; return out end
            if kind == 'load' then local row = f.rows[params[1] .. ':' .. params[2]]; return row and { copy(row) } or {} end
            if kind == 'marker' then return f.tombstone and { { status = 'deleted', source_checksum = '' } } or {} end
            if sql:find('INFORMATION_SCHEMA', 1, true) then return { { COLUMN_NAME = 'identifier' }, { COLUMN_NAME = 'items' } } end
            if sql:find('FROM `inventories`', 1, true) or sql:find('FROM `stashitems`', 1, true) then return { { legacy_id = 'policetrash', legacy_items = record(9).items } } end
            return {}
        end, cb)
    end
    function driver.execute(_, sql, params, cb)
        local kind = sql:find('INSERT INTO `kora_inventory_inventories`', 1, true) and 'save' or 'execute'
        submit(kind, function()
            if kind == 'save' then f.rows[params[1] .. ':' .. params[2]] = {
                inventory_type = params[1], inventory_id = params[2], label = params[3], slots = params[4],
                max_weight = params[5], revision = params[6], items = params[7], properties = params[8],
            } end
            return { affectedRows = 1 }
        end, cb)
    end
    function driver.scalar(_, sql, params, cb)
        cb = cb or params
        assert(sql:find('UUID()', 1, true))
        f.sequence = (f.sequence or 0) + 1
        cb(('%032x'):format(f.sequence))
    end
    function driver.transactionChecked(_, statements, cb)
        if statements[1].query:find('FOR UPDATE', 1, true) then
            submit('reconcile', function()
                return { success = true, results = { f.receipt and { { source_checksum = f.receipt } } or {} } }
            end, cb)
            return
        end
        H.ok(statements[1].query:find('kora_inventory_migration_rows', 1, true), 'delete transaction records durable import tombstone')
        H.ok(statements[2].query:find('kora_inventory_inventories', 1, true), 'delete transaction targets canonical table')
        local ambiguous = f.ambiguous
        f.ambiguous = nil
        submit('delete', function()
            if ambiguous == 'rollback' then return { success = false, code = 'indeterminate', message = 'commit acknowledgement lost' } end
            f.tombstone = true
            local affected = f.rows['stash:policetrash'] and 1 or 0
            f.rows['stash:policetrash'] = nil
            f.receipt = statements[3].values[1] .. ':' .. affected
            if ambiguous == 'commit' then return { success = false, code = 'indeterminate', message = 'commit acknowledgement lost' } end
            return { success = true, results = { { affectedRows = 1 }, { affectedRows = affected } } }
        end, cb)
    end
    env.exports = setmetatable({ kora_sql = driver, kora_core = {
        getShared = function(_, _, name) return { name = name, label = name, weight = 1 } end,
        allShared = function() return {} end,
    } }, { __call = function(_, name, fn) f.exports[name] = fn end })
    local function load(path) assert(loadfile(path, 't', env))() end
    load('config.lua'); load('shared.lua'); load('../kora_sql/init.lua'); load('server/schema.lua'); load('server/persistence.lua'); load('server.lua')
    f.env, f.persistence, f.internal = env, env.QbInventory.persistence, env.QbInventory.internal
    function f.resume(thread)
        local ok, value, err = coroutine.resume(thread); assert(ok, value); return value, err
    end
    function f.complete(thread)
        local request = assert(f.pending); f.pending = nil
        request.callback(request.work()); return f.resume(thread)
    end
    function f.bridge()
        local before = #f.threads
        f.exports.deleteLegacyPoliceTrash(function(rows, err) f.replies[#f.replies + 1] = { rows = rows, error = err } end)
        if #f.threads == before then return end
        local thread = f.threads[#f.threads]; f.resume(thread); return thread
    end
    if boot ~= false then f.resume(f.threads[1]) end
    return f
end

-- Loaded, unloaded and absent durable records report actual affectedRows.
for _, mode in ipairs({ 'loaded', 'unloaded', 'absent' }) do
    local f = setup(mode == 'loaded' and 4 or nil)
    if mode == 'unloaded' then f.rows['stash:policetrash'] = record(4) end
    H.equal(f.exports.getPersistenceStatus().ready, true, 'schema and hydration are complete')
    f.bridge()
    H.equal(#f.replies, 1, 'SQL callback settles once')
    H.equal(f.replies[1].rows, mode == 'absent' and 0 or 1, 'real durable row count for ' .. mode)
    H.equal(f.internal.getInventory('stash:policetrash'), nil, 'cache evicted for ' .. mode)
    H.equal(f.rows['stash:policetrash'], nil, 'durable record deleted for ' .. mode)
    H.equal(f.persistence.flush(), true, 'subsequent flush succeeds')
    H.equal(f.rows['stash:policetrash'], nil, 'flush cannot resurrect ' .. mode)
end

-- A queued dirty snapshot is discarded, and mutations while SQL is pending fail.
do
    local f = setup(4)
    H.equal(f.exports.stashSet('policetrash', { [1] = { name = 'water_bottle', amount = 8, info = {} } }), true)
    f.hold = 'delete'; local thread = f.bridge()
    H.equal(#f.replies, 0, 'pending commit does not report success')
    H.equal(f.exports.stashSet('policetrash', {}), false, 'mutation lock rejects concurrent item changes')
    f.exports.RegisterStash('policetrash', 'Trash', 10, 100000)
    H.equal(f.internal.removeSecondary('stash:policetrash'), false, 'native remove cannot race bridged delete')
    f.complete(thread)
    H.equal(f.replies[1].rows, 1)
    f.persistence.flush()
    H.equal(f.rows['stash:policetrash'], nil, 'dirty registration snapshot cannot resurrect deleted items')
end

-- An in-flight save must finish before the delete, even when its write is delayed.
do
    local f = setup(4)
    f.exports.stashSet('policetrash', { [1] = { name = 'water_bottle', amount = 8, info = {} } })
    f.hold = 'save'; local flush = coroutine.create(f.persistence.flush); f.resume(flush)
    local saveRequest = f.pending
    local deletion = f.bridge()
    H.equal(#f.replies, 0, 'delete waits for earlier save')
    H.equal(f.pending, saveRequest, 'delete has not reached SQL before save drains')
    f.complete(flush); f.resume(deletion)
    H.equal(f.replies[1].rows, 1)
    f.persistence.flush()
    H.equal(f.rows['stash:policetrash'], nil, 'late save cannot recreate trash after deletion')
end

-- A restore already in flight finishes before deletion sees the cache.
do
    local f = setup(4, false)
    f.hold = 'load'; f.resume(f.threads[1])
    H.equal(f.exports.getPersistenceStatus().schemaReady, true)
    H.equal(f.exports.getPersistenceStatus().ready, false, 'schema event is insufficient')
    local deletion = f.bridge()
    H.equal(#f.replies, 0, 'delete waits for hydration')
    f.complete(f.threads[1]); f.resume(deletion)
    H.equal(f.replies[1].rows, 1)
    H.equal(f.internal.getInventory('stash:policetrash'), nil, 'restore cannot install old record after deletion')
end

-- A lazy runtime SELECT begun before deletion cannot install its stale result.
for _, finishDuringDelete in ipairs({ false, true }) do
    local f = setup()
    f.rows['stash:policetrash'] = record(4)
    f.hold = 'load'
    local loading = coroutine.create(function() return f.internal.createSecondary('stash', 'policetrash') end)
    f.resume(loading)
    local loadRequest = f.pending
    loadRequest.work = function() return { record(4) } end -- SELECT already captured its old row
    if finishDuringDelete then f.hold = 'delete' end
    local deletion = f.bridge()
    local deleteRequest = f.pending
    f.pending = loadRequest; f.complete(loading)
    if finishDuringDelete then f.pending = deleteRequest; f.complete(deletion) end
    f.persistence.flush()
    local current = f.internal.getInventory('stash:policetrash')
    H.ok(not current or next(current.items) == nil, 'lazy hydration cannot restore deleted items')
    local stored = f.rows['stash:policetrash']
    H.ok(not stored or next(json.decode(stored.items)) == nil, 'reopened fresh stash cannot contain stale items')
    H.equal(f.replies[1].rows, 1)
end

-- Failure leaves cache and queued data intact; retry can perform the real delete.
do
    local f = setup(4)
    f.fail = 'delete'; f.bridge()
    H.equal(f.replies[1].rows, nil)
    H.equal(f.replies[1].error, 'controlled SQL failure')
    H.equal(f.internal.getInventory('stash:policetrash').items[1].amount, 4)
    H.equal(f.internal.getInventory('stash:policetrash').blocked, false, 'failure restores access state')
    H.equal(f.tombstone, nil, 'failed transaction does not record tombstone')
    f.bridge(); H.equal(f.replies[2].rows, 1)
end

-- Lost COMMIT replies keep all writers fenced until this exact receipt is read.
for _, outcome in ipairs({ 'commit', 'rollback' }) do
    local f = setup(4)
    f.bridge() -- an older successful receipt must never prove a later commit
    f.rows['stash:policetrash'] = record(6)
    f.internal.createSecondary('stash', 'policetrash')
    f.exports.stashSet('policetrash', { [1] = { name = 'water_bottle', amount = 8, info = {} } })
    f.ambiguous, f.hold = outcome, 'reconcile'
    local deletion = f.bridge()
    H.equal(#f.replies, 1, 'unknown commit has no premature response')
    H.equal(f.exports.stashSet('policetrash', {}), false, 'unknown commit retains mutation fence')
    H.equal(f.persistence.flush(), false, 'unknown commit retains persistence fence')
    H.equal(f.internal.removeSecondary('stash:policetrash'), false, 'unknown commit blocks native removal')
    f.complete(deletion)
    if outcome == 'commit' then
        H.equal(f.replies[2].rows, 1, 'receipt recovers actual affected rows')
        H.equal(f.internal.getInventory('stash:policetrash'), nil)
        H.equal(f.persistence.flush(), true)
        H.equal(f.rows['stash:policetrash'], nil, 'uncertain committed deletion never resurrects')
    else
        H.equal(f.replies[2].rows, nil, 'older receipt is not current success')
        H.equal(f.replies[2].error, 'commit acknowledgement lost')
        H.equal(f.internal.getInventory('stash:policetrash').items[1].amount, 8)
        H.equal(f.persistence.flush(), true, 'confirmed rollback releases dirty snapshots')
        H.equal(json.decode(f.rows['stash:policetrash'].items)[1].amount, 8)
    end
end

-- Unavailable reconciliation must keep retrying with the same locks and receipt.
do
    local f = setup(4)
    f.ambiguous, f.fail = 'commit', 'reconcile'
    local deletion = f.bridge()
    H.equal(#f.replies, 0)
    H.equal(f.exports.stashSet('policetrash', {}), false)
    f.resume(deletion)
    H.equal(f.replies[1].rows, 1)
    H.equal(f.rows['stash:policetrash'], nil)
end

-- Export exceptions after submission are also unknown, not proof of rollback.
do
    local f = setup(4)
    f.throw, f.hold = 'delete', 'reconcile'
    local deletion = f.bridge()
    H.equal(#f.replies, 0)
    H.equal(f.exports.stashSet('policetrash', {}), false)
    f.complete(deletion)
    H.equal(f.replies[1].rows, 1)
    H.equal(f.rows['stash:policetrash'], nil)
end

do
    local f = setup(4)
    f.ambiguous, f.throw = 'commit', 'reconcile'
    local deletion = f.bridge()
    H.equal(#f.replies, 0)
    H.equal(f.exports.stashSet('policetrash', {}), false)
    f.resume(deletion)
    H.equal(f.replies[1].rows, 1)
end

-- Tombstones survive a resource restart and defeat both normal and forced imports.
do
    local f = setup(4); f.bridge()
    local restarted = setup(); restarted.tombstone = f.tombstone
    for _, retry in ipairs({ false, true }) do
        local report = assert(restarted.persistence.migrateLegacy({ sources = { 'inventories', 'stashitems' }, retry = retry }))
        H.equal(report.imported, 0)
        H.equal(report.skipped, 2)
        H.equal(restarted.rows['stash:policetrash'], nil, 'archive cannot resurrect deleted trash on retry')
    end
end

-- A migration that read before deletion holds its key lock until its save ends.
do
    local f = setup()
    f.hold = 'marker'
    local migration = coroutine.create(function() return f.persistence.migrateLegacy({ sources = { 'inventories' } }) end)
    f.resume(migration)
    local deletion = f.bridge()
    H.equal(#f.replies, 0, 'delete waits for pending import decision')
    f.complete(migration); f.resume(deletion)
    H.equal(f.replies[1].rows, 1, 'delete counts the row imported before it')
    H.equal(f.rows['stash:policetrash'], nil, 'completed migration cannot resurrect trash')
end

-- Readiness failure, disabled durability, unauthorized calls and deadline expiry fail explicitly.
do
    local f = setup(nil, false); f.fail = 'restore'; f.resume(f.threads[1])
    H.equal(f.exports.getPersistenceStatus().lastError, 'controlled SQL failure')
    f.bridge(); H.equal(f.replies[1].error, 'controlled SQL failure')
    local disabled = setup(); disabled.env.Config.qbinventory.persistence.enabled = false
    disabled.bridge(); H.equal(disabled.replies[1].error, 'inventory persistence is disabled')
    local unauthorised = setup(); unauthorised.invoker = 'other_resource'; unauthorised.bridge()
    H.equal(unauthorised.replies[1].rows, nil)
    H.ok(unauthorised.replies[1].error:find('restricted', 1, true))
    local timeout = setup(nil, false); local pending = timeout.bridge(); timeout.time = 60001; timeout.resume(pending)
    H.equal(timeout.replies[1].rows, nil)
    H.ok(timeout.replies[1].error:find('timed out', 1, true))
    H.equal(timeout.tombstone, nil, 'pre-operation timeout performs no deletion')
end
H.finish()
