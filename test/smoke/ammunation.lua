local H = dofile('test/harness.lua')

Config = { qbinventory = {} }
dofile('config.lua')
dofile('config/shops/ammunation.lua')

local shop = Config.qbinventory.shops.ammunation
H.equal(shop.id, 'ammunation', 'Ammu-Nation has a fixed canonical identifier')
H.ok(#shop.locations >= 1, 'Ammu-Nation has approved locations')
H.equal(shop.blip.category, 'Weapons', 'Ammu-Nation uses the canonical weapon-store category')
H.equal(shop.blip.name, shop.label, 'Ammu-Nation supplies its storefront name separately')
H.equal(shop.blip.label, nil, 'kora_lib composes the map label from category and name')
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
    kora_inventory = {
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
Kora = { util = { nearest = function(list, position, opts)
    local best, bestDistance
    for _, entry in pairs(list) do
        if opts.bucketOf == nil or opts.bucketOf(entry) == opts.bucket then
            local dx, dy, dz = position.x - entry.x, position.y - entry.y, position.z - entry.z
            local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
            if (opts.radius == nil or distance <= opts.radius) and (bestDistance == nil or distance < bestDistance) then
                best, bestDistance = entry, distance
            end
        end
    end
    return best, bestDistance
end } }
dofile('server/shops/location_policy.lua')

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

-- Restocking: depleted rows and sold-out rows return, nothing is lowered.
local stored = {
    [1] = { name = 'weapon_knife', amount = 12, price = 250, label = 'Knife' },
    [3] = { name = 'weapon_pistol', amount = 99, price = 7500 },
}
local sets = 0
exports.kora_inventory.GetShopItems = function(_, id)
    H.equal(id, 'ammunation', 'restock reads the ammunation shelf')
    return stored
end
exports.kora_inventory.SetShopItems = function(_, id, items)
    sets = sets + 1
    stored = items
    return true
end
H.ok(A.restock(), 'restock succeeds')
H.equal(stored[1].amount, shop.inventory[1].amount, 'a depleted row is topped back up')
H.equal(stored[2].name, shop.inventory[2].name, 'a sold-out row is restored')
H.equal(stored[2].price, shop.inventory[2].price, 'with its configured price')
H.equal(stored[3].amount, 99, 'a level above the configured amount is never lowered')
H.equal(sets, 1, 'one write for the whole shelf')
H.ok(A.restock(), 'restock is repeatable')
H.equal(sets, 1, 'a full shelf is not rewritten')
H.equal(shop.limitedStock, true, 'stock is limited by default')
H.equal(shop.restockIntervalMinutes, 30, 'restock interval defaults to 30 minutes')

-- The shelf is a catalogue: registration opts it out of the weight cap.
H.equal(shop.weightLimit, false, 'Ammu-Nation stock is not weight-capped by default')
H.equal(captured.data.weightLimit, false, 'the weight policy reaches RegisterShop')

-- A refused shelf write falls back to row-by-row: rows that fit are kept and
-- each refused row is named in the log, instead of one bare failure.
local printed = {}
local realPrint = print
print = function(line) printed[#printed + 1] = line end
stored = { [1] = { name = 'weapon_knife', amount = 1, price = 250 } }
local writes = {}
exports.kora_inventory.SetShopItems = function(_, _, items)
    for _, item in pairs(items) do
        if item.name == shop.inventory[2].name then
            writes[#writes + 1] = false
            return false, 'over weight'
        end
    end
    writes[#writes + 1] = true
    stored = {}
    for slot, item in pairs(items) do stored[slot] = { name = item.name, amount = item.amount, price = item.price } end
    return true
end
local okRestock, why = A.restock()
H.equal(okRestock, false, 'a refused row makes the restock report failure')
H.ok(tostring(why):find('1 of', 1, true), 'the summary counts the refused rows')
H.equal(stored[1].amount, shop.inventory[1].amount, 'rows that fit are still restocked')
H.equal(stored[2], nil, 'the refused row is left as it was')
H.equal(stored[3].amount, shop.inventory[3].amount, 'rows after the refused one are still restocked')
local named = false
for _, line in ipairs(printed) do
    if line:find(shop.inventory[2].name, 1, true) and line:find('over weight', 1, true) and line:find('slot 2', 1, true) then named = true end
end
H.ok(named, 'the log names the refused slot, item and reason')

-- A slot holding a different item than its config row is reported once.
printed = {}
stored = { [1] = { name = 'weapon_bat', amount = 1, price = 500 } }
exports.kora_inventory.SetShopItems = function(_, _, items) stored = items return true end
A.restock()
A.restock()
local mismatches = 0
for _, line in ipairs(printed) do
    if line:find('slot 1 holds weapon_bat', 1, true) then mismatches = mismatches + 1 end
end
H.equal(mismatches, 1, 'a slot/item mismatch is logged once, not every interval')
H.equal(stored[1].name, 'weapon_bat', 'a mismatched slot is never overwritten')
print = realPrint

H.finish()
