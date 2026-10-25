local H = dofile('test/harness.lua')
local calls, onlineResult, offlineResult, flushResult = {}, { true }, { true }, { true }
local throwOnline, throwFlush
local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
QbInventory = { internal = {}, api = {}, copy = copy,
    persistence = { flush = function() error('player saves must not flush unrelated secondary inventories') end } }
exports = { qbcore = {
    savePlayer = function(_, src, field)
        if throwOnline then error('core unavailable') end
        calls.online = { src = src, field = field }
        return table.unpack(onlineResult)
    end,
    saveOfflinePlayer = function(_, data, fields)
        calls.offline = { data = data, fields = fields }
        return table.unpack(offlineResult)
    end,
} }
QB = { sql = { flush = function(tableName)
    calls.flush = (calls.flush or 0) + 1
    H.equal(tableName, 'players', 'only the authoritative player queue is flushed')
    if throwFlush then error('queue threw') end
    return table.unpack(flushResult)
end } }
dofile('server/compat/qb.lua')
local save = QbInventory.compat.qb.SaveInventory
H.equal(save(7), nil, 'online success preserves upstream nil return')
H.equal(calls.online.src, 7, 'online save uses the player source')
H.equal(calls.online.field, 'items', 'inventory fence must be checked before queueing')
H.equal(calls.flush, 1, 'online save awaits queue durability')
local source = { citizenid = 'CID1', items = { [2] = { name = 'water', amount = 3 } }, money = { bank = 99999 } }
H.equal(save(source, true), nil, 'offline success preserves upstream nil return')
H.equal(calls.offline.data.citizenid, 'CID1')
H.equal(calls.offline.data.items[2].amount, 3)
H.equal(calls.offline.data.money, nil, 'offline save cannot overwrite money or unrelated fields')
H.equal(calls.offline.fields[1], 'items')
calls.offline.data.items[2].amount = 4
H.equal(source.items[2].amount, 3, 'offline input is not mutated')
H.equal(calls.flush, 1, 'offline authority already performs its awaited update')
H.equal(save({ citizenid = 'EMPTY' }, true), nil, 'empty offline inventory is supported')
H.equal(next(calls.offline.data.items), nil)
local ok, err = save({ citizenid = 'CID1', items = 'invalid' }, true)
H.equal(ok, false); H.equal(err, 'invalid offline player inventory')
onlineResult = { false, 'player data is busy' }
ok, err = save(7)
H.equal(ok, false); H.equal(err, 'player data is busy')
H.equal(calls.flush, 1, 'rejected inventory writes do not flush unrelated changes')
onlineResult = { false, 'no such player' }
H.equal(save(404), nil, 'missing online player matches upstream early return')
offlineResult = { false, 'player is online' }
ok, err = save(source, true)
H.equal(ok, false); H.equal(err, 'player is online', 'offline API cannot rewrite an active player')
onlineResult = { true }; flushResult = { false, 'database unavailable' }
ok, err = save(7)
H.equal(ok, false); H.equal(err, 'database unavailable', 'durable failure is not reported as success')
throwFlush = true
ok, err = save(7)
H.equal(ok, false); H.ok(err:find('queue threw', 1, true))
throwFlush, throwOnline = false, true
ok, err = save(7)
H.equal(ok, false); H.ok(err:find('core unavailable', 1, true))
H.finish()
