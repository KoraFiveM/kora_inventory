-- Trunk and hood toggles for vehicles: ALT-menu entries (kora_target) shown only
-- while aiming at that end of the vehicle, plus the /trunk and /hood commands
-- for the driver seat. A trunk storage entry sits beside the trunk toggle.
--
-- The trunk is the rear lid, or the front (bonnet) lid for the rear/mid-engine
-- models in Config.qbinventory.vehicles.frontBootModels; the hood is the other
-- lid. Doors are opened after taking network control of the vehicle, so the
-- door state is replicated and every player sees it. Everything is configured
-- in Config.qbinventory.vehicles.doors and read on every use.

QbInventory = QbInventory or {}
local vehicleDoors = {}
QbInventory.vehicleDoors = vehicleDoors

local BONNET_DOOR, BOOT_DOOR = 4, 5
local OPEN_RATIO = 0.1
local CONTROL_WAIT_MS = 750
-- The aimed point must sit inside this fraction of the vehicle half width, so
-- the side panels of the rear/front quarter are not mistaken for the lid.
local CENTRE_FRACTION = 0.8
-- Metres the aimed point may overshoot the end of the model dimensions.
local END_MARGIN = 0.5

local registered = {} -- kora_target registration ids owned by this file
local busy = false

local function vehicleSettings()
    return (Config.qbinventory and Config.qbinventory.vehicles) or {}
end

local function settings()
    local doors = vehicleSettings().doors
    return type(doors) == 'table' and doors or {}
end

local function enabled(key)
    local cfg = settings()
    return cfg.enabled ~= false and cfg[key] ~= false
end

local FALLBACK_TEXT = {
    ['vehicle_doors.title'] = 'Vehicle',
    ['vehicle_doors.trunk_open'] = 'Open trunk',
    ['vehicle_doors.trunk_close'] = 'Close trunk',
    ['vehicle_doors.hood_open'] = 'Open hood',
    ['vehicle_doors.hood_close'] = 'Close hood',
    ['vehicle_doors.trunk_storage'] = 'Trunk storage',
    ['vehicle_doors.locked'] = 'This vehicle is locked.',
    ['vehicle_doors.no_trunk'] = 'This vehicle has no trunk.',
    ['vehicle_doors.no_hood'] = 'This vehicle has no hood.',
    ['vehicle_doors.driver_only'] = 'You must be in the driver seat.',
    ['vehicle_doors.no_control'] = 'Could not reach the vehicle. Try again.',
}

-- Resolved against this resource explicitly: callbacks run from kora_target, so
-- Kora.lang would look the key up in the invoking resource instead.
local function text(key)
    local ok, value = pcall(Kora.locale.translate, GetCurrentResourceName(), key)
    if ok and type(value) == 'string' and value ~= '' and value ~= key then
        return value
    end
    return FALLBACK_TEXT[key] or key
end

local function notify(key, kind)
    Kora.notify.send({ title = text('vehicle_doors.title'), message = text(key), type = kind or 'error' })
end

local function storage()
    return QbInventory.vehicleStorage
end

---Door index of the trunk or hood of this vehicle.
---@param vehicle number
---@param part 'trunk'|'hood'
---@return integer
function vehicleDoors.doorIndex(vehicle, part)
    local frontTrunk = storage().hasFrontBoot(vehicle, vehicleSettings())
    if part == 'trunk' then
        return frontTrunk and BONNET_DOOR or BOOT_DOOR
    end
    return frontTrunk and BOOT_DOOR or BONNET_DOOR
end

---False for vehicles that have no such lid (bikes, boats, many trucks).
function vehicleDoors.hasDoor(vehicle, part)
    return GetIsDoorValid(vehicle, vehicleDoors.doorIndex(vehicle, part)) == true
end

function vehicleDoors.isOpen(vehicle, part)
    return (tonumber(GetVehicleDoorAngleRatio(vehicle, vehicleDoors.doorIndex(vehicle, part))) or 0.0) > OPEN_RATIO
end

---True when the world point lies over the lid of `part`: the end of the vehicle
---(front for the bonnet door, rear for the boot door), near its centre line.
function vehicleDoors.isAimedAt(vehicle, part, point)
    if not (point and point.x) then
        return false
    end
    local front = vehicleDoors.doorIndex(vehicle, part) == BONNET_DOOR
    local depth = tonumber(settings().partDepth) or 1.3
    local minimum, maximum = GetModelDimensions(GetEntityModel(vehicle))
    local at = GetOffsetFromEntityGivenWorldCoords(vehicle, point.x, point.y, point.z)
    if math.abs(at.x) > math.max(-minimum.x, maximum.x) * CENTRE_FRACTION then
        return false
    end
    if front then
        return at.y >= maximum.y - depth and at.y <= maximum.y + END_MARGIN
    end
    return at.y <= minimum.y + depth and at.y >= minimum.y - END_MARGIN
end

local function insideVehicle(vehicle)
    return GetVehiclePedIsIn(PlayerPedId(), false) == vehicle
end

---Open or close a lid for everyone. The network owner replicates door state,
---so control is requested first; without it the change would only show here.
---@return boolean changed
function vehicleDoors.setOpen(vehicle, part, open)
    if not DoesEntityExist(vehicle) then
        return false
    end
    if not Kora.entities.requestControl(vehicle, CONTROL_WAIT_MS) then
        notify('vehicle_doors.no_control')
        return false
    end
    local door = vehicleDoors.doorIndex(vehicle, part)
    if open then
        SetVehicleDoorOpen(vehicle, door, false, false)
    else
        SetVehicleDoorShut(vehicle, door, false)
    end
    return true
end

---Toggle a lid, applying the missing-door and lock rules. Opening from outside
---a locked vehicle is refused when doors.respectLocks is on; closing is always
---allowed, and so is anything done from inside the vehicle.
---@return boolean changed
function vehicleDoors.toggle(vehicle, part)
    if busy or not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        return false
    end
    if not vehicleDoors.hasDoor(vehicle, part) then
        notify(part == 'trunk' and 'vehicle_doors.no_trunk' or 'vehicle_doors.no_hood')
        return false
    end
    local opening = not vehicleDoors.isOpen(vehicle, part)
    if opening and settings().respectLocks ~= false and not insideVehicle(vehicle)
        and storage().isLocked(vehicle) then
        notify('vehicle_doors.locked')
        return false
    end
    busy = true
    local ok, changed = pcall(vehicleDoors.setOpen, vehicle, part, opening)
    busy = false
    return ok and changed or false
end

---/trunk and /hood: driver seat only.
function vehicleDoors.toggleFromDriverSeat(part)
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 or GetPedInVehicleSeat(vehicle, -1) ~= ped then
        notify('vehicle_doors.driver_only')
        return false
    end
    return vehicleDoors.toggle(vehicle, part)
end

local function partOption(part, wantOpen)
    return {
        label = text(('vehicle_doors.%s_%s'):format(part, wantOpen and 'open' or 'close')),
        icon = part == 'trunk' and 'car-rear' or 'car',
        name = ('kora_inventory:%s:%s'):format(part, wantOpen and 'open' or 'close'),
        distance = tonumber(settings().targetDistance) or 3.0,
        canInteract = function(vehicle, _, _, point)
            if not enabled('targetOptions') or not vehicle or vehicle == 0 then
                return false
            end
            return vehicleDoors.hasDoor(vehicle, part)
                and vehicleDoors.isOpen(vehicle, part) ~= wantOpen
                and vehicleDoors.isAimedAt(vehicle, part, point)
        end,
        onSelect = function(vehicle)
            CreateThread(function() vehicleDoors.toggle(vehicle, part) end)
        end,
    }
end

local function storageOption()
    return {
        label = text('vehicle_doors.trunk_storage'),
        icon = 'box-open',
        name = 'kora_inventory:trunk:storage',
        distance = tonumber(settings().targetDistance) or 3.0,
        canInteract = function(vehicle, _, _, point)
            local cfg = vehicleSettings()
            if not enabled('inventoryOption') or cfg.enabled == false or cfg.trunkEnabled == false
                or not vehicle or vehicle == 0 then
                return false
            end
            local class = GetVehicleClass(vehicle)
            for _, skipped in ipairs(type(cfg.bootSkipClasses) == 'table' and cfg.bootSkipClasses or {}) do
                if tonumber(skipped) == class then
                    return false
                end
            end
            return vehicleDoors.hasDoor(vehicle, 'trunk') and vehicleDoors.isAimedAt(vehicle, 'trunk', point)
        end,
        onSelect = function(vehicle)
            storage().openTrunk(vehicle)
        end,
    }
end

local function unregister()
    local ids = registered
    registered = {}
    if GetResourceState('kora_target') ~= 'started' then
        return
    end
    for _, id in ipairs(ids) do
        pcall(function() exports.kora_target:removeGlobalType('vehicle', id) end)
    end
end

---(Re)register the ALT-menu entries with kora_target.
---@return boolean registered
function vehicleDoors.register()
    unregister()
    if GetResourceState('kora_target') ~= 'started' then
        return false
    end
    local ok, id = pcall(function()
        return exports.kora_target:addGlobalType('vehicle', {
            partOption('trunk', true),
            partOption('trunk', false),
            storageOption(),
            partOption('hood', true),
            partOption('hood', false),
        }, tonumber(settings().targetDistance) or 3.0)
    end)
    if ok and id then
        registered[#registered + 1] = id
    end
    return ok and id ~= nil
end

local function registerCommands()
    local cfg = settings()
    if cfg.enabled == false or cfg.commands == false then
        return
    end
    local names = type(cfg.commandNames) == 'table' and cfg.commandNames or {}
    for _, part in ipairs({ 'trunk', 'hood' }) do
        local name = names[part] == nil and part or names[part]
        if type(name) == 'string' and name ~= '' then
            RegisterCommand(name, function()
                if enabled('commands') then
                    vehicleDoors.toggleFromDriverSeat(part)
                end
            end, false)
        end
    end
end

registerCommands()

AddEventHandler('onClientResourceStart', function(name)
    if name == 'kora_target' then
        vehicleDoors.register()
    end
end)

AddEventHandler('onClientResourceStop', function(name)
    if name == GetCurrentResourceName() then
        unregister()
    end
end)

-- kora_target is a dependency, so it is normally running when this loads.
CreateThread(function()
    Wait(0)
    if #registered == 0 then
        vehicleDoors.register()
    end
end)

return vehicleDoors
