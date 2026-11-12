-- Vehicle storage entry point for the inventory key.
--
-- This file only decides WHICH vehicle storage the player is asking for and
-- forwards that intent (a network id) through client.lua's validated transport.
-- The server resolves the plate, class, capacity, lock state and distance
-- itself before it creates or opens anything (see server/vehicles.lua).
--
-- Seated in a vehicle -> glovebox. On foot at the boot of a vehicle -> trunk,
-- where the boot is the front for the rear/mid-engine models listed in
-- Config.kora_inventory.vehicles.frontBootModels. client/compat.lua calls tryOpen()
-- from the inventory key before it falls back to the player's own inventory.

KoraInventory = KoraInventory or {}
-- Locale text with an English fallback (shared.lua's KoraInventory.text).
local function localeText(key, fallback, vars)
    local text = KoraInventory and KoraInventory.text
    return text and text(key, fallback, vars) or fallback
end

local vehicleStorage = {}
KoraInventory.vehicleStorage = vehicleStorage

-- Ignore key repeats while a request is in flight.
local REQUEST_COOLDOWN_MS = 750
-- Vehicles further than this from the player cannot have a boot within reach.
local SEARCH_RADIUS = 12.0
-- Boot position sits this far beyond the bumper, so it is reachable from outside.
local BOOT_OUTSET = 0.3
local lastRequest = -REQUEST_COOLDOWN_MS
-- A trunk request is only paired with the session it produced for this long.
local PENDING_TRUNK_MS = 5000
-- Extra metres beyond bootReach before the trunk animation gives up.
local ANIM_LEAVE_MARGIN = 1.5
local CONTROL_WAIT_MS = 500
local BONNET_DOOR, BOOT_DOOR = 4, 5

local pendingTrunk -- { vehicle, at } set by request(), consumed by the session event
local activeAnim   -- the trunk animation currently owned by this file

local function settings()
    return (Config.kora_inventory and Config.kora_inventory.vehicles) or {}
end

local function notify(key, fallback)
    Kora.notify.send({
        title = localeText('vehicle_doors.title', 'Vehicle'),
        message = localeText(key, fallback),
        type = 'error',
    })
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
    local state = Entity(vehicle).state['kora_vehiclekeys:locked']
    if type(state) == 'boolean' then
        return state
    end
    return (tonumber(GetVehicleDoorLockStatus(vehicle)) or 0) >= 2
end

vehicleStorage.isLocked = isLocked

---True for the rear/mid-engine models listed in frontBootModels, whose trunk is
---under the front (bonnet) lid.
function vehicleStorage.hasFrontBoot(vehicle, cfg)
    cfg = cfg or settings()
    return hasFrontBoot(GetEntityModel(vehicle), cfg.frontBootModels)
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

local function animSettings()
    local cfg = settings().trunkAnimation
    if type(cfg) ~= 'table' or cfg.enabled ~= true then
        return nil
    end
    return cfg
end

local function stopTrunkAnimation()
    local anim = activeAnim
    if not anim then
        return
    end
    activeAnim = nil
    local ped = PlayerPedId()
    if anim.played and IsEntityPlayingAnim(ped, anim.dict, anim.clip, 3) then
        StopAnimTask(ped, anim.dict, anim.clip, 1.0)
    end
    -- Only shut a door this script opened; never one the player or another
    -- script already had open.
    if anim.openedDoor and DoesEntityExist(anim.vehicle) then
        if NetworkHasControlOfEntity(anim.vehicle) then
            SetVehicleDoorShut(anim.vehicle, anim.door, false)
        else
            NetworkRequestControlOfEntity(anim.vehicle)
            SetVehicleDoorShut(anim.vehicle, anim.door, false)
        end
    end
end
vehicleStorage.stopTrunkAnimation = stopTrunkAnimation

local function loadAnimDict(dict)
    if HasAnimDictLoaded(dict) then
        return true
    end
    RequestAnimDict(dict)
    local deadline = GetGameTimer() + 2000
    while not HasAnimDictLoaded(dict) and GetGameTimer() < deadline do
        Wait(0)
    end
    return HasAnimDictLoaded(dict)
end

---Face the boot, open its door and play the configured animation while the
---trunk session is open. Everything is undone by stopTrunkAnimation().
local function startTrunkAnimation(vehicle, cfg)
    stopTrunkAnimation()
    local vcfg = settings()
    local model = GetEntityModel(vehicle)
    local mine = {
        vehicle = vehicle,
        dict = tostring(cfg.dict or 'mini@repair'),
        clip = tostring(cfg.clip or 'fixing_a_ped'),
        door = hasFrontBoot(model, vcfg.frontBootModels) and BONNET_DOOR or BOOT_DOOR,
    }
    activeAnim = mine
    CreateThread(function()
        local ped = PlayerPedId()
        local boot = vehicleStorage.bootPosition(vehicle, vcfg)
        TaskTurnPedToFaceCoord(ped, boot.x, boot.y, boot.z, 600)

        if cfg.openDoor ~= false and GetVehicleDoorAngleRatio(vehicle, mine.door) < 0.1 then
            if not NetworkHasControlOfEntity(vehicle) then
                NetworkRequestControlOfEntity(vehicle)
                local deadline = GetGameTimer() + CONTROL_WAIT_MS
                while activeAnim == mine and not NetworkHasControlOfEntity(vehicle) and GetGameTimer() < deadline do
                    Wait(0)
                end
            end
            if activeAnim ~= mine then
                return
            end
            -- Opened even without control: the local state still shows for us and
            -- is replicated when we are the owner (the usual case for a driver).
            SetVehicleDoorOpen(vehicle, mine.door, false, false)
            mine.openedDoor = true
        end

        if activeAnim == mine and loadAnimDict(mine.dict) and activeAnim == mine then
            TaskPlayAnim(ped, mine.dict, mine.clip, 4.0, -4.0, -1, tonumber(cfg.flag) or 49, 0.0, false, false, false)
            mine.played = true
        end

        local limit = (tonumber(vcfg.bootReach) or 1.8) + ANIM_LEAVE_MARGIN
        while activeAnim == mine do
            Wait(250)
            if activeAnim ~= mine then
                break
            end
            local api = KoraInventory.clientApi
            local at = GetEntityCoords(PlayerPedId())
            local now = vehicleStorage.bootPosition(vehicle, vcfg)
            local dx, dy = now.x - at.x, now.y - at.y
            if not (api and api.getCurrentSession())
                or IsEntityDead(PlayerPedId())
                or not DoesEntityExist(vehicle)
                or dx * dx + dy * dy > limit * limit then
                stopTrunkAnimation()
            end
        end
    end)
end

AddEventHandler('kora_inventory:ui:sessionOpened', function(payload)
    local pending = pendingTrunk
    pendingTrunk = nil
    local cfg = animSettings()
    local key = type(payload) == 'table' and type(payload.secondary) == 'table' and payload.secondary.key
    if not (cfg and pending and type(key) == 'string' and key:sub(1, 6) == 'trunk:'
        and GetGameTimer() - pending.at <= PENDING_TRUNK_MS and DoesEntityExist(pending.vehicle)) then
        return
    end
    startTrunkAnimation(pending.vehicle, cfg)
end)

AddEventHandler('kora_inventory:ui:sessionClosed', function()
    pendingTrunk = nil
    stopTrunkAnimation()
end)

AddEventHandler('kora_inventory:ui:rejected', function()
    pendingTrunk = nil
end)

AddEventHandler('onClientResourceStop', function(name)
    if name == GetCurrentResourceName() then
        pendingTrunk = nil
        stopTrunkAnimation()
    end
end)

local function request(kind, vehicle)
    if not NetworkGetEntityIsNetworked(vehicle) then
        notify('vehicle_doors.no_storage', 'This vehicle has no storage you can open.')
        return true
    end
    lastRequest = GetGameTimer()
    pendingTrunk = kind == 'trunk' and { vehicle = vehicle, at = lastRequest } or nil
    KoraInventory.clientApi.openInventory(kind, NetworkGetNetworkIdFromEntity(vehicle))
    return true
end

---Open the trunk inventory of a specific vehicle (the ALT menu entry). Follows
---the same switches and lock rule as the inventory key; the server still
---resolves distance, class and lock itself.
---@param vehicle number
---@return boolean requested
function vehicleStorage.openTrunk(vehicle)
    local cfg = settings()
    local api = KoraInventory.clientApi
    if cfg.enabled == false or cfg.trunkEnabled == false or not api or api.getCurrentSession()
        or LocalPlayer.state.inv_busy or not vehicle or not DoesEntityExist(vehicle) then
        return false
    end
    if GetGameTimer() - lastRequest < REQUEST_COOLDOWN_MS then
        return true
    end
    if cfg.respectLocks ~= false and isLocked(vehicle) then
        notify('vehicle_doors.locked', 'This vehicle is locked.')
        return false
    end
    return request('trunk', vehicle)
end

---Handle the inventory key for vehicle storage.
---@return boolean handled true when a vehicle inventory was requested (the
---caller must not also open the player's own inventory).
function vehicleStorage.tryOpen()
    local cfg = settings()
    local api = KoraInventory.clientApi
    if cfg.enabled == false or not api or api.getCurrentSession() or LocalPlayer.state.inv_busy then
        return false
    end
    if GetGameTimer() - lastRequest < REQUEST_COOLDOWN_MS then
        return true
    end

    local seated = Kora.cache.vehicle()
    if seated and seated ~= 0 then
        if cfg.gloveboxEnabled == false then
            return false
        end
        return request('glovebox', seated)
    end

    if cfg.trunkEnabled == false then
        return false
    end
    local vehicle = vehicleStorage.findBootVehicle(Kora.cache.coords(), cfg)
    if not vehicle then
        return false
    end
    if cfg.respectLocks ~= false and isLocked(vehicle) then
        notify('vehicle_doors.locked', 'This vehicle is locked.')
        return false
    end
    return request('trunk', vehicle)
end

return vehicleStorage
