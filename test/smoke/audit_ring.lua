-- Regression (L8): the in-memory audit ring is circular (no per-insert array
-- shifting) while the public read order stays newest-first, across wrap-around,
-- a changed auditLimit and retention pruning.
local logSpy = dofile('test/logging_spy.lua')
local H = dofile('test/harness.lua')
Config = {}
dofile('config.lua')
dofile('shared.lua')
Kora = { util = { deepClone = function(v) return v end }, sql = {} }
logSpy.reset()
GetCurrentResourceName = function() return 'kora_inventory' end
GetInvokingResource = function() return nil end
CreateThread = function() end
Wait = function() end
TriggerEvent = function() end

dofile('server/audit_log.lua')
local audit = KoraInventory.auditLog
local clock = 1000000
audit.clock = function() return clock end
audit.sink = function(rows) return #rows end
local cfg = Config.kora_inventory
cfg.audit.enabled, cfg.audit.persist = true, false
cfg.audit.anomaly.enabled = false
cfg.auditLimit = 100

local function resources(filter)
    local out = {}
    for _, row in ipairs(audit.query(filter or { range = '1h' }).rows) do out[#out + 1] = row.resource end
    return out
end
local function record(index, at)
    clock = at or clock
    audit.record({ action = 'add', item = 'bread', amount = 1, resource = 'r' .. index })
end

-- Below capacity: newest first.
for index = 1, 5 do record(index) end
local rows = resources()
H.equal(#rows, 5, 'five entries kept')
H.equal(rows[1], 'r5', 'newest first')
H.equal(rows[5], 'r1', 'oldest last')

-- Wrap-around: only the newest 100 remain, still newest-first.
audit.reset()
for index = 1, 250 do record(index) end
rows = resources()
H.equal(#rows, 100, 'the ring is capped at auditLimit')
H.equal(rows[1], 'r250', 'newest entry first after wrapping')
H.equal(rows[100], 'r151', 'oldest kept entry last after wrapping')
for position = 1, 99 do
    if rows[position] ~= 'r' .. (251 - position) then
        H.ok(false, 'order broke at position ' .. position)
    end
end
local page2 = audit.query({ range = '1h', page = 1 })
H.equal(#page2.rows, 0, 'a capped ring of 100 has no second page')

-- Records keep coming after the wrap.
record(251)
rows = resources()
H.equal(rows[1], 'r251', 'a record after wrapping is newest')
H.equal(rows[100], 'r152', 'and pushes out exactly one oldest entry')
H.equal(#audit.query({ range = '1h' }).summary.resources > 0, true, 'the summary still reads the ring')

-- The limit can change at runtime.
cfg.auditLimit = 200
record(252)
rows = resources()
H.equal(rows[1], 'r252', 'order survives a limit change')
H.equal(#audit.query({ range = '1h', page = 1 }).rows, 1, 'raising the limit keeps every entry and adds the new one (101 in total)')
cfg.auditLimit = 100
record(253)
rows = resources()
H.equal(#rows, 100, 'lowering the limit trims to the newest entries')
H.equal(rows[1], 'r253', 'order survives a lowered limit')
H.equal(rows[100], 'r154', 'the oldest are the ones dropped')

-- Retention pruning after a wrap keeps order and keeps recording.
audit.reset()
cfg.auditLimit = 100
local base = 1000000
for index = 1, 130 do record(index, base + index) end
clock = base + 70 + 14 * 86400 -- entries older than 14 days (at < base + 70) are expired
audit.prune()
clock = base + 200 -- back inside the query window
rows = resources({ range = '7d' })
local survivors = #rows
H.equal(survivors, 61, 'prune dropped only the expired entries (index 70..130 remain)')
H.equal(rows[1], 'r130', 'newest first after pruning')
record(131)
rows = resources({ range = '7d' })
H.equal(rows[1], 'r131', 'recording works after pruning')
H.equal(#rows, survivors + 1, 'and appends')

-- A full ring never moves entries: recording is constant time (no table.move).
local source = io.open('server/audit_log.lua', 'rb'):read('a')
local recordBody = source:sub(source:find('function auditLog.record', 1, true), source:find('local function defaultSink', 1, true))
H.equal(recordBody:find('table.move', 1, true), nil, 'recording no longer shifts the ring array on insert')
H.equal(recordBody:find('table.remove(ring', 1, true), nil, 'and never removes from the front of the ring')

audit.reset()
H.equal(#resources(), 0, 'reset empties the ring')
record(1)
H.equal(#resources(), 1, 'and it records again')

H.finish()
