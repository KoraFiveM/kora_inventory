-- Server-only vehicle inventory domain.
-- A network id is an intent only: this module derives the plate, class,
-- coordinates and final trunk/glovebox key from the live server entity.

QbInventory = QbInventory or {}
local inventory = QbInventory
local vehicles = {}
inventory.vehicles = vehicles

local vehicleConfig = (Config.qbinventory and Config.qbinventory.vehicles) or {}
local accessHooks, nextHookId = {}, 1
-- Lookup metadata uses GTA's vehicleClass names (including streamed addons).
local vehicleClasses = {
    COMPACT = 0, SEDAN = 1, SUV = 2, COUPE = 3, MUSCLE = 4,
    SPORT_CLASSIC = 5, SPORT = 6, SPORTS = 6, SUPER = 7, MOTORCYCLE = 8,
    OFF_ROAD = 9, INDUSTRIAL = 10, UTILITY = 11, VAN = 12, CYCLE = 13,
    BOAT = 14, HELICOPTER = 15, PLANE = 16, SERVICE = 17, EMERGENCY = 18,
    MILITARY = 19, COMMERCIAL = 20, RAIL = 21, OPEN_WHEEL = 22,
}

local function asInteger(value)
    local number = tonumber(value)
    if not number or number % 1 ~= 0 then
        return nil
    end
    return number
end

local function storageKind(kind)
    return kind == 'trunk' or kind == 'glovebox'
end

local function accessDistance(kind)
    if kind == 'trunk' and tonumber(vehicleConfig.trunkDistance) then
        -- The boot is at the far end of the vehicle, not at its origin.
        return tonumber(vehicleConfig.trunkDistance)
    end
    return tonumber(vehicleConfig.distance)
        or tonumber(Config.qbinventory and Config.qbinventory.interactionDistance)
        or 3.0
end

local function invokingResource()
    return type(GetInvokingResource) == 'function' and GetInvokingResource() or nil
end

local function coordsDistance(a, b)
    if not a or not b then
        return nil
    end
    local ax, ay, az = tonumber(a.x), tonumber(a.y), tonumber(a.z)
    local bx, by, bz = tonumber(b.x), tonumber(b.y), tonumber(b.z)
    if not ax or not ay or not az or not bx or not by or not bz then
        return nil
    end
    local x, y, z = ax - bx, ay - by, az - bz
    return math.sqrt(x * x + y * y + z * z)
end

local function invokeAccessCallback(callback, src, vehicle)
    local ok, allowed, reason = pcall(callback, src, inventory.copy(vehicle))
    if not ok then
        print(('^3[qbinventory:vehicles]^7 vehicle access callback failed: %s'):format(tostring(allowed)))
        return false, 'vehicle access check failed'
    end
    if allowed == false then
        return false, reason or 'vehicle access denied'
    end
    return true
end

local function matchesAccessHook(hook, vehicle)
    local options = hook.options
    if options.kind and options.kind ~= vehicle.kind then
        return false
    end
    if options.class and tonumber(options.class) ~= vehicle.class then
        return false
    end
    if options.plate and vehicles.normalisePlate(options.plate) ~= vehicle.plate then
        return false
    end
    return true
end

---Trim native padding, canonicalise whitespace and disallow key separators.
---@return string|nil, string|nil
function vehicles.normalisePlate(value)
    local maximum = math.max(1, math.floor(tonumber(vehicleConfig.plateMaxLength) or 8))
    local plate = Kora.vehicle.normalizePlate(value, { maxLength = maximum })
    if not plate then return nil, 'invalid vehicle plate' end
    return plate
end

function vehicles.inventoryKey(kind, plate)
    if not storageKind(kind) then
        return nil, 'invalid vehicle storage type'
    end
    local normalised, err = vehicles.normalisePlate(plate)
    if not normalised then
        return nil, err
    end
    return ('%s:%s'):format(kind, normalised)
end

---Lock state: kora_vehiclekeys publishes a boolean state bag; vehicles it does
---not manage (parked traffic) fall back to the native door lock status.
local function isLocked(entity)
    if type(Entity) == 'function' then
        local ok, state = pcall(function() return Entity(entity).state['qbvehiclekeys:locked'] end)
        if ok and type(state) == 'boolean' then
            return state
        end
    end
    if type(GetVehicleDoorLockStatus) == 'function' then
        return (tonumber(GetVehicleDoorLockStatus(entity)) or 0) >= 2
    end
    return false
end

local warnedModels = {}

---Resolve a model hash to its GTA vehicle class through kora_lib's lookup.
---Never raises: a missing/failed lookup yields nil (logged once per model) and
---the caller falls back to the default capacity row.
function vehicles.modelClass(model)
    local ok, record = pcall(function()
        return Kora.lookup.get('vehicle', model)
    end)
    if not ok then
        if not warnedModels[model] then
            warnedModels[model] = true
            print(('[kora_inventory] vehicle class lookup failed for model %s, using default capacity: %s')
                :format(tostring(model), tostring(record)))
        end
        return nil
    end
    local metadataClass = type(record) == 'table' and type(record.metadata) == 'table' and record.metadata.class
    return asInteger(metadataClass)
        or (type(metadataClass) == 'string' and vehicleClasses[metadataClass:upper()] or nil)
end

---Find the capacity policy for a server-resolved GTA vehicle class.
function vehicles.capacity(kind, class)
    if not storageKind(kind) then
        return nil, 'invalid vehicle storage type'
    end
    class = asInteger(class)
    if class ~= nil and class < 0 then
        return nil, 'invalid vehicle class'
    end
    -- An unresolved class (nil) uses the `default` row of the class table.
    local row = (class ~= nil and (vehicleConfig.classes or {})[class]) or (vehicleConfig.classes or {}).default or {}
    local capacity = row[kind]
    if capacity == false or capacity == nil then
        return nil, 'vehicle storage unavailable'
    end
    local slots = math.floor(tonumber(capacity.slots) or 0)
    local maxWeight = math.floor(tonumber(capacity.maxWeight or capacity.maxweight) or 0)
    if slots < 1 or maxWeight < 0 then
        return nil, 'invalid vehicle capacity configuration'
    end
    return { slots = slots, maxWeight = maxWeight }
end

---Register a trusted, resource-owned server access callback.
function vehicles.registerAccess(callbackFn, options)
    assert(inventory.isCallable(callbackFn), 'vehicle access callback is required')
    options = options or {}
    if options.kind then
        assert(storageKind(options.kind), 'invalid vehicle storage type')
    end
    if options.class ~= nil then
        assert(asInteger(options.class) ~= nil, 'invalid vehicle class')
    end
    if options.plate then
        assert(vehicles.normalisePlate(options.plate), 'invalid vehicle plate')
    end
    local id = nextHookId
    nextHookId = nextHookId + 1
    accessHooks[id] = { id = id, callback = callbackFn, options = inventory.copy(options), owner = invokingResource() }
    return id
end

function vehicles.removeAccess(id)
    id = asInteger(id)
    if not id or not accessHooks[id] then
        return false
    end
    local hook, caller = accessHooks[id], invokingResource()
    if caller and hook.owner and caller ~= hook.owner then
        return false, 'not hook owner'
    end
    accessHooks[id] = nil
    return true
end

function vehicles.cleanupResource(name)
    for id, hook in pairs(accessHooks) do
        if hook.owner == name then
            accessHooks[id] = nil
        end
    end
end

function vehicles.authorise(src, vehicle)
    if type(src) ~= 'number' or type(vehicle) ~= 'table' then
        return false, 'invalid vehicle access request'
    end
    for _, check in ipairs({ vehicleConfig.ownerCheck, vehicleConfig.accessCheck }) do
        if inventory.isCallable(check) then
            local ok, reason = invokeAccessCallback(check, src, vehicle)
            if not ok then
                return false, reason
            end
        end
    end
    for _, hook in pairs(accessHooks) do
        if matchesAccessHook(hook, vehicle) then
            local ok, reason = invokeAccessCallback(hook.callback, src, vehicle)
            if not ok then
                return false, reason
            end
        end
    end
    return true
end

---Validate a live server vehicle. expectedPlate is used only by the internal
---revalidation closure, never accepted as an open request field.
function vehicles.validate(src, kind, networkId, expectedPlate)
    if not storageKind(kind) then
        return nil, 'invalid vehicle storage type'
    end
    networkId = asInteger(networkId)
    local entity, reason = Kora.world.resolveNetworkEntity(src, networkId, {
        entityType = 'vehicle',
        maxDistance = accessDistance(kind),
        sameBucket = vehicleConfig.requireSameBucket ~= false,
    })
    if not entity then
        if reason == 'invalid_network_id' then return nil, 'invalid vehicle entity' end
        if reason == 'wrong_entity_type' then return nil, 'entity is not a vehicle' end
        if reason == 'player_unavailable' then return nil, 'player entity unavailable' end
        if reason == 'routing_bucket_mismatch' then return nil, 'different routing bucket' end
        if reason == 'too_far' then return nil, 'too far away' end
        return nil, 'vehicle does not exist'
    end
    local ped = GetPlayerPed(src)
    local playerCoords, vehicleCoords = GetEntityCoords(ped), GetEntityCoords(entity)
    local separation = coordsDistance(playerCoords, vehicleCoords)
    if not separation then
        return nil, 'vehicle coordinates unavailable'
    end
    if type(GetVehicleNumberPlateText) ~= 'function' or type(GetEntityModel) ~= 'function' then
        return nil, 'vehicle details unavailable'
    end
    local plate, plateErr = vehicles.normalisePlate(GetVehicleNumberPlateText(entity))
    if not plate then
        return nil, plateErr
    end
    if expectedPlate and plate ~= expectedPlate then
        return nil, 'vehicle changed'
    end
    local class = vehicles.modelClass(GetEntityModel(entity))
    if class == nil and vehicleConfig.unknownClassFallback == false then
        return nil, 'invalid vehicle class'
    end
    local capacity, capacityErr = vehicles.capacity(kind, class)
    if not capacity then
        return nil, capacityErr
    end
    if kind == 'trunk' and vehicleConfig.respectLocks ~= false and isLocked(entity) then
        return nil, 'vehicle is locked'
    end
    local vehicle = {
        entity = entity,
        netId = networkId,
        plate = plate,
        class = class,
        kind = kind,
        coords = vehicleCoords,
        distance = separation,
        slots = capacity.slots,
        maxWeight = capacity.maxWeight,
    }
    local allowed, accessErr = vehicles.authorise(src, vehicle)
    if not allowed then
        return nil, accessErr
    end
    return vehicle
end

function vehicles.resolve(src, kind, networkId)
    local vehicle, err = vehicles.validate(src, kind, networkId)
    if not vehicle then
        return nil, err
    end
    local inventoryKey = assert(vehicles.inventoryKey(kind, vehicle.plate))
    local options = {
        label = ('%s · %s'):format(kind == 'trunk' and 'Trunk' or 'Glovebox', vehicle.plate),
        slots = vehicle.slots,
        maxWeight = vehicle.maxWeight,
        coords = vehicle.coords,
        distance = accessDistance(kind),
    }
    -- Do not retain trust in a one-time open: every access during a session
    -- revalidates the same native entity and original server-resolved plate.
    options.access = function(requester)
        local current, validationErr = vehicles.validate(requester, kind, vehicle.netId, vehicle.plate)
        return current ~= nil, validationErr
    end
    return { key = inventoryKey, type = kind, id = vehicle.plate, vehicle = vehicle, options = options }
end

---Required server.lua integration target. It never writes player state.
function vehicles.open(src, kind, networkId)
    local descriptor, err = vehicles.resolve(src, kind, networkId)
    if not descriptor then
        return false, err
    end
    local internal = inventory.internal
    if not internal or type(internal.createSecondary) ~= 'function' or type(internal.open) ~= 'function' then
        return false, 'vehicle inventory authority is unavailable'
    end
    local inv = internal.getInventory and internal.getInventory(descriptor.key) or nil
    if inv then
        -- Persisted records need current non-serialisable access policy too.
        inv.label, inv.slots, inv.maxWeight =
            descriptor.options.label, descriptor.options.slots, descriptor.options.maxWeight
        inv.coords, inv.distance, inv.access =
            descriptor.options.coords, descriptor.options.distance, descriptor.options.access
    else
        internal.createSecondary(kind, descriptor.id, descriptor.options)
    end
    return internal.open(src, descriptor.key, descriptor.options)
end

return vehicles
