-- Regression (L6): the `inventory.internal` constructor in server.lua defines
-- every key exactly once, and nothing re-assigns a key the literal already has
-- (a duplicate silently wins and hides the earlier definition).
local H = dofile('test/harness.lua')

local file = assert(io.open('server.lua', 'rb'))
local source = file:read('a')
file:close()

local startAt = assert(source:find('\ninventory.internal = {\n', 1, true), 'constructor found')
local block = source:sub(startAt + 1, (source:find('\n}\n', startAt, true)))

local seen, duplicates = {}, {}
for key in block:gmatch('\n    ([%a_][%w_]*) = ') do
    if seen[key] then duplicates[#duplicates + 1] = key end
    seen[key] = true
end
H.equal(#duplicates, 0, 'no duplicate keys in the inventory.internal constructor: ' .. table.concat(duplicates, ', '))

for _, key in ipairs({ 'validSession', 'recordAudit', 'showItemBox', 'playerSetPath', 'auditAdd', 'lock', 'isSlotBusy' }) do
    H.ok(seen[key], 'inventory.internal.' .. key .. ' is defined')
end

local reassigned = {}
for key in source:gmatch('\ninventory%.internal%.([%a_][%w_]*) = ') do
    if seen[key] then reassigned[#reassigned + 1] = key end
end
H.equal(#reassigned, 0, 'no key of the constructor is re-assigned later: ' .. table.concat(reassigned, ', '))

H.finish()
