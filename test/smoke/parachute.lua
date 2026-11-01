-- Parachute use: kora_inventory registers a built-in handler so the item no
-- longer falls through to "no useable registered". The server only asks the
-- client to equip it and consumes the item once the client confirms.
local H = dofile('test/harness.lua')

Config = { qbinventory = {} }
dofile('config.lua')

local useables, removals, pushed, netEvents = {}, {}, {}, {}
local owned = { name = 'parachute', slot = 5 }
local invoking = nil
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
function TriggerClientEvent(event, src, payload) pushed[#pushed + 1] = { event = event, src = src, payload = payload } end
RegisterNetEvent = function(name, fn) netEvents[name] = fn end
AddEventHandler = function() end
GetInvokingResource = function() return invoking end
GetGameTimer = function() return NOW end
exports = setmetatable({}, { __index = function() return setmetatable({}, { __index = function() return function() return {} end end }) end })

local function load()
    useables, removals, pushed = {}, {}, {}
    dofile('server/useables.lua')
end

load()
H.ok(useables.parachute, 'the parachute item has a built-in use handler')

local ok = useables.parachute(7, { name = 'parachute', slot = 5 })
H.equal(ok, true, 'using it succeeds')
H.equal(#removals, 0, 'the item is not consumed before the client equips it')
H.equal(pushed[1].event, 'qbinventory:client:useParachute', 'the client is asked to equip it')
H.equal(pushed[1].payload.time, 1500, 'with the configured pack-up time')

source = 8
netEvents['qbinventory:server:parachuteEquipped']()
H.equal(#removals, 0, 'a confirmation nobody asked for consumes nothing')

source = 7
invoking = 'other_resource'
netEvents['qbinventory:server:parachuteEquipped']()
H.equal(#removals, 0, 'another resource cannot confirm for a player')
invoking = nil
netEvents['qbinventory:server:parachuteEquipped']()
H.equal(#removals, 1, 'the confirmation consumes exactly one parachute')
H.equal(removals[1].slot, 5, 'from the slot that was used')
netEvents['qbinventory:server:parachuteEquipped']()
H.equal(#removals, 1, 'a confirmation cannot be replayed')

useables.parachute(7, { name = 'parachute', slot = 5 })
NOW = NOW + 20000
netEvents['qbinventory:server:parachuteEquipped']()
H.equal(#removals, 1, 'a stale request is ignored')

useables.parachute(7, { name = 'parachute', slot = 5 })
owned = { name = 'water_bottle', slot = 5 }
netEvents['qbinventory:server:parachuteEquipped']()
H.equal(#removals, 1, 'the slot must still hold a parachute')

Config.qbinventory.builtinUsables.parachute = false
load()
H.equal(useables.parachute, nil, 'builtinUsables.parachute = false leaves the item to other resources')

H.finish()
