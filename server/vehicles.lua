-- Server-only vehicle inventory domain.
-- A network id is an intent only: this module derives the plate, class,
-- coordinates and final trunk/glovebox key from the live server entity.

QbInventory = QbInventory or {}
local I = QbInventory
local V = {}
I.vehicles = V

local cfg = (Config.qbinventory and Config.qbinventory.vehicles) or {}
local accessHooks, nextHookId = {}, 1

local function asInteger(value)
    local number = tonumber(value)
    if not number or number % 1 ~= 0 then return nil end
    return number
end

local function storageKind(kind)
    return kind == 'trunk' or kind == 'glovebox'
end

local function distance()
    return tonumber(cfg.distance) or tonumber(Config.qbinventory and Config.qbinventory.interactionDistance) or 3.0
end

local function resource()
    return type(GetInvokingResource) == 'function' and GetInvokingResource() or nil
end

local function coordsDistance(a, b)
    if not a or not b then return nil end
    local ax, ay, az = tonumber(a.x), tonumber(a.y), tonumber(a.z)
    local bx, by, bz = tonumber(b.x), tonumber(b.y), tonumber(b.z)
    if not ax or not ay or not az or not bx or not by or not bz then return nil end
    local x, y, z = ax - bx, ay - by, az - bz
    return math.sqrt(x * x + y * y + z * z)
end

local function callback(callback, src, vehicle)
    local ok, allowed, reason = pcall(callback, src, I.copy(vehicle))
    if not ok then
        print(('^3[qbinventory:vehicles]^7 vehicle access callback failed: %s'):format(tostring(allowed)))
        return false, 'vehicle access check failed'
    end
    if allowed == false then return false, reason or 'vehicle access denied' end
    return true
end

local function matches(hook, vehicle)
    local options = hook.options
    if options.kind and options.kind ~= vehicle.kind then return false end
    if options.class and tonumber(options.class) ~= vehicle.class then return false end
    if options.plate and V.normalisePlate(options.plate) ~= vehicle.plate then return false end
    return true
end

---Trim native padding, canonicalise whitespace and disallow key separators.
---@return string|nil, string|nil
function V.normalisePlate(value)
    if type(value) ~= 'string' then return nil, 'invalid vehicle plate' end
    local plate = value:gsub('^%s*(.-)%s*$', '%1'):upper():gsub('%s+', ' ')
    local maximum = math.max(1, math.floor(tonumber(cfg.plateMaxLength) or 8))
    if plate == '' or #plate > maximum or not plate:match('^[A-Z0-9 ]+$') then
        return nil, 'invalid vehicle plate'
    end
    return plate
end

function V.inventoryKey(kind, plate)
    if not storageKind(kind) then return nil, 'invalid vehicle storage type' end
    local normalised, err = V.normalisePlate(plate)
    if not normalised then return nil, err end
    return ('%s:%s'):format(kind, normalised)
end

---Find the capacity policy for a server-resolved GTA vehicle class.
function V.capacity(kind, class)
    if not storageKind(kind) then return nil, 'invalid vehicle storage type' end
    class = asInteger(class)
    if class == nil or class < 0 then return nil, 'invalid vehicle class' end
    local row = (cfg.classes or {})[class] or (cfg.classes or {}).default or {}
    local capacity = row[kind]
    if capacity == false or capacity == nil then return nil, 'vehicle storage unavailable' end
    local slots = math.floor(tonumber(capacity.slots) or 0)
    local maxWeight = math.floor(tonumber(capacity.maxWeight or capacity.maxweight) or 0)
    if slots < 1 or maxWeight < 0 then return nil, 'invalid vehicle capacity configuration' end
    return { slots = slots, maxWeight = maxWeight }
end

---Register a trusted, resource-owned server access callback.
function V.registerAccess(callbackFn, options)
    assert(type(callbackFn) == 'function', 'vehicle access callback is required')
    options = options or {}
    if options.kind then assert(storageKind(options.kind), 'invalid vehicle storage type') end
    if options.class ~= nil then assert(asInteger(options.class) ~= nil, 'invalid vehicle class') end
    if options.plate then assert(V.normalisePlate(options.plate), 'invalid vehicle plate') end
    local id = nextHookId
    nextHookId = nextHookId + 1
    accessHooks[id] = { id = id, callback = callbackFn, options = I.copy(options), owner = resource() }
    return id
end

function V.removeAccess(id)
    id = asInteger(id)
    if not id or not accessHooks[id] then return false end
    local hook, caller = accessHooks[id], resource()
    if caller and hook.owner and caller ~= hook.owner then return false, 'not hook owner' end
    accessHooks[id] = nil
    return true
end

function V.cleanupResource(name)
    for id, hook in pairs(accessHooks) do if hook.owner == name then accessHooks[id] = nil end end
end

function V.authorise(src, vehicle)
    if type(src) ~= 'number' or type(vehicle) ~= 'table' then return false, 'invalid vehicle access request' end
    for _, check in ipairs({ cfg.ownerCheck, cfg.accessCheck }) do
        if type(check) == 'function' then
            local ok, reason = callback(check, src, vehicle)
            if not ok then return false, reason end
        end
    end
    for _, hook in pairs(accessHooks) do
        if matches(hook, vehicle) then
            local ok, reason = callback(hook.callback, src, vehicle)
            if not ok then return false, reason end
        end
    end
    return true
end

---Validate a live server vehicle. expectedPlate is used only by the internal
---revalidation closure, never accepted as an open request field.
function V.validate(src, kind, networkId, expectedPlate)
    if not storageKind(kind) then return nil, 'invalid vehicle storage type' end
    networkId = asInteger(networkId)
    if not networkId or networkId < 1 or type(NetworkGetEntityFromNetworkId) ~= 'function' then return nil, 'invalid vehicle entity' end
    local entity = NetworkGetEntityFromNetworkId(networkId)
    if not entity or entity == 0 or type(DoesEntityExist) ~= 'function' or not DoesEntityExist(entity) then return nil, 'vehicle does not exist' end
    if type(GetEntityType) ~= 'function' or GetEntityType(entity) ~= 2 then return nil, 'entity is not a vehicle' end
    if type(GetPlayerPed) ~= 'function' or type(GetEntityCoords) ~= 'function' then return nil, 'vehicle validation unavailable' end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return nil, 'player entity unavailable' end
    if cfg.requireSameBucket ~= false then
        if type(GetPlayerRoutingBucket) ~= 'function' or type(GetEntityRoutingBucket) ~= 'function' then return nil, 'routing bucket validation unavailable' end
        if GetPlayerRoutingBucket(src) ~= GetEntityRoutingBucket(entity) then return nil, 'different routing bucket' end
    end
    local playerCoords, vehicleCoords = GetEntityCoords(ped), GetEntityCoords(entity)
    local separation = coordsDistance(playerCoords, vehicleCoords)
    if not separation then return nil, 'vehicle coordinates unavailable' end
    if separation > distance() then return nil, 'too far away' end
    if type(GetVehicleNumberPlateText) ~= 'function' or type(GetVehicleClass) ~= 'function' then return nil, 'vehicle details unavailable' end
    local plate, plateErr = V.normalisePlate(GetVehicleNumberPlateText(entity))
    if not plate then return nil, plateErr end
    if expectedPlate and plate ~= expectedPlate then return nil, 'vehicle changed' end
    local class = asInteger(GetVehicleClass(entity))
    local capacity, capacityErr = V.capacity(kind, class)
    if not capacity then return nil, capacityErr end
    local vehicle = { entity = entity, netId = networkId, plate = plate, class = class, kind = kind,
        coords = vehicleCoords, distance = separation, slots = capacity.slots, maxWeight = capacity.maxWeight }
    local allowed, accessErr = V.authorise(src, vehicle)
    if not allowed then return nil, accessErr end
    return vehicle
end

function V.resolve(src, kind, networkId)
    local vehicle, err = V.validate(src, kind, networkId)
    if not vehicle then return nil, err end
    local inventoryKey = assert(V.inventoryKey(kind, vehicle.plate))
    local options = {
        label = ('%s · %s'):format(kind == 'trunk' and 'Trunk' or 'Glovebox', vehicle.plate),
        slots = vehicle.slots, maxWeight = vehicle.maxWeight, coords = vehicle.coords, distance = distance(),
    }
    -- Do not retain trust in a one-time open: every access during a session
    -- revalidates the same native entity and original server-resolved plate.
    options.access = function(requester)
        local current, validationErr = V.validate(requester, kind, vehicle.netId, vehicle.plate)
        return current ~= nil, validationErr
    end
    return { key = inventoryKey, type = kind, id = vehicle.plate, vehicle = vehicle, options = options }
end

---Required server.lua integration target. It never writes player state.
function V.open(src, kind, networkId)
    local descriptor, err = V.resolve(src, kind, networkId)
    if not descriptor then return false, err end
    local internal = I.internal
    if not internal or type(internal.createSecondary) ~= 'function' or type(internal.open) ~= 'function' then return false, 'vehicle inventory authority is unavailable' end
    local inv = internal.getInventory and internal.getInventory(descriptor.key) or nil
    if inv then
        -- Persisted records need current non-serialisable access policy too.
        inv.label, inv.slots, inv.maxWeight = descriptor.options.label, descriptor.options.slots, descriptor.options.maxWeight
        inv.coords, inv.distance, inv.access = descriptor.options.coords, descriptor.options.distance, descriptor.options.access
    else
        internal.createSecondary(kind, descriptor.id, descriptor.options)
    end
    return internal.open(src, descriptor.key, descriptor.options)
end

return V
