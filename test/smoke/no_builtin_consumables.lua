-- Consumables belong to kora_consumables. kora_inventory must not register its own
-- food/drink/alcohol/drug handler: it would answer the Use button before
-- kora_consumables (no progress bar, wrong effects, item removed instantly).
local H = dofile('test/harness.lua')

Config = { kora_inventory = {} }
dofile('config.lua')

local builtIn, explicit, increments = {}, {}, {}
KoraInventory = {
    internal = { setBuiltInUseable = function(name, fn) if fn then builtIn[name] = fn end end },
    api = {
        createUseable = function(name, fn) explicit[name] = fn end,
        getItemBySlot = function() end,
        removeItem = function() return true end,
    },
}
Kora = { callback = { trigger = function() return false end } }
GetGameTimer = function() return 0 end
local coreExports = setmetatable({
    incrementMetaData = function(_, src, key, amount) increments[#increments + 1] = { src = src, key = key, amount = amount } end,
    allShared = function() return {} end,
    onSharedChange = function() end,
}, { __index = function() return function() return {} end end })
exports = setmetatable({ kora_core = coreExports }, { __index = function() return setmetatable({}, { __index = function() return function() return {} end end }) end })

dofile('server/useables.lua')

local consumables = {
    'sandwich', 'bread', 'chocolate_bar', 'chips', 'hot_dog', 'egg_sandwich',
    'water', 'water_bottle', 'soda', 'coffee',
    'beer', 'whiskey', 'vodka', 'wine', 'ambeer',
    'cigarette', 'joint', 'weed',
}
for _, name in ipairs(consumables) do
    H.ok(explicit[name] == nil, name .. ' has no explicit kora_inventory use handler')
    H.ok(builtIn[name] == nil, name .. ' has no built-in kora_inventory use handler')
end
H.equal(#increments, 0, 'loading kora_inventory touches no hunger/thirst/stress metadata')
H.ok(builtIn.parachute ~= nil, 'the parachute built-in is still registered')

-- The client half must not carry the old eat/drink effect either.
local f = assert(io.open('client/useables.lua'))
local client = f:read('*a'); f:close()
H.ok(not client:find('consumeEffect', 1, true), 'client has no kora_inventory:client:consumeEffect handler')

-- Source guard: nothing in the server half may write needs metadata.
f = assert(io.open('server/useables.lua')); local server = f:read('*a'); f:close()
H.ok(not server:find("'hunger'", 1, true) and not server:find("'thirst'", 1, true), 'server/useables.lua never writes hunger/thirst')
print('no_builtin_consumables ok')
