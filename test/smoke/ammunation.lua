local H = dofile('test/harness.lua')

Config = { qbinventory = {} }
dofile('config.lua')
dofile('config/shops/ammunation.lua')

local shop = Config.qbinventory.shops.ammunation
H.equal(shop.id, 'ammunation', 'Ammu-Nation has a fixed canonical identifier')
H.ok(#shop.locations >= 1, 'Ammu-Nation has approved locations')
H.equal(shop.blip.category, shop.blip.label, 'Ammu-Nation locations share one named legend category')
local expectedAmmo = {
    pistol_ammo = true, smg_ammo = true, shotgun_ammo = true,
    rifle_ammo = true, mg_ammo = true, snp_ammo = true,
}
local ammoFound = {}
for _, row in ipairs(shop.inventory) do
    H.ok(type(row.name) == 'string' and (row.name:sub(1, 7) == 'weapon_' or expectedAmmo[row.name]), 'stock uses registered weapon or ammo names')
    H.ok(type(row.amount) == 'number' and row.amount > 0, 'starter stock has a positive finite amount')
    H.ok(type(row.price) == 'number' and row.price > 0, 'starter stock has a positive server price')
    H.equal(row.label, nil, 'shop config leaves canonical labels to the registry-backed authority')
    H.equal(row.weight, nil, 'shop config leaves canonical weights to the registry-backed authority')
    if expectedAmmo[row.name] then ammoFound[row.name] = true end
end
for name in pairs(expectedAmmo) do H.ok(ammoFound[name], ('Ammu-Nation stocks %s'):format(name)) end

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

local A = dofile('server/shops/ammunation.lua')
H.equal(captured.id, 'ammunation', 'server registers the fixed shop id')
H.equal(captured.data.inventory, shop.inventory, 'server uses declared stock rows without client data')
H.ok(type(captured.data.access) == 'function', 'shop has a server-side access callback')
H.ok(A.access(7, { type = 'shop', id = 'ammunation' }), 'server permits an approved location in its approved bucket')

player.coords = { x = 0, y = 0, z = 0 }
H.equal(A.access(7, { type = 'shop', id = 'ammunation' }), false, 'server rejects the shop id away from every counter')
player.coords = { x = shop.locations[1].x, y = shop.locations[1].y, z = shop.locations[1].z }
player.bucket = 9
H.equal(A.access(7, { type = 'shop', id = 'ammunation' }), false, 'server rejects the shop id in the wrong routing bucket')
player.bucket = 0
H.equal(A.access(7, { type = 'shop', id = 'other' }), false, 'policy cannot be reused for another shop')

H.finish()
