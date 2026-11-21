local inventory = KoraInventory
local stateKey = 'kora_inventory:trunkCargo'
local resource = GetCurrentResourceName()
local states, stopped, building = {}, false, false
local maxPacketItems = 24
local staticBones = { 'wheel_lr', 'wheel_rr', 'seat_dside_r', 'seat_pside_r', 'wheel_lf', 'wheel_rf' }

local function integer(value, min, max)
    return type(value) == 'number' and value >= min and value <= max and value % 1 == 0
end

local function settings()
    local vehicles = Config.kora_inventory.vehicles
    local cfg = vehicles and vehicles.trunkCargo
    if not stopped and cfg and cfg.enabled == true then return cfg, vehicles end
end

local function modelHash(model)
    if type(model) == 'string' then model = joaat(model) end
    if integer(model, -0x80000000, 0xffffffff) and model ~= 0 and IsModelValid(model)
        and not IsModelAVehicle(model) and not IsModelAPed(model) then
        return model
    end
end

local function resolveModel(name, cfg)
    local visual = inventory.cargoVisual(name)
    if not visual then return false end
    if visual.weapon then
        local weapon = joaat(visual.weapon)
        if IsWeaponValid(weapon) then
            local model = modelHash(GetWeapontypeModel(weapon))
            if model then return { model = model, flat = true } end
        end
    else
        local model = modelHash(visual.model)
        if model then return { model = model } end
    end
    local fallback = modelHash(cfg.fallbackModel)
    return fallback and { model = fallback } or false
end

local function inRange(vehicle, origin, cfg)
    if not origin or not DoesEntityExist(vehicle) or not NetworkGetEntityIsNetworked(vehicle) then return false end
    local point = GetEntityCoords(vehicle)
    local dx, dy, dz = origin.x - point.x, origin.y - point.y, origin.z - point.z
    local distance = tonumber(cfg.drawDistance) or 35
    return distance > 0 and dx * dx + dy * dy + dz * dz <= distance * distance
end

local function snapshot(vehicle, cfg, vehicles, visuals)
    local packet = Entity(vehicle).state[stateKey]
    if type(packet) ~= 'table'
        or not integer(packet.model, -0x80000000, 0xffffffff)
        or not integer(packet.bucket, 0, 0x7fffffff)
        or not integer(packet.revision, 0, 0x7fffffffffffffff)
        or type(packet.plate) ~= 'string' or #packet.plate > 32
        or type(packet.items) ~= 'table' then return end

    local model = GetEntityModel(vehicle)
    local maxPlate = math.max(1, math.floor(tonumber(vehicles.plateMaxLength) or 8))
    local plate = Kora.vehicle.normalizePlate(GetVehicleNumberPlateText(vehicle), { maxLength = maxPlate })
    local netId = NetworkGetNetworkIdFromEntity(vehicle)
    if not integer(netId, 1, 65535) or (packet.model & 0xffffffff) ~= (model & 0xffffffff)
        or not plate or packet.plate ~= plate then return end

    local limit = math.min(maxPacketItems, cfg.maxProps or maxPacketItems)
    local rows, seen = {}, {}
    for index, item in pairs(packet.items) do
        if not integer(index, 1, limit) or type(item) ~= 'table' or not integer(item.slot, 1, 65535)
            or type(item.name) ~= 'string' or #item.name == 0 or #item.name > 96
            or seen[item.slot] then return end
        seen[item.slot] = true
        rows[#rows + 1] = { slot = item.slot, name = item.name }
    end
    if #rows == 0 then return end
    table.sort(rows, function(a, b) return a.slot < b.slot end)

    local signature = { netId, model, plate, packet.bucket, packet.revision, cfg.fallbackModel or '' }
    local entries = {}
    for _, item in ipairs(rows) do
        local visual = visuals[item.name]
        if visual == nil then
            visual = resolveModel(item.name, cfg)
            visuals[item.name] = visual
        end
        if visual then
            entries[#entries + 1] = { slot = item.slot, model = visual.model, flat = visual.flat }
            signature[#signature + 1] = ('%d:%d:%d'):format(item.slot, visual.model, visual.flat and 1 or 0)
        end
    end
    if #entries == 0 then return end
    return { vehicle = vehicle, model = model, signature = table.concat(signature, '|'), entries = entries, props = {} }
end

local function clear(vehicle)
    local entry = states[vehicle]
    if not entry then return end
    states[vehicle] = nil
    for _, entity in ipairs(entry.props) do
        if DoesEntityExist(entity) then DeleteEntity(entity) end
    end
end

local function current(entry)
    local cfg = settings()
    return cfg and states[entry.vehicle] == entry and not entry.dirty
        and inRange(entry.vehicle, Kora.cache.coords(), cfg)
end

local function volumeFor(vehicle, model, cfg, vehicles)
    local bounds
    for name, override in pairs(cfg.bounds or {}) do
        if type(name) == 'string' and (joaat(name) & 0xffffffff) == (model & 0xffffffff) then
            bounds = override
            break
        end
    end
    local bones = {}
    for _, name in ipairs(staticBones) do
        local index = GetEntityBoneIndexByName(vehicle, name)
        if index >= 0 then
            local point = GetWorldPositionOfEntityBone(vehicle, index)
            bones[name] = GetOffsetFromEntityGivenWorldCoords(vehicle, point.x, point.y, point.z)
        end
    end
    local min, max = GetModelDimensions(model)
    return inventory.cargoBounds(min, max, inventory.vehicleStorage.hasFrontBoot(vehicle, vehicles), bounds, bones)
end

local function loadModel(model, entry, assets)
    if not model then return false end
    if assets[model] == nil then
        assets[model] = Kora.stream.loadModel(model, nil, {
            timeout = 1500,
            shouldContinue = function() return current(entry) end,
        }) or false
    end
    return assets[model]
end

local function build(entry, assets)
    local cfg, vehicles = settings()
    if not current(entry) then return false end
    local vehicle = entry.vehicle
    local volume = volumeFor(vehicle, entry.model, cfg, vehicles)
    if not volume then return true end
    local geometry = {}
    for _, item in ipairs(entry.entries) do
        local model = loadModel(item.model, entry, assets)
        if not current(entry) then return false end
        local flat = item.flat
        if not model then
            model = loadModel(modelHash(cfg.fallbackModel), entry, assets)
            flat = false
            if not current(entry) then return false end
        end
        if model then
            local min, max = GetModelDimensions(model)
            geometry[#geometry + 1] = { slot = item.slot, model = model, min = min, max = max, flat = flat }
        end
    end
    -- A bag or vehicle can change while asset streaming yields, even before the next scan.
    local latest = snapshot(vehicle, cfg, vehicles, {})
    if not latest or latest.signature ~= entry.signature then return false end

    local poses = inventory.cargoLayout(volume, geometry)
    local origin = GetEntityCoords(vehicle)
    for _, item in ipairs(geometry) do
        local pose = poses[item.slot]
        if pose then
            local prop = CreateObjectNoOffset(item.model, origin.x, origin.y, origin.z - 50.0, false, false, false)
            if prop and prop ~= 0 and DoesEntityExist(prop) then
                entry.props[#entry.props + 1] = prop
                SetEntityVisible(prop, false, false)
                SetEntityAsMissionEntity(prop, true, true)
                SetEntityCollision(prop, false, false)
                SetEntityCompletelyDisableCollision(prop, false, false)
                FreezeEntityPosition(prop, true)
                SetEntityInvincible(prop, true)
                local pos, rot = pose.pos, pose.rot
                AttachEntityToEntity(prop, vehicle, 0, pos.x, pos.y, pos.z, rot.x, rot.y, rot.z,
                    false, false, false, true, 0, true)
                SetEntityVisible(prop, true, false)
            end
        end
    end
    return true
end

local function buildPending()
    if building then return end
    building = true
    CreateThread(function()
        while not stopped do
            local pending
            for _, entry in pairs(states) do
                if not entry.status then pending = entry break end
            end
            if not pending then break end
            pending.status = 'building'
            local assets = {}
            local ok, built = pcall(build, pending, assets)
            for _, model in pairs(assets) do
                if model then SetModelAsNoLongerNeeded(model) end
            end
            if not ok and states[pending.vehicle] == pending then
                clear(pending.vehicle)
                Kora.logging.warn('vehicles.trunk_cargo_render_failed', 'Could not render trunk cargo', { error = tostring(built) })
            end
            pending.status = ok and built and 'ready' or 'waiting'
        end
        building = false
    end)
end

local function scan()
    local cfg, vehicles = settings()
    local seen, visuals = {}, {}
    if cfg then
        local origin = Kora.cache.coords()
        for _, vehicle in ipairs(GetGamePool('CVehicle')) do
            if inRange(vehicle, origin, cfg) then
                local nextState = snapshot(vehicle, cfg, vehicles, visuals)
                if nextState then
                    seen[vehicle] = true
                    local previous = states[vehicle]
                    if previous and previous.signature == nextState.signature then
                        previous.dirty = nil
                        if previous.status == 'waiting' then previous.status = nil end
                    else
                        clear(vehicle)
                        states[vehicle] = nextState
                    end
                end
            end
        end
    end
    for vehicle in pairs(states) do
        if not seen[vehicle] then clear(vehicle) end
    end
    if next(states) then buildPending() end
end

Kora.state.onChange(stateKey, nil, function(context)
    local entry = states[context.entity]
    if entry then entry.dirty = true end
end)

AddEventHandler('onClientResourceStop', function(name)
    if name ~= resource and name ~= 'kora_lib' then return end
    stopped = true
    for vehicle in pairs(states) do clear(vehicle) end
end)

CreateThread(function()
    while not stopped do
        scan()
        Wait(500)
    end
end)
