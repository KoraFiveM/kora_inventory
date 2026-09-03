-- Rob's Liquor: the stock rows are real registry items, and the shop's access
-- policy is the counter/bucket check -- not the shop id the client sent.
local H = dofile('test/harness.lua')

Config = { qbinventory = {} }
dofile('config.lua')
dofile('config/shops/liquorstore.lua')

local shop = Config.qbinventory.shops.liquorstore
H.equal(shop.id, 'liquorstore', 'the liquor store has a fixed canonical identifier')
H.ok(#shop.locations >= 1, 'the liquor store has approved locations')

-- Every stock row must name an item qbcore's registry actually defines.
-- Inventing an id here would present a slot with no label, no weight and no
-- price authority -- an unbuyable row that looks like a shop bug rather than a
-- config one.
QBCoreSeed = nil
dofile('../qbcore/shared/items.lua')
local known = {}
for _, def in ipairs(QBCoreSeed.items) do known[def.name] = true end

for _, row in ipairs(shop.inventory) do
    H.ok(known[row.name], ('stock row %s exists in the shared item registry'):format(tostring(row.name)))
    H.ok(type(row.amount) == 'number' and row.amount > 0, 'starter stock has a positive finite amount')
    H.ok(type(row.price) == 'number' and row.price > 0, 'starter stock has a positive server price')
    H.equal(row.label, nil, 'shop config leaves canonical labels to the registry-backed authority')
    H.equal(row.weight, nil, 'shop config leaves canonical weights to the registry-backed authority')
end

-- Every branch shares one blip label and category, which is what collapses the
-- five of them into a single pause-map legend heading.
H.equal(shop.blip.category, 11, 'branches are grouped in the map legend rather than listed one per row')
H.equal(shop.blip.label, shop.label, 'the legend heading is the shop name')

-- Each location must carry an explicit bucket: the server policy fails closed
-- on a missing one, so a row without it is a shop nobody can ever open.
for index, location in ipairs(shop.locations) do
    H.equal(type(location.bucket), 'number', ('location %d declares an explicit routing bucket'):format(index))
    H.equal(type(location.x), 'number', ('location %d has finite coordinates'):format(index))
end

local captured
exports = {
    qbinventory = {
        RegisterShop = function(_, id, data)
            captured = { id = id, data = data }
            return 'shop:' .. id
        end,
    },
}

local player = { bucket = 0, coords = { x = shop.locations[1].x, y = shop.locations[1].y, z = shop.locations[1].z } }
GetPlayerPed = function(source) return source == 7 and 101 or 0 end
DoesEntityExist = function(entity) return entity == 101 end
GetPlayerRoutingBucket = function(source) return source == 7 and player.bucket or -1 end
GetEntityCoords = function(entity) return entity == 101 and player.coords or nil end

local L = dofile('server/shops/liquorstore.lua')
H.equal(captured.id, 'liquorstore', 'server registers the fixed shop id')
H.equal(captured.data.inventory, shop.inventory, 'server uses declared stock rows without client data')
H.ok(type(captured.data.access) == 'function', 'shop has a server-side access callback')
H.ok(L.access(7, { type = 'shop', id = 'liquorstore' }), 'server permits an approved location in its approved bucket')

player.coords = { x = 0, y = 0, z = 0 }
H.equal(L.access(7, { type = 'shop', id = 'liquorstore' }), false, 'server rejects the shop id away from every counter')
player.coords = { x = shop.locations[1].x, y = shop.locations[1].y, z = shop.locations[1].z }
player.bucket = 9
H.equal(L.access(7, { type = 'shop', id = 'liquorstore' }), false, 'server rejects the shop id in the wrong routing bucket')
player.bucket = 0
H.equal(L.access(7, { type = 'shop', id = 'other' }), false, 'policy cannot be reused for another shop')

-- Every branch must be reachable: a counter more than interactionDistance from
-- itself would be a typo that only shows up as a shop nobody can open.
for index, location in ipairs(shop.locations) do
    player.coords = { x = location.x, y = location.y, z = location.z }
    H.ok(L.access(7, { type = 'shop', id = 'liquorstore' }),
        ('location %d opens the shop when stood on'):format(index))
end

H.finish()
