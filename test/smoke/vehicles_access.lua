-- Run from kora_inventory: lua test/smoke/vehicles_access.lua
-- Real server/vehicles.lua; only GTA natives and the kora_lib world/lookup
-- helpers are faked. Covers the trunk distance and lock policy.
local H = dofile('test/harness.lua')

Config = { kora_inventory = {} }
dofile('config.lua')
dofile('shared.lua')

local Kora = { vehicle = {}, world = {}, lookup = {} }
Kora.vehicle.normalizePlate = function(value) return (tostring(value):gsub('%s+$', '')) end
Kora.world.resolveNetworkEntity = function(src, networkId, options)
    local a, b = GetEntityCoords(1), GetEntityCoords(networkId)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    if math.sqrt(dx * dx + dy * dy + dz * dz) > options.maxDistance then return nil, 'too_far' end
    return networkId
end
Kora.lookup.get = function() return { metadata = { class = 'SUPER' } } end
_G.Kora = Kora

local vehicle = { coords = { x = 5, y = 0, z = 0 }, bag = nil, lock = 0 }
GetPlayerPed = function() return 1 end
GetEntityCoords = function(entity) return entity == 1 and { x = 0, y = 0, z = 0 } or vehicle.coords end
GetVehicleNumberPlateText = function() return 'ADDER01' end
GetEntityModel = function() return 1 end
GetVehicleDoorLockStatus = function() return vehicle.lock end
Entity = function() return { state = { ['kora_vehiclekeys:locked'] = vehicle.bag } } end

local V = dofile('server/vehicles.lua')
local cfg = Config.kora_inventory.vehicles
local function reset()
    vehicle.coords, vehicle.bag, vehicle.lock = { x = 5, y = 0, z = 0 }, nil, 0
    cfg.respectLocks, cfg.trunkDistance, cfg.distance = true, 7.0, 3.0
end

-- Distance: the boot is far from the vehicle origin.
reset()
H.ok(V.validate(7, 'trunk', 2), 'trunk opens 5 m from the origin (boot of a long car)')
H.equal(V.validate(7, 'glovebox', 2), nil, 'glovebox keeps the short interaction distance')
cfg.trunkDistance = 4.0
H.equal(V.validate(7, 'trunk', 2), nil, 'trunkDistance is config driven and read at use time')
reset()
vehicle.coords = { x = 12, y = 0, z = 0 }
H.equal(V.validate(7, 'trunk', 2), nil, 'trunk beyond trunkDistance is refused')
reset()
H.equal(select(1, V.resolve(7, 'trunk', 2)).options.distance, 7.0, 'trunk session distance follows trunkDistance')

-- Locks.
vehicle.bag = true
local refused, reason = V.validate(7, 'trunk', 2)
H.equal(refused, nil, 'keys-locked vehicle refuses the trunk')
H.equal(reason, 'vehicle is locked', 'locked refusal reason')
vehicle.coords = { x = 1, y = 0, z = 0 }
H.ok(V.validate(7, 'glovebox', 2), 'glovebox of a locked vehicle you sit in is not blocked')
reset()
vehicle.lock = 2
H.equal(select(2, V.validate(7, 'trunk', 2)), 'vehicle is locked', 'native lock status locks the trunk')
vehicle.bag = false
H.ok(V.validate(7, 'trunk', 2), 'unlocked keys state wins over a stale native status')
reset()
vehicle.bag = true
cfg.respectLocks = false
H.ok(V.validate(7, 'trunk', 2), 'respectLocks=false allows a locked trunk')
reset()
H.ok(V.validate(7, 'trunk', 2), 'unlocked vehicle opens')
H.finish()
