-- Behavioural check for the kora_lib logger migration: failure paths emit the
-- expected Kora.logging call (level, stable event name, error carried in fields).
local H = dofile('test/harness.lua')
local logSpy = dofile('test/logging_spy.lua')

Config = { kora_inventory = {} }
dofile('shared.lua')

Kora = { blips = { create = function() error('boom: bad category') end } }
Kora.logging = logSpy.logging

local result = KoraInventory.createShopBlip('Config.x.blip', { x = 1, y = 2, z = 3 }, { category = 'Nope' })
H.equal(result, nil, 'a blip that cannot be created at all returns nil (behaviour unchanged)')
local first = logSpy.find('warn', 'blips.category_rejected')
H.ok(first, 'the rejected category is logged as warn blips.category_rejected')
H.ok(first.fields.error:find('bad category', 1, true), 'the error is carried in fields.error')
local second = logSpy.find('warn', 'blips.create_failed')
H.ok(second, 'the total failure is logged as warn blips.create_failed')
for _, call in ipairs(logSpy.calls) do
    H.ok(#call.event <= 128 and not call.event:find('%s'), 'event names are static identifiers')
    H.ok(not call.message:find('%^%d'), 'messages carry no colour codes')
end
H.finish()
