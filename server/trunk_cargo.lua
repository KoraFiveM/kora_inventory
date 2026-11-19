-- Cosmetic projection of already-loaded trunks. It never opens or changes inventory.
local inventory = KoraInventory
local internal, vehicles = inventory.internal, inventory.vehicles
local stateKey = 'kora_inventory:trunkCargo'
local cargo = {}
inventory.trunkCargo = cargo

local bindings, published = {}, {}
local stopped = false

local function integer(value, minimum)
    return type(value) == 'number' and value % 1 == 0 and value >= minimum
end

local function settings()
    return Config.kora_inventory.vehicles.trunkCargo
end

local function sameVehicle(a, b)
    return a and b and a.entity == b.entity and a.netId == b.netId
        and a.plate == b.plate and a.model == b.model and a.bucket == b.bucket
end

local function identity(entity)
    if not integer(entity, 1) or not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then return end
    local netId = NetworkGetNetworkIdFromEntity(entity)
    if not integer(netId, 1) or NetworkGetEntityFromNetworkId(netId) ~= entity then return end
    local plate = vehicles.normalisePlate(GetVehicleNumberPlateText(entity))
    local model, bucket = GetEntityModel(entity), GetEntityRoutingBucket(entity)
    if not plate or not integer(model, -2147483648) or model == 0 or model > 4294967295 or not integer(bucket, 0) then
        return
    end
    return { entity = entity, netId = netId, plate = plate, model = model, bucket = bucket }
end

local function setState(entity, value)
    local ok, written = pcall(function()
        if not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then return false end
        Entity(entity).state:set(stateKey, value, true)
        return true
    end)
    return ok and written
end

local function clear(key)
    local current = published[key]
    if not current then return end
    setState(current.vehicle.entity, false)
    published[key] = nil
end

local function clearAll()
    for key in pairs(published) do clear(key) end
    bindings = {}
end

-- A validated open may select one specific vehicle when plates collide.
function cargo.bind(descriptor)
    local cfg = settings()
    if stopped or type(cfg) ~= 'table' or cfg.enabled ~= true or descriptor.type ~= 'trunk' then return end
    local opened = descriptor.vehicle
    local vehicle = identity(opened.entity)
    if not vehicle or vehicle.netId ~= opened.netId or vehicle.plate ~= descriptor.id then return end
    local key = 'trunk:' .. vehicle.plate
    if descriptor.key ~= key then return end
    if published[key] and not sameVehicle(published[key].vehicle, vehicle) then clear(key) end
    bindings[key] = vehicle
end

local function candidate(entity)
    local vehicle = identity(entity)
    if not vehicle then return end
    local key = 'trunk:' .. vehicle.plate
    local inv = internal.getInventory(key)
    if not inv or inv.type ~= 'trunk' or inv.id ~= vehicle.plate then return end
    local class = vehicles.modelClass(vehicle.model)
    if class == nil and Config.kora_inventory.vehicles.unknownClassFallback == false then return end
    if not vehicles.capacity('trunk', class) then return end
    return key, vehicle
end

local function collectTargets()
    local candidates = {}
    for _, entity in ipairs(GetAllVehicles()) do
        local ok, key, vehicle = pcall(candidate, entity)
        if ok and key then
            local group = candidates[key]
            if not group then
                group = {}
                candidates[key] = group
            end
            group[entity] = vehicle
        end
    end

    local targets = {}
    for key, bound in pairs(bindings) do
        local group = candidates[key]
        local vehicle = group and group[bound.entity]
        if sameVehicle(bound, vehicle) then
            targets[key] = vehicle
        else
            bindings[key] = nil
        end
        -- A changed binding is cleared this pass before another entity can claim it.
        candidates[key] = nil
    end
    for key, group in pairs(candidates) do
        local entity, vehicle = next(group)
        if not next(group, entity) then targets[key] = vehicle end
    end
    return targets
end

local function snapshot(inv, vehicle, maximum, visible)
    if not inv or inv.type ~= 'trunk' or inv.id ~= vehicle.plate or inv.blocked
        or (inv.bucket ~= nil and inv.bucket ~= vehicle.bucket) or type(inv.items) ~= 'table'
        or not integer(inv.slots, 1) or not integer(inv.revision, 0) then return end

    local slots = {}
    for slot, item in pairs(inv.items) do
        if integer(slot, 1) and slot <= inv.slots and type(item) == 'table' and integer(item.amount, 1)
            and type(item.name) == 'string' and item.name == item.name:lower() then
            slots[#slots + 1] = slot
        end
    end
    table.sort(slots)

    local items = {}
    for _, slot in ipairs(slots) do
        local name = inv.items[slot].name
        if visible[name] == nil then
            local ok, visual = pcall(inventory.cargoVisual, name)
            visible[name] = ok and type(visual) == 'table'
        end
        if visible[name] then
            items[#items + 1] = { slot = slot, name = name }
            if #items == maximum then break end
        end
    end
    if #items == 0 then return end
    return { plate = vehicle.plate, model = vehicle.model, bucket = vehicle.bucket, revision = inv.revision, items = items }
end

local function reconcile(key, vehicle, maximum, visible)
    local ok, packet = internal.lock({ key }, function()
        return true, snapshot(internal.getInventory(key), vehicle, maximum, visible)
    end)
    if not ok or stopped then return end
    if not packet or not sameVehicle(vehicle, identity(vehicle.entity)) then
        clear(key)
        return
    end

    local fingerprint = json.encode(packet)
    local previous = published[key]
    if (not previous or previous.fingerprint ~= fingerprint) and setState(vehicle.entity, packet) then
        published[key] = { vehicle = vehicle, fingerprint = fingerprint }
    end
end

local function poll()
    local cfg = settings()
    if type(cfg) ~= 'table' or cfg.enabled ~= true then
        clearAll()
        return
    end

    local maximum = integer(cfg.maxProps, 1) and math.min(cfg.maxProps, 24) or 24
    local targets, visible = collectTargets(), {}
    for key, current in pairs(published) do
        if not sameVehicle(current.vehicle, targets[key]) then clear(key) end
    end
    for key, vehicle in pairs(targets) do
        pcall(reconcile, key, vehicle, maximum, visible)
    end
end

local resource = GetCurrentResourceName()
AddEventHandler('onResourceStop', function(name)
    if name == resource or name == 'kora_core' or name == 'kora_lib' then
        stopped = true
        clearAll()
    end
end)

CreateThread(function()
    while not stopped do
        poll()
        Wait(1000)
    end
end)
