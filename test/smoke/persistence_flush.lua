-- Run from qbinventory: lua5.4 test/smoke/persistence_flush.lua [persistence-source]
-- Uses actual persistence/shared code and the qbsql consumer adapter. Driver
-- callbacks and the FiveM host are controlled; no database or service runs.
local H = dofile('test/harness.lua')
dofile('../qbcore/test/mocks.lua').install() -- existing deterministic JSON codec

local function setup()
    local f = { calls = {}, threads = {} }
    local env = {}
    for key, value in pairs(_G) do env[key] = value end
    env.Config, env.QbInventory, env.QB = {}, nil, {}
    env.GetCurrentResourceName = function() return 'qbinventory' end
    env.CreateThread = function(fn) f.threads[#f.threads + 1] = fn end
    env.RegisterCommand, env.AddEventHandler, env.TriggerEvent = function() end, function() end, function() end
    env.print = function() end
    env.LoadResourceFile = function(_, path)
        local file = assert(io.open(path, 'r'))
        local source = file:read('*a'); file:close()
        return source
    end
    local driver = {}
    function driver.isReady() return true end
    function driver.migrate(_, _, _, callback) callback(true) end
    local function submit(request, callback)
        request.callback = callback
        f.calls[#f.calls + 1] = request
        if f.hold == request.kind then
            f.hold, f.pending = nil, request
        elseif f.fail == request.kind then
            f.fail = nil
            callback(nil, 'controlled SQL failure')
        else
            callback({ affectedRows = 1 })
        end
    end
    function driver.execute(_, statement, params, callback)
        submit({ kind = 'execute', statement = statement, params = env.QbInventory.copy(params) }, callback)
    end
    function driver.upsert(_, tableName, key, rows, opts, callback)
        if type(opts) == 'function' then callback = opts end
        submit({ kind = 'upsert', tableName = tableName, rows = env.QbInventory.copy(rows) }, callback)
    end
    env.exports = { qbsql = driver }
    env.promise = { new = function()
        return {
            resolve = function(p, value) p.settled, p.value = true, value end,
            reject = function(p, err) p.settled, p.err = true, err end,
        }
    end }
    env.Citizen = { Await = function(p)
        if not p.settled then coroutine.yield('SQL wait') end
        assert(p.settled, 'Resolve the driver callback before resuming')
        if p.err then error(p.err, 0) end
        return p.value
    end }
    local function load(path) assert(loadfile(path, 't', env))() end
    load('config.lua'); load('shared.lua'); load('../qbsql/init.lua')
    load(arg[1] or 'server/persistence.lua')
    -- Run only real bootstrap, leaving the permanent periodic flusher dormant.
    assert(f.threads[1])()
    f.env, f.persistence = env, env.QbInventory.persistence
    H.equal(f.persistence.getStatus().ready, true, 'actual bootstrap enables persistence')
    function f.start()
        local thread = coroutine.create(f.persistence.flush)
        local ok, err = coroutine.resume(thread)
        assert(ok, err)
        assert(coroutine.status(thread) == 'suspended', 'Expected a real consumer SQL wait')
        return thread
    end
    function f.complete(thread, value, err)
        assert(f.pending).callback(value, err)
        f.pending = nil
        local ok, result, failures = coroutine.resume(thread)
        assert(ok, result)
        assert(coroutine.status(thread) == 'dead', 'Flush should complete')
        return result, failures
    end
    return f
end

local function record(kind, id, revision, amount)
    local value = {
        type = kind, id = id, label = id, slots = 10, maxWeight = 100000,
        revision = revision, items = { [1] = { name = 'water_bottle', amount = amount, info = { serial = id } } },
    }
    if kind == 'shop' then value.stock = value.items end
    return value
end

local function assertWrite(request, id, revision, amount)
    H.equal(request.kind, 'execute', 'save writes the inventory header')
    H.equal(request.params[2], id, 'saved inventory id')
    H.equal(request.params[6], revision, 'saved snapshot revision')
    H.equal(json.decode(request.params[7])[1].amount, amount, 'saved snapshot quantity')
end

-- A completed save with no replacement is cleared; failed saves remain queued.
do
    local f = setup()
    assert(f.persistence.markDirty(record('stash', 'plain', 1, 4)))
    H.equal(f.persistence.flush(), true, 'ordinary save succeeds')
    assertWrite(f.calls[1], 'plain', 1, 4)
    H.equal(f.persistence.flush(), true, 'nothing remains queued')
    H.equal(#f.calls, 1, 'already saved snapshot is not written twice')
    assert(f.persistence.markDirty(record('stash', 'failed', 2, 3)))
    f.fail = 'execute'
    local ok, failures = f.persistence.flush()
    H.equal(ok, false, 'driver rejection returns failed flush')
    H.equal(failures[1].key, 'stash:failed', 'failed key is reported')
    H.equal(failures[1].error, 'controlled SQL failure', 'actual adapter returns error string')
    H.equal(f.persistence.flush(), true, 'failed snapshot can be retried')
    assertWrite(f.calls[3], 'failed', 2, 3)
end

-- Both successful and failed old saves must leave the latest replacement queued.
for _, succeeds in ipairs({ true, false }) do
    local f = setup()
    local live = record('stash', 'updated', 1, 5)
    assert(f.persistence.markDirty(live))
    f.hold = 'execute'
    local thread = f.start()
    live.revision, live.items[1].amount = 2, 4
    assert(f.persistence.markDirty(live))
    live.revision, live.items[1].amount = 3, 2
    assert(f.persistence.markDirty(live))
    local ok, failures
    if succeeds then ok, failures = f.complete(thread, { affectedRows = 1 })
    else ok, failures = f.complete(thread, nil, 'controlled SQL failure') end
    H.equal(ok, succeeds, 'replacement does not alter the old save result')
    H.equal(#failures, succeeds and 0 or 1, 'flush keeps its existing failure-list contract')
    assertWrite(f.calls[1], 'updated', 1, 5)
    H.equal(f.persistence.flush(), true, 'latest snapshot flush succeeds')
    H.equal(#f.calls, 2, 'latest update queued during SQL is written next')
    assertWrite(f.calls[2], 'updated', 3, 2)
    H.equal(f.persistence.flush(), true, 'latest successful snapshot is cleared')
    H.equal(#f.calls, 2, 'intermediate snapshots remain coalesced')
end

-- A shop's save has two yielding writes: header followed by stock upsert.
for _, succeeds in ipairs({ true, false }) do
    local f = setup()
    local live = record('shop', 'shop', 1, 5)
    assert(f.persistence.markDirty(live))
    f.hold = 'upsert'
    local thread = f.start()
    H.equal(#f.calls, 2, 'paused at the second shop write')
    live.revision, live.items[1].amount = 2, 3
    assert(f.persistence.markDirty(live))
    local ok
    if succeeds then ok = f.complete(thread, { affectedRows = 1 })
    else ok = f.complete(thread, nil, 'controlled SQL failure') end
    H.equal(ok, succeeds, 'shop stock completion keeps normal success/failure result')
    assertWrite(f.calls[1], 'shop', 1, 5)
    H.equal(json.decode(f.calls[2].rows[1].cols.item).amount, 5, 'old stock belongs to the captured snapshot')
    H.equal(f.persistence.flush(), true, 'new shop snapshot remains queued')
    H.equal(#f.calls, 4, 'new shop snapshot writes header and stock')
    assertWrite(f.calls[3], 'shop', 2, 3)
    H.equal(json.decode(f.calls[4].rows[1].cols.item).amount, 3, 'new stock reaches its second write')
    H.equal(f.persistence.flush(), true, 'completed latest shop snapshot is cleared')
    H.equal(#f.calls, 4, 'completed shop is not saved again')
end

-- Each dirty key is independent regardless of pairs() traversal order.
do
    local f = setup()
    local records = { a = record('stash', 'a', 1, 4), b = record('stash', 'b', 1, 4) }
    for _, value in pairs(records) do assert(f.persistence.markDirty(value)) end
    f.hold = 'execute'
    local thread = f.start()
    local heldId = f.pending.params[2]
    local latest = records[heldId]
    latest.revision, latest.items[1].amount = 2, 2
    assert(f.persistence.markDirty(latest))
    H.equal(f.complete(thread, { affectedRows = 1 }), true, 'both captured dirty keys finish')
    H.equal(#f.calls, 2, 'first pass writes each captured key')
    H.equal(f.persistence.flush(), true, 'replacement can flush independently')
    H.equal(#f.calls, 3, 'only the replaced key needs another save')
    assertWrite(f.calls[3], heldId, 2, 2)
end

-- Multiple public flush calls can wait on the same old snapshot. Neither
-- completion may consume a replacement queued after both started.
do
    local f = setup()
    local live = record('stash', 'overlap', 1, 5)
    assert(f.persistence.markDirty(live))
    f.hold = 'execute'
    local first = f.start()
    local firstRequest = f.pending
    f.hold = 'execute'
    local second = f.start()
    local secondRequest = f.pending
    live.revision, live.items[1].amount = 2, 3
    assert(f.persistence.markDirty(live))
    f.pending = secondRequest
    H.equal(f.complete(second, { affectedRows = 1 }), true, 'second captured snapshot finishes normally')
    f.pending = firstRequest
    H.equal(f.complete(first, { affectedRows = 1 }), true, 'first captured snapshot finishes normally')
    H.equal(f.persistence.flush(), true, 'replacement survives both overlapping old completions')
    H.equal(#f.calls, 3, 'replacement still gets its own save')
    assertWrite(f.calls[3], 'overlap', 2, 3)
end
-- Opt-in persisted drops must retain their bucket after save/load.
do
    local f = setup()
    f.env.Config.qbinventory.persistence.persistDrops = true
    f.env.Config.qbinventory.persistence.persistTemporary = true
    local drop = record('drop', 'scoped', 1, 4)
    drop.bucket, drop.temporary = 11, true
    H.equal(f.persistence.markDirty(drop), true, 'scoped drop is queued under existing opt-in durability')
    H.equal(f.persistence.flush(), true, 'scoped drop save succeeds')
    local params = f.calls[1].params
    H.equal(json.decode(params[8]).bucket, 11, 'bucket is stored in existing properties JSON')
    local row = { inventory_type = 'drop', inventory_id = 'scoped', label = 'Drop',
        slots = 10, max_weight = 100000, revision = 1, items = params[7], properties = params[8] }
    f.env.exports.qbsql.query = function(_, statement, args, callback) callback({ row }) end
    local restored = assert(f.persistence.load('drop', 'scoped'))
    H.equal(restored.bucket, 11, 'bucket survives actual persistence loading')
    row.properties = '{}'
    restored = assert(f.persistence.load('drop', 'scoped'))
    H.equal(restored.bucket, nil, 'historical unscoped records retain their behavior')
end
-- A successful delete clears only its captured snapshot; failures keep it queued.
do
    local f = setup()
    assert(f.persistence.markDirty(record('stash', 'deleted', 1, 4)))
    H.equal(f.persistence.delete('stash', 'deleted'), true, 'ordinary delete succeeds')
    H.equal(f.persistence.flush(), true, 'deleted snapshot is no longer queued')
    H.equal(#f.calls, 1, 'ordinary deletion is not followed by an obsolete save')
    assert(f.persistence.markDirty(record('stash', 'failed-delete', 2, 3)))
    f.fail = 'execute'
    local ok, err = f.persistence.delete('stash', 'failed-delete')
    H.equal(ok, nil, 'delete preserves the actual SQL nil-error contract')
    H.equal(err, 'controlled SQL failure', 'delete forwards the SQL error')
    H.equal(f.persistence.flush(), true, 'failed deletion leaves its snapshot available')
    assertWrite(f.calls[3], 'failed-delete', 2, 3)
end

-- A trusted same-key recreation can occur after SQL deletes the old row but
-- before its callback resumes RemoveInventory. Test both queued and saved originals.
for _, savedFirst in ipairs({ false, true }) do
    local f = setup()
    local env, registered = f.env, {}
    env.QB.resources = { serverRegistry = function() return { track = function() end, untrack = function() end } end }
    env.QB.callback = { register = function() end }
    env.RegisterNetEvent = function() end
    local providers = env.exports
    -- Capture the native export registrar only during module loading; SQL has
    -- already captured its real local consumer driver and does not use this.
    env.exports = function(name, fn) registered[name] = fn end
    assert(loadfile('server.lua', 't', env))()
    assert(loadfile('server/compat/qb.lua', 't', env))()
    env.exports = providers
    -- Controlled durable-row absence after DELETE's effect, before its response.
    providers.qbsql.query = function(_, _, _, callback) callback({}) end
    local internal, api = env.QbInventory.internal, env.QbInventory.compat.qb
    H.equal(api.CreateInventory('recreated', { items = record('stash', 'recreated', 0, 2).items }), nil,
        'legacy creation keeps its no-value return')
    if savedFirst then H.equal(f.persistence.flush(), true, 'old inventory can already be saved') end
    local before = #f.calls
    f.hold = 'execute'
    local thread = coroutine.create(function() return api.RemoveInventory('recreated') end)
    local ok, wait = coroutine.resume(thread)
    assert(ok, wait)
    H.equal(coroutine.status(thread), 'suspended', 'real consumer awaits delete response')
    H.ok(f.pending.statement:find('DELETE FROM', 1, true), 'held write is the actual DELETE')
    H.equal(internal.getInventory('stash:recreated'), nil, 'old live record was evicted')
    api.CreateInventory('recreated', { items = record('stash', 'recreated', 0, 7).items })
    local replacement = assert(internal.getInventory('stash:recreated'))
    H.equal(replacement.items[1].amount, 7, 'trusted recreation is live before old delete returns')
    H.equal(f.complete(thread, { affectedRows = 1 }), true, 'RemoveInventory keeps its success return')
    H.equal(internal.getInventory('stash:recreated'), replacement, 'old completion preserves live replacement')
    H.equal(f.persistence.flush(), true, 'recreated snapshot flushes')
    H.equal(#f.calls, before + 2, 'old delete completion must not discard the replacement save')
    assertWrite(f.calls[#f.calls], 'recreated', 0, 7)
    H.equal(f.persistence.flush(), true, 'replacement is cleared after its own save')
    H.equal(#f.calls, before + 2, 'replacement is not saved twice')
end
H.finish()
