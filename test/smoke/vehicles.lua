local H = dofile('test/harness.lua')

Config = { kora_inventory = {} }
dofile('config.lua')
dofile('shared.lua')

Kora = { vehicle = {}, world = {}, lookup = {}, util = { deepClone = function(value)
    local seen = {}
    local function clone(v)
        if type(v) ~= 'table' then return v end
        if seen[v] then return seen[v] end
        local copy = {}
        seen[v] = copy
        for k, vv in pairs(v) do copy[clone(k)] = clone(vv) end
        return copy
    end
    return clone(value)
end } }
function Kora.vehicle.normalizePlate(value, options)
    if type(value) ~= 'string' then return nil, 'invalid_type' end
    local plate = value:match('^%s*(.-)%s*$'):upper():gsub('%s+', ' ')
    if plate == '' then return nil, 'empty' end
    if #plate > options.maxLength then return nil, 'too_long' end
    if not plate:match('^[A-Z0-9 ]+$') then return nil, 'invalid_characters' end
    return plate
end
function Kora.world.resolveNetworkEntity(src, networkId, options)
    if type(networkId) ~= 'number' or networkId < 1 then return nil, 'invalid_network_id' end
    local entity = NetworkGetEntityFromNetworkId(networkId)
    if entity == 0 or not DoesEntityExist(entity) then return nil, 'entity_unavailable' end
    if GetEntityType(entity) ~= 2 then return nil, 'wrong_entity_type' end
    local ped = GetPlayerPed(src)
    if ped == 0 or not DoesEntityExist(ped) then return nil, 'player_unavailable' end
    if options.sameBucket and GetPlayerRoutingBucket(src) ~= GetEntityRoutingBucket(entity) then
        return nil, 'routing_bucket_mismatch'
    end
    local a, b = GetEntityCoords(ped), GetEntityCoords(entity)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    if math.sqrt(dx * dx + dy * dy + dz * dz) > options.maxDistance then return nil, 'too_far' end
    return entity
end

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
GetVehicleClass = nil
GetEntityModel = function(entity) return entity end
Kora.lookup.get = function(ns, model) assert(ns == 'vehicle'); return { metadata = { class = entities[model].class } } end

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
H.equal(vehicle.class, 0, 'class comes from server model metadata')
entities[101].class = 'compact'
H.equal(assert(V.validate(7, 'trunk', 101)).class, 0, 'streamed class names are supported')
entities[101].class = 'sports'
H.equal(assert(V.validate(7, 'trunk', 101)).class, 6, 'documented lookup class overrides are supported')
entities[101].class = 'MOTORCYCLE'
H.equal(V.validate(7, 'trunk', 101), nil, 'model class still enforces disabled storage')
entities[101].class = 'unknown'
H.equal(assert(V.validate(7, 'trunk', 101)).slots, 50, 'unknown model classes use the default capacity row')
Config.kora_inventory.vehicles.unknownClassFallback = false
H.equal(V.validate(7, 'trunk', 101), nil, 'unknownClassFallback = false refuses unknown classes')
Config.kora_inventory.vehicles.unknownClassFallback = true
local realGet, printed = Kora.lookup.get, 0
local realPrint = print
print = function() printed = printed + 1 end
Kora.lookup.get = function() error('No such export lookup_get in resource kora_lib') end
H.equal(assert(V.validate(7, 'glovebox', 101)).slots, 8, 'a failing lookup falls back to the default glovebox')
V.validate(7, 'trunk', 101); V.validate(7, 'trunk', 101)
print = realPrint
Kora.lookup.get = realGet

-- The glovebox is reached from a seat, never from outside the vehicle.
local seatedIn = 0
GetVehiclePedIsIn = function() return seatedIn end
local refusedGlovebox, gloveboxWhy = V.validate(7, 'glovebox', 101)
H.equal(refusedGlovebox, nil, 'a player on foot cannot open the glovebox')
H.equal(gloveboxWhy, 'you must be inside the vehicle', 'with the seat reason')
seatedIn = 101
H.ok(V.validate(7, 'glovebox', 101), 'a seated player opens the glovebox')
H.ok(V.validate(7, 'trunk', 101), 'the trunk does not need a seat')
seatedIn = 0
Config.kora_inventory.vehicles.gloveboxRequireSeated = false
H.ok(V.validate(7, 'glovebox', 101), 'gloveboxRequireSeated = false restores the distance-only rule')
Config.kora_inventory.vehicles.gloveboxRequireSeated = nil
GetVehiclePedIsIn = nil
Kora.lookup.get = function() error('No such export lookup_get in resource kora_lib') end
H.equal(printed, 1, 'a failing lookup is logged once per model')
Kora.lookup.get = realGet
entities[101].class = 0
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
