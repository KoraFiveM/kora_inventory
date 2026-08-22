local H = dofile('test/harness.lua')

Config = { qbinventory = {} }
dofile('config.lua')
dofile('shared.lua')

-- Deterministic server-native fakes. No data below comes from a client input.
local entities = {
    [101] = { type = 2, bucket = 1, coords = { x = 1, y = 0, z = 0 }, plate = ' ab  12  ', class = 0 },
    [102] = { type = 1, bucket = 1, coords = { x = 1, y = 0, z = 0 }, plate = 'BAD', class = 0 },
}
NetworkGetEntityFromNetworkId = function(id) return id end
DoesEntityExist = function(entity) return entity == 1 or entities[entity] ~= nil end
GetEntityType = function(entity) return entities[entity] and entities[entity].type or 1 end
GetPlayerPed = function(src) return src == 7 and 1 or 0 end
GetPlayerRoutingBucket = function(src) return src == 7 and 1 or 2 end
GetEntityRoutingBucket = function(entity) return entities[entity] and entities[entity].bucket or 1 end
GetEntityCoords = function(entity)
    if entity == 1 then return { x = 0, y = 0, z = 0 } end
    return entities[entity] and entities[entity].coords
end
GetVehicleNumberPlateText = function(entity) return entities[entity].plate end
GetVehicleClass = function(entity) return entities[entity].class end

local V = dofile('server/vehicles.lua')
H.equal(V.normalisePlate('  ab   12  '), 'AB 12', 'plate whitespace is canonical')
H.equal(V.normalisePlate('A:B'), nil, 'plate cannot inject inventory key separator')
H.equal(V.inventoryKey('trunk', ' ab12 '), 'trunk:AB12', 'trunk key is canonical')
H.equal(V.inventoryKey('glovebox', 'ab12'), 'glovebox:AB12', 'glovebox key is canonical')
H.equal(V.inventoryKey('stash', 'ab12'), nil, 'vehicle keys reject arbitrary types')
H.equal(assert(V.capacity('trunk', 0)).slots, 30, 'configured class capacity is used')
H.equal(V.capacity('trunk', 8), nil, 'motorcycle trunk is disabled')
local vehicle = assert(V.validate(7, 'trunk', 101))
H.equal(vehicle.plate, 'AB 12', 'native plate is resolved server-side')
H.equal(vehicle.class, 0, 'native class is resolved server-side')
H.equal(V.validate(7, 'trunk', 102), nil, 'non-vehicle entity is rejected')
entities[101].bucket = 2
H.equal(V.validate(7, 'trunk', 101), nil, 'routing bucket is enforced')
entities[101].bucket = 1
entities[101].coords = { x = 20, y = 0, z = 0 }
H.equal(V.validate(7, 'trunk', 101), nil, 'server distance is enforced')
entities[101].coords = { x = 1, y = 0, z = 0 }
local descriptor = assert(V.resolve(7, 'trunk', 101))
H.equal(descriptor.key, 'trunk:AB 12', 'resolve derives storage key after validation')
H.ok(type(descriptor.options.access) == 'function', 'descriptor holds live revalidation policy')
local deny = V.registerAccess(function() return false, 'locked' end, { plate = 'AB 12' })
H.equal(V.validate(7, 'trunk', 101), nil, 'server hook can deny access')
H.ok(V.removeAccess(deny), 'server hook can be removed')
H.ok(V.validate(7, 'trunk', 101), 'removed hook no longer denies')
H.finish()
