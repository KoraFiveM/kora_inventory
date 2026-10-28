local H = dofile('test/harness.lua')
local jsonTools = dofile('../kora_core/test/mocks.lua')
local json = { encode = jsonTools.stableEncode, decode = jsonTools.simpleDecode }
local function copy(value) return json.decode(json.encode(value)) end

local function setup(database, skipRestore)
    local f = { db = database or { inventories = {}, operations = {} }, provided = {}, events = {}, threads = {}, tokens = {}, players = {
        [1] = { citizenid = 'CID1', items = {} }, [2] = { citizenid = 'CID2', items = {} },
    } }
    local env = {}; for key, value in pairs(_G) do env[key] = value end
    env.json, env.Config, env.QbInventory = json, {}, nil
    env.GetCurrentResourceName = function() return 'kora_inventory' end
    env.GetInvokingResource = function() return f.caller or 'housing' end
    env.GetGameTimer = function() return 100 end
    env.GetPlayerPed = function(src) return src end
    env.GetPlayerRoutingBucket = function() return 0 end
    env.GetEntityCoords = function() return { x = 0, y = 0, z = 0 } end
    env.CreateThread = function(fn) f.threads[#f.threads + 1] = fn end
    env.AddEventHandler = function(name, fn) f.events[name] = fn end
    env.RegisterNetEvent = env.AddEventHandler
    env.TriggerEvent = function(name, ...) if f.events[name] then f.events[name](...) end end
    env.TriggerClientEvent, env.RegisterCommand, env.Wait = function() end, function() end, function() end
    local definitions = { bread = { name = 'bread', weight = 1 }, wood = { name = 'wood', weight = 1 } }
    local core = {}
    function core.getShared(_, _, name) return definitions[name] end
    function core.getPlayerData(_, src, path)
        local data = f.players[src]
        return data and copy(path and data[path[1]] or data)
    end
    function core.setPath(_, src, path, value)
        for _, token in pairs(f.tokens) do if token.cid == f.players[src].citizenid then return false, 'inventory is fenced' end end
        if #path == 1 then f.players[src][path[1]] = copy(value)
        else f.players[src][path[1]][path[2]] = copy(value) end
        return true
    end
    function core.beginPlayerColumnOperation(_, key, cids)
        f.tokens[key] = f.tokens[key] or { cid = cids[1] }
        return key
    end
    function core.getPlayerColumnOperations()
        local rows = {}; for key in pairs(f.tokens) do rows[#rows + 1] = { token = key, operationKey = key } end; return rows
    end
    function core.abortPlayerColumnOperation(_, token)
        if f.failAbort then return false, 'controlled fence release failure' end
        f.tokens[token] = nil; return true
    end
    function core.finishPlayerColumnOperation(_, token, values)
        local cid = assert(f.tokens[token]).cid
        for src, data in pairs(f.players) do
            if data.citizenid == cid then data.items = copy(values[cid].inventory); env.TriggerEvent('qbcore:server:inventoryChanged', src) end
        end
        f.tokens[token] = nil
        return true
    end
    env.exports = setmetatable({ kora_core = core }, { __call = function(_, name, fn) f.provided[name] = fn end })
    env.QB = {
        resources = { serverRegistry = function() return { track = function() end, untrack = function() end } end },
        callback = { register = function() end }, distance = { player = function() return not f.far end }, sql = {},
    }
    local sql = env.QB.sql
    sql.ready, sql.migrateFiles = function() return true end, function() return true end
    sql.query = function(statement, params)
        if f.failRead then return nil, 'controlled read failure' end
        if statement:find('FROM `qbinventory_inventories`', 1, true) then
            if params and #params > 0 then
                local row = f.db.inventories[params[1] .. ':' .. params[2]]
                return row and { copy(row) } or {}
            end
            if skipRestore then return {} end
            local rows = {}; for _, row in pairs(f.db.inventories) do rows[#rows + 1] = copy(row) end; return rows
        end
        return {}
    end
    sql.execute = function(statement, params)
        if f.failSave then return nil, 'controlled persistence failure' end
        if statement:find('INSERT INTO `qbinventory_inventories`', 1, true) then
            f.db.inventories[params[1] .. ':' .. params[2]] = {
                inventory_type = params[1], inventory_id = params[2], label = params[3], slots = params[4], max_weight = params[5],
                revision = params[6], items = params[7], properties = params[8],
            }
        elseif statement:find('INSERT IGNORE INTO `qbinventory_recovery_operations`', 1, true) then
            local key = params[1] .. ':' .. params[2]
            f.db.operations[key] = f.db.operations[key] or { provider = params[1], operation_key = params[2], stash_id = params[3], citizenid = params[4], status = 'pending' }
        end
        return { affectedRows = 1 }
    end
    local function commit(statements)
        local first = statements[1].values
        local row = f.db.operations[first[1] .. ':' .. first[2]]
        H.equal(row.status, 'pending')
        local source, complete = statements[2].values, statements[4].values
        local inv = f.db.inventories['stash:' .. source[3]]
        H.equal(inv.revision, source[4], 'source revision is compared before committing')
        inv.items, inv.revision = source[1], source[2]
        row.status, row.destination_items, row.source_revision, row.receipt = 'complete', complete[1], complete[2], complete[3]
    end
    sql.awaitCheckedOperation = function(key, fingerprint)
        H.equal(key, f.lastContext.key)
        H.equal(fingerprint, f.lastContext.fingerprint)
        if f.delayedCommit then
            f.delayedCommit = false
            commit(f.lastStatements)
            return { active = true, result = { success = true } }
        end
        return { active = false }
    end
    sql.transactionChecked = function(statements, context)
        local first = statements[1].values
        local row = f.db.operations[first[1] .. ':' .. first[2]]
        if #statements == 1 then return { success = true, results = { row and { copy(row) } or {} } } end
        H.equal(context.key, 'qbinventory:housing:' .. first[2])
        H.equal(context.citizenids[1], 'CID1')
        H.equal(context.fingerprint, json.encode({ 'housing', first[2], first[3], first[4] }))
        f.lastContext, f.lastStatements = copy(context), copy(statements)
        for _, statement in ipairs(statements) do H.equal(statement.expectedRows, 1, 'durable mutation checks affected rows') end
        if f.failCommit then return { success = false, code = 'unavailable', message = 'controlled rollback' } end
        if not f.ambiguousRollback then commit(statements) end
        if f.ambiguousCommit or f.ambiguousRollback then return { success = false, code = 'indeterminate' } end
        return { success = true, results = {} }
    end
    local function load(path) assert(loadfile(path, 't', env))() end
    load('config.lua'); load('shared.lua'); env.Config.qbinventory.cash.asItem = false
    load('server/persistence.lua'); load('server.lua'); load('server/recovery.lua')
    f.env, f.inventory = env, env.QbInventory
    f.threads[1]()
    function f.policy(allowed)
        f.allowed = allowed
        return f.provided.RegisterStashPolicy('lease-1', { slots = 10, maxWeight = 1000 }, function(src)
            if f.policyError then error('controlled policy error') end
            return f.allowed and src == 1
        end)
    end
    function f.items(amount) assert(f.provided.SetStashItems('lease-1', { [1] = { name = 'bread', amount = amount, info = { batch = 'original' } } })) end
    return f
end

do
    local f = setup()
    H.equal(f.policy(true), true)
    f.items(3)
    local opened, session = f.provided.stashOpen(1, 'lease-1')
    H.equal(opened, true)
    f.allowed = false
    H.equal(f.inventory.internal.transfer(1, {
        token = session.token, fromInventory = 'stash:lease-1', toInventory = 'player:1',
        fromSlot = 1, amount = 1, fromRevision = session.secondary.revision, toRevision = session.primary.revision,
    }), false, 'revocation applies to an already open transfer session')
    H.equal(f.provided.GetStashItems('lease-1')[1].amount, 3)
    H.equal(next(f.players[1].items), nil)
    H.equal(f.provided.stashOpen(1, 'lease-1'), false, 'revoked policy denies an existing stash')
    f.allowed, f.policyError = true, true
    H.equal(f.provided.stashOpen(1, 'lease-1'), false, 'policy exception denies')
    f.policyError = false
    f.env.QbInventory.persistence.flush()
    local properties = json.decode(f.db.inventories['stash:lease-1'].properties)
    H.equal(properties.policyOwner, 'housing'); H.equal(properties.accessRequired, true)
    f.events.onResourceStop('housing')
    H.equal(f.provided.stashOpen(1, 'lease-1'), false, 'provider stop denies')
    local restarted = setup(f.db)
    H.equal(restarted.provided.stashOpen(1, 'lease-1'), false, 'restored required policy is closed before rebind')
    H.equal(restarted.policy(true), true)
    H.equal(restarted.provided.stashOpen(1, 'lease-1'), true)
    restarted.caller = 'other'
    H.equal(restarted.policy(true), false, 'another resource cannot replace a policy')
end

do
    local original = setup(); assert(original.policy(true)); original.items(3); original.inventory.persistence.flush()
    local lazy = setup(original.db, true)
    lazy.caller = 'other'
    H.equal(lazy.policy(true), false, 'lazy hydration cannot overwrite a persisted provider marker before checking ownership')
    lazy.caller = 'housing'
    H.equal(lazy.provided.RebindStashPolicy('lease-1', function() return true end), true)
    H.equal(lazy.provided.GetStashItems('lease-1')[1].amount, 3)
    local unavailable = setup(original.db, true); unavailable.failRead = true
    H.equal(unavailable.policy(true), false, 'failed hydrate cannot overwrite existing durable contents with an empty stash')
    H.equal(json.decode(original.db.inventories['stash:lease-1'].items)[1].amount, 3)
end

do
    local f = setup(); f.failSave = true
    H.equal(f.policy(true), false, 'registration requires a confirmed durable policy marker')
    H.equal(f.provided.stashOpen(1, 'lease-1'), false, 'failed registration remains closed')
    H.equal(f.provided.RebindStashPolicy('lease-1', function() return true end), false, 'rebind cannot activate an unconfirmed policy marker')
end

do
    local f = setup()
    H.equal(f.provided.RegisterStashPolicy('bad', { coords = {} }, function() return true end), false)
    H.equal(f.provided.RegisterStashPolicy('bad', { coords = { x = 0/0, y = 0, z = 0 } }, function() return true end), false)
    H.equal(f.provided.RegisterStashPolicy('bad', { distance = math.huge }, function() return true end), false)
end

do
    local f = setup(); assert(f.policy(true)); f.items(3)
    H.equal(f.provided.SetStashBlocked('lease-1', true), true)
    H.equal(f.provided.stashOpen(1, 'lease-1'), false)
    H.equal(f.provided.SetStashItems('lease-1', {}), false)
    local restarted = setup(f.db); assert(restarted.policy(true))
    H.equal(restarted.provided.stashOpen(1, 'lease-1'), false, 'sale freeze survives inventory restart and policy rebind')
    H.equal(restarted.provided.SetStashBlocked('lease-1', false), true)
    H.equal(restarted.provided.stashOpen(1, 'lease-1'), true)
    H.equal(restarted.provided.GetStashItems('lease-1')[1].amount, 3)
    local thread = coroutine.create(function()
        return restarted.inventory.internal.lock({ 'stash:lease-1' }, function() coroutine.yield('held'); return true end)
    end)
    assert(coroutine.resume(thread))
    H.equal(restarted.provided.SetStashBlocked('lease-1', true), false, 'freeze cannot pass an unfinished transfer lock')
    assert(coroutine.resume(thread))
    H.equal(restarted.provided.SetStashBlocked('lease-1', true), true)
end

do
    local f = setup()
    assert(f.provided.RegisterStashPolicy('lease-1', { slots = 10, maxWeight = 1000, coords = { x = 0, y = 0, z = 0 } }, function(src) return src == 1 end))
    f.items(3); f.far = true
    H.equal(f.provided.stashOpen(1, 'lease-1'), false)
    H.equal(f.provided.ClaimStash(1, 'lease-1', 'remote-recovery'), true, 'trusted recovery remains available after physical access ends')
    H.equal(f.players[1].items[1].amount, 3)
end

do
    local f = setup()
    assert(f.provided.RegisterStashPolicy('lease-1', { slots = 10, maxWeight = 1000 }, function(src, _, _, context)
        return src == 1 and context and context.recovery == true
    end))
    f.items(3)
    H.equal(f.provided.stashOpen(1, 'lease-1', { recovery = true }), false, 'client-like open options cannot forge trusted recovery context')
    H.equal(f.provided.ClaimStash(1, 'lease-1', 'context'), true)
    H.equal(f.players[1].items[1].amount, 3)
end

do
    local f = setup(); assert(f.policy(true)); f.items(3)
    local ok, result = f.provided.ClaimStash(1, 'lease-1', 'claim-1')
    H.equal(ok, true); H.equal(result.amount, 3)
    H.equal(f.players[1].items[1].amount, 3)
    H.equal(next(f.provided.GetStashItems('lease-1')), nil)
    H.equal(f.provided.ClaimStash(1, 'lease-1', 'claim-1'), true)
    H.equal(f.players[1].items[1].amount, 3, 'duplicate claim does not deliver twice')
    f.items(2)
    H.equal(f.provided.ClaimStash(1, 'lease-1', 'claim-1'), true)
    H.equal(f.provided.GetStashItems('lease-1')[1].amount, 2, 'receipt retry cannot consume later contents')
    H.equal(f.provided.ClaimStash(2, 'lease-1', 'claim-1'), false, 'receipt is bound to its recipient')
end

do
    local f = setup(); assert(f.policy(true)); f.items(3)
    f.env.Config.qbinventory.playerSlots = 1
    f.players[1].items = { [1] = { name = 'wood', amount = 1, slot = 1, info = {} } }
    H.equal(f.provided.ClaimStash(1, 'lease-1', 'capacity'), false)
    H.equal(f.provided.GetStashItems('lease-1')[1].amount, 3)
    H.equal(next(f.tokens), nil, 'capacity rejection releases the player fence')
    f.players[1].items = {}
    H.equal(f.provided.ClaimStash(1, 'lease-1', 'capacity'), true, 'same key retries after making room')
end

for _, ambiguity in ipairs({ 'ambiguousCommit', 'ambiguousRollback' }) do
    local f = setup(); assert(f.policy(true)); f.items(3)
    f[ambiguity] = true
    H.equal(f.provided.ClaimStash(1, 'lease-1', 'uncertain'), false)
    H.ok(next(f.tokens), 'ambiguous result retains core fence')
    H.equal(f.provided.stashOpen(1, 'lease-1'), false)
    H.equal(f.provided.SetStashItems('lease-1', {}), false, 'source cannot be overwritten before reconciliation')
    f[ambiguity] = false
    H.equal(f.provided.ClaimStash(1, 'lease-1', 'uncertain'), true)
    H.equal(f.players[1].items[1].amount, 3)
    H.equal(next(f.provided.GetStashItems('lease-1')), nil)
    H.equal(next(f.tokens), nil)
end

do
    local f = setup(); assert(f.policy(true)); f.items(3); f.failCommit = true
    H.equal(f.provided.ClaimStash(1, 'lease-1', 'rollback'), false)
    H.equal(f.provided.GetStashItems('lease-1')[1].amount, 3)
    H.equal(next(f.players[1].items), nil)
    H.equal(next(f.tokens), nil)
    f.failCommit = false
    H.equal(f.provided.ClaimStash(1, 'lease-1', 'rollback'), true)
end

do
    local f = setup(); assert(f.policy(true)); f.items(3)
    f.ambiguousRollback = true
    H.equal(f.provided.ClaimStash(1, 'lease-1', 'old-worker'), false)
    f.events.onResourceStop('housing')
    H.equal(f.provided.RebindStashPolicy('lease-1', function(src) return src == 1 end), true, 'callback-only rebind is safe while durable recovery is pending')
    H.equal(f.provided.stashOpen(1, 'lease-1'), false)
    f.delayedCommit, f.ambiguousRollback = true, false
    H.equal(f.provided.ClaimStash(1, 'lease-1', 'old-worker'), true, 'restart reconciliation joins an old worker before reading pending intent')
    H.equal(f.players[1].items[1].amount, 3)
    H.equal(next(f.tokens), nil)
end

do
    local f = setup(); assert(f.policy(true)); f.items(3)
    f.failCommit, f.failAbort = true, true
    H.equal(f.provided.ClaimStash(1, 'lease-1', 'failed-release'), false)
    H.equal(f.provided.stashOpen(1, 'lease-1'), false, 'failed core fence release keeps source frozen')
    H.ok(next(f.tokens))
    f.failCommit, f.failAbort = false, false
    H.equal(f.provided.ClaimStash(1, 'lease-1', 'failed-release'), true)
end

do
    local f = setup(); assert(f.policy(true)); f.items(3); f.ambiguousCommit = true
    H.equal(f.provided.ClaimStash(1, 'lease-1', 'restored'), false)
    local restarted = setup(f.db)
    restarted.tokens, restarted.lastContext = f.tokens, f.lastContext
    assert(restarted.policy(true)); restarted.items(2)
    H.equal(restarted.provided.ClaimStash(1, 'lease-1', 'restored'), true)
    H.equal(restarted.players[1].items[1].amount, 3)
    H.equal(restarted.provided.GetStashItems('lease-1')[1].amount, 2, 'receipt publication preserves deposits made after restored source commit')
end

H.finish()
