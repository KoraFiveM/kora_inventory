local H = dofile('test/harness.lua')

Config = { kora_inventory = {} }
dofile('config.lua')
dofile('config/shops/vendingmachine.lua')

local shop = Config.kora_inventory.shops.vendingmachine
H.equal(shop.id, 'vendingmachine', 'the vending machine shop has a fixed canonical identifier')
H.ok(#shop.models >= 1, 'vending machines target at least one prop model')
for _, model in ipairs(shop.models) do
    H.ok(type(model) == 'string' and #model > 0, 'every vending model is a non-empty string')
end
local expectedItems = { water_bottle = true, soda = true }
local found = {}
for _, row in ipairs(shop.inventory) do
    H.ok(expectedItems[row.name], ('stock row %s is a recognised catalogue item'):format(tostring(row.name)))
    H.ok(type(row.amount) == 'number' and row.amount > 0, 'starter stock has a positive finite amount')
    H.ok(type(row.price) == 'number' and row.price > 0, 'starter stock has a positive server price')
    found[row.name] = true
end
for name in pairs(expectedItems) do H.ok(found[name], ('vending machine stocks %s'):format(name)) end

local captured
exports = {
    kora_inventory = {
        RegisterShop = function(_, id, data)
            captured = { id = id, data = data }
            return 'shop:' .. id
        end,
    },
}

local eventHandlers = {}
AddEventHandler = function(name, fn) eventHandlers[name] = fn end

local distanceResult = true
Kora = { distance = { player = function() return distanceResult end } }

local timer = 1000
GetGameTimer = function() return timer end

local V = dofile('server/shops/vendingmachine.lua')
H.equal(captured.id, 'vendingmachine', 'server registers the fixed shop id')
H.equal(captured.data.inventory, shop.inventory, 'server uses declared stock rows without client data')
H.ok(type(captured.data.access) == 'function', 'shop has a server-side access callback')

local inv = { type = 'shop', id = 'vendingmachine' }

-- Fresh coordinates arrive on the initial open request.
distanceResult = true
H.ok(V.access(7, inv, { coords = { x = 1.0, y = 2.0, z = 3.0 } }), 'server permits a real machine within range')

-- Session revalidation (kora_inventory's validSession) has no fresh coords to
-- offer -- the short-lived approval from the open above must cover it.
H.ok(V.access(7, inv, nil), 'revalidation without fresh coords reuses the just-granted approval')

-- Once the approval window elapses, a bare revalidation must fail again
-- rather than trusting the source indefinitely.
timer = timer + 130000
H.equal(V.access(7, inv, nil), false, 'an expired approval no longer satisfies revalidation')

-- A bare, data-less open (no coords at all -- e.g. a bypass attempt that
-- skips the client target flow) must never fall through to a stale/foreign
-- approval it never earned.
H.equal(V.access(8, inv, nil), false, 'a source with no prior approval is rejected outright')

-- Coordinates that don't actually place the source near a machine are
-- rejected, and never grant a cached approval for later reuse.
distanceResult = false
H.equal(V.access(9, inv, { coords = { x = 1.0, y = 2.0, z = 3.0 } }), false, 'server rejects reported coordinates away from any machine')
H.equal(V.access(9, inv, nil), false, 'a rejected open never leaves behind a usable approval')

distanceResult = true
H.equal(V.access(7, { type = 'shop', id = 'other' }, { coords = { x = 1.0, y = 2.0, z = 3.0 } }), false, 'policy cannot be reused for another shop')
H.equal(V.access(7, { type = 'stash', id = 'vendingmachine' }, { coords = { x = 1.0, y = 2.0, z = 3.0 } }), false, 'policy only ever governs shop-type inventories')

-- Disconnecting clears the approval cache so a later source id can't inherit it.
H.ok(eventHandlers.playerDropped ~= nil, 'the vending shop cleans up on disconnect')
H.ok(V.access(10, inv, { coords = { x = 1.0, y = 2.0, z = 3.0 } }), 'a fresh source can still get approved before disconnecting')
source = 10
eventHandlers.playerDropped()
H.equal(V.access(10, inv, nil), false, 'a disconnected source loses its approval')

H.finish()
