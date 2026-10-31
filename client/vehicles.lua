-- Vehicle storage entry point for the inventory key.
--
-- This file only decides WHICH vehicle storage the player is asking for and
-- forwards that intent (a network id) through client.lua's validated transport.
-- The server resolves the plate, class, capacity, lock state and distance
-- itself before it creates or opens anything (see server/vehicles.lua).
--
-- Seated in a vehicle -> glovebox. On foot at the boot of a vehicle -> trunk,
-- where the boot is the front for the rear/mid-engine models listed in
-- Config.qbinventory.vehicles.frontBootModels. client/compat.lua calls tryOpen()
-- from the inventory key before it falls back to the player's own inventory.

QbInventory = QbInventory or {}
local vehicleStorage = {}
QbInventory.vehicleStorage = vehicleStorage

-- Ignore key repeats while a request is in flight.
local REQUEST_COOLDOWN_MS = 750
-- Vehicles further than this from the player cannot have a boot within reach.
local SEARCH_RADIUS = 12.0
-- Boot position sits this far beyond the bumper, so it is reachable from outside.
local BOOT_OUTSET = 0.3
local lastRequest = -REQUEST_COOLDOWN_MS

local function settings()
    return (Config.qbinventory and Config.qbinventory.vehicles) or {}
end

local function notify(message)
    QB.notify.send({ title = 'Vehicle', message = message, type = 'error' })
end

local function listHas(list, wanted)
    for _, value in ipairs(type(list) == 'table' and list or {}) do
        if tonumber(value) == wanted then
            return true
        end
    end
    return false
end

local function hasFrontBoot(model, list)
    for _, name in ipairs(type(list) == 'table' and list or {}) do
        if type(name) == 'string' and GetHashKey(name:lower()) == model then
            return true
        end
    end
    return false
end

---Lock state as kora_vehiclekeys publishes it, falling back to the native
---door lock status for vehicles it does not manage (parked traffic).
local function isLocked(vehicle)
    local state = Entity(vehicle).state['qbvehiclekeys:locked']
    if type(state) == 'boolean' then
        return state
    end
    return (tonumber(GetVehicleDoorLockStatus(vehicle)) or 0) >= 2
end

---World position of the boot of a vehicle, from its model dimensions.
function vehicleStorage.bootPosition(vehicle, cfg)
    cfg = cfg or settings()
    local model = GetEntityModel(vehicle)
    local minimum, maximum = GetModelDimensions(model)
    local offset = hasFrontBoot(model, cfg.frontBootModels) and (maximum.y + BOOT_OUTSET) or (minimum.y - BOOT_OUTSET)
    return GetOffsetFromEntityInWorldCoords(vehicle, 0.0, offset, 0.0)
end

---Nearest vehicle whose boot is within reach of the player on foot.
function vehicleStorage.findBootVehicle(coords, cfg)
    cfg = cfg or settings()
    local reach = tonumber(cfg.bootReach) or 1.8
    local best, bestDistance
    for _, vehicle in ipairs(GetGamePool('CVehicle')) do
        local origin = GetEntityCoords(vehicle)
        local dx, dy = origin.x - coords.x, origin.y - coords.y
        if dx * dx + dy * dy <= SEARCH_RADIUS * SEARCH_RADIUS
            and not listHas(cfg.bootSkipClasses, GetVehicleClass(vehicle)) then
            local boot = vehicleStorage.bootPosition(vehicle, cfg)
            local bx, by = boot.x - coords.x, boot.y - coords.y
            local distance = math.sqrt(bx * bx + by * by)
            if distance <= reach and math.abs(boot.z - coords.z) <= 2.5
                and (not bestDistance or distance < bestDistance) then
                best, bestDistance = vehicle, distance
            end
        end
    end
    return best
end

local function request(kind, vehicle)
    if not NetworkGetEntityIsNetworked(vehicle) then
        notify('This vehicle has no storage you can open.')
        return true
    end
    lastRequest = GetGameTimer()
    QbInventory.clientApi.openInventory(kind, NetworkGetNetworkIdFromEntity(vehicle))
    return true
end

---Handle the inventory key for vehicle storage.
---@return boolean handled true when a vehicle inventory was requested (the
---caller must not also open the player's own inventory).
function vehicleStorage.tryOpen()
    local cfg = settings()
    local api = QbInventory.clientApi
    if cfg.enabled == false or not api or api.getCurrentSession() or LocalPlayer.state.inv_busy then
        return false
    end
    if GetGameTimer() - lastRequest < REQUEST_COOLDOWN_MS then
        return true
    end

    local seated = QB.cache.vehicle()
    if seated and seated ~= 0 then
        if cfg.gloveboxEnabled == false then
            return false
        end
        return request('glovebox', seated)
    end

    if cfg.trunkEnabled == false then
        return false
    end
    local vehicle = vehicleStorage.findBootVehicle(QB.cache.coords(), cfg)
    if not vehicle then
        return false
    end
    if cfg.respectLocks ~= false and isLocked(vehicle) then
        notify('This vehicle is locked.')
        return false
    end
    return request('trunk', vehicle)
end

return vehicleStorage
