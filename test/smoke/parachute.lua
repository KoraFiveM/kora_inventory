-- Parachute use: kora_inventory registers a built-in handler so the item no
-- longer falls through to "no useable registered". The handler waits for the
-- client's progress bar (keeping the mid-use lock) and only consumes the item
-- when the client reports the parachute was equipped.
local H = dofile('test/harness.lua')

Config = { qbinventory = {} }
dofile('config.lua')

local useables, removals, calls = {}, {}, {}
local owned = { name = 'parachute', slot = 5 }
local answer = true
local NOW = 1000

QbInventory = {
    internal = { setBuiltInUseable = function(name, fn) useables[name] = fn end },
    api = {
        createUseable = function() end,
        getItemBySlot = function(_, slot) if owned and owned.slot == slot then return owned end end,
        removeItem = function(src, name, amount, slot, reason)
            removals[#removals + 1] = { src = src, name = name, amount = amount, slot = slot, reason = reason }
            return true
        end,
    },
}
Kora = {
    callback = {
        trigger = function(src, name, payload)
            calls[#calls + 1] = { src = src, name = name, payload = payload }
            NOW = NOW + (Config.qbinventory.builtinUsables.parachuteTime or 0)
            if answer == 'error' then error('timeout') end
            return answer
        end,
    },
}
GetGameTimer = function() return NOW end
exports = setmetatable({}, { __index = function() return setmetatable({}, { __index = function() return function() return {} end end }) end })

local function load()
    useables, removals, calls = {}, {}, {}
    dofile('server/useables.lua')
end

load()
H.ok(useables.parachute, 'the parachute item has a built-in use handler')
H.equal(Config.qbinventory.builtinUsables.parachuteTime, 2500, 'the progress bar defaults to 2500 ms')
H.equal(Config.qbinventory.builtinUsables.parachuteBag.enabled, true, 'the visible pack is on by default')
H.equal(Config.qbinventory.builtinUsables.parachuteBag.male.drawable, 8, 'with the stock freemode parachute bag')

local ok = useables.parachute(7, { name = 'parachute', slot = 5 })
H.equal(ok, true, 'using it succeeds when the client equips it')
H.equal(calls[1].name, 'qbinventory:client:useParachute', 'the client is asked to run the bar and equip it')
H.equal(calls[1].payload.time, 2500, 'with the configured duration')
H.equal(#removals, 1, 'exactly one parachute is consumed after the client confirms')
H.equal(removals[1].slot, 5, 'from the slot that was used')

answer = false
H.equal(useables.parachute(7, { name = 'parachute', slot = 5 }), false, 'a cancelled bar / existing parachute is rejected')
H.equal(#removals, 1, 'and consumes nothing')

answer = 'error'
H.equal(useables.parachute(7, { name = 'parachute', slot = 5 }), false, 'a client that never answers is rejected')
H.equal(#removals, 1, 'and consumes nothing')

answer = true
local realTrigger = Kora.callback.trigger
Kora.callback.trigger = function() return true end
H.equal(useables.parachute(7, { name = 'parachute', slot = 5 }), false, 'an instant answer (faster than the bar) is ignored')
H.equal(#removals, 1, 'and consumes nothing')
Kora.callback.trigger = realTrigger

owned = { name = 'water_bottle', slot = 5 }
H.equal(useables.parachute(7, { name = 'parachute', slot = 5 }), false, 'the slot must still hold a parachute')
H.equal(#removals, 1, 'and consumes nothing')

Config.qbinventory.builtinUsables.parachute = false
load()
H.equal(useables.parachute, nil, 'builtinUsables.parachute = false leaves the item to other resources')

H.finish()
