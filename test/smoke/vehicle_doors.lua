-- Run from the resource root: lua test/smoke/vehicle_doors.lua
-- Real client/vehicles.lua and client/vehicle_doors.lua: ALT-menu trunk/hood
-- options, trunk storage option and the /trunk and /hood commands. Natives,
-- kora_target and the inventory transport are faked.
local H = dofile('test/harness.lua')

local f = {
    opened = {}, notices = {}, now = 10000, commands = {}, controlled = {}, doorCalls = {},
    registered = {}, seat = nil, inVehicle = 0, doors = {}, valid = true, lockedBag = nil,
    controlOk = true,
}
local env = setmetatable({}, { __index = _G })
env.Config = { qbinventory = { vehicles = {
    enabled = true, trunkEnabled = true, respectLocks = true, bootReach = 1.8,
    frontBootModels = { 'adder' }, bootSkipClasses = { 8, 13, 21 },
    doors = {
        enabled = true, targetOptions = true, inventoryOption = true, commands = true,
        commandNames = { trunk = 'trunk', hood = 'hood' }, respectLocks = true,
        targetDistance = 3.0, partDepth = 1.3,
    },
} } }
local doors = env.Config.qbinventory.vehicles.doors
env.LocalPlayer = { state = {} }
env.QbInventory = { clientApi = {
    getCurrentSession = function() return f.session end,
    openInventory = function(kind, id) f.opened[#f.opened + 1] = { kind = kind, id = id } end,
} }
local Kora = {
    cache = {
        vehicle = function() return f.inVehicle ~= 0 and f.inVehicle or false end,
        seat = function() return f.inVehicle ~= 0 and f.seat or false end,
        coords = function() return { x = 0, y = 0, z = 0 } end,
    },
    notify = { send = function(payload) f.notices[#f.notices + 1] = payload.message end },
    locale = { translate = function(_, key) return key end },
    entities = { requestControl = function(vehicle)
        f.controlled[#f.controlled + 1] = vehicle
        return f.controlOk
    end },
}
env.QB, env.Kora = Kora, Kora
env.GetCurrentResourceName = function() return 'kora_inventory' end
env.GetResourceState = function() return 'started' end
env.GetGameTimer = function() return f.now end
env.GetHashKey = function(name) return 'hash:' .. name end
env.GetEntityModel = function(v) return 'hash:' .. f.model[v] end
env.GetModelDimensions = function() return { x = -1, y = -2.2, z = 0 }, { x = 1, y = 2.2, z = 1 } end
env.GetOffsetFromEntityGivenWorldCoords = function(_, x, y, z) return { x = x, y = y, z = z } end -- vehicle at origin facing +y
env.GetVehicleClass = function() return 6 end
env.DoesEntityExist = function() return true end
env.NetworkGetEntityIsNetworked = function() return true end
env.NetworkGetNetworkIdFromEntity = function(v) return 500 + v end
env.PlayerPedId = function() return 99 end
-- FiveM hands BOOL natives to Lua as 1 or false, never true.
env.GetIsDoorValid = function() return f.valid and 1 or false end
env.GetVehicleDoorAngleRatio = function(_, door) return f.doors[door] or 0.0 end
env.SetVehicleDoorOpen = function(_, door) f.doors[door] = 1.0; f.doorCalls[#f.doorCalls + 1] = 'open:' .. door end
env.SetVehicleDoorShut = function(_, door) f.doors[door] = 0.0; f.doorCalls[#f.doorCalls + 1] = 'shut:' .. door end
env.GetVehicleDoorLockStatus = function() return 0 end
env.Entity = function() return { state = { ['qbvehiclekeys:locked'] = f.lockedBag } } end
env.AddEventHandler = function() end
env.Wait = function() end
env.CreateThread = function(fn) fn() end
env.RegisterCommand = function(name, fn) f.commands[name] = fn end
env.exports = { kora_target = {
    addGlobalType = function(_, kind, options, distance)
        f.registered[#f.registered + 1] = { kind = kind, options = options, distance = distance }
        return #f.registered
    end,
    removeGlobalType = function() end,
} }
f.model = { [1] = 'sultan', [2] = 'adder' }
assert(loadfile('client/vehicles.lua', 't', env))()
assert(loadfile('client/vehicle_doors.lua', 't', env))()
local D = env.QbInventory.vehicleDoors

H.equal(#f.registered, 1, 'one global vehicle registration')
H.equal(f.registered[1].kind, 'vehicle', 'registered on vehicles')
local options = f.registered[1].options
H.equal(#options, 5, 'trunk open/close, storage, hood open/close')
local byName = {}
for _, option in ipairs(options) do byName[option.name] = option end
local trunkOpen, trunkClose = byName['kora_inventory:trunk:open'], byName['kora_inventory:trunk:close']
local hoodOpen, hoodClose = byName['kora_inventory:hood:open'], byName['kora_inventory:hood:close']
local storage = byName['kora_inventory:trunk:storage']
H.equal(trunkOpen.label, 'Open trunk', 'label falls back to English text')
H.ok(f.commands.trunk and f.commands.hood, '/trunk and /hood registered')

local rear, front = { x = 0, y = -2.0, z = 0.5 }, { x = 0, y = 2.0, z = 0.5 }
local function can(option, vehicle, point) return option.canInteract(vehicle, 1.0, nil, point) == true end
local function reset()
    f.opened, f.notices, f.controlled, f.doorCalls, f.doors = {}, {}, {}, {}, {}
    f.seat, f.inVehicle, f.valid, f.lockedBag, f.controlOk, f.session = nil, 0, true, nil, true, nil
    f.now = f.now + 5000
    doors.enabled, doors.targetOptions, doors.inventoryOption, doors.commands, doors.respectLocks = true, true, true, true, true
    env.Config.qbinventory.vehicles.trunkEnabled = true
end

-- Aiming: rear end shows the trunk, front end the hood, middle/side nothing.
reset()
H.equal(can(trunkOpen, 1, rear), true, 'rear aim: Open trunk')
H.equal(can(hoodOpen, 1, rear), false, 'rear aim: no Open hood')
H.equal(can(hoodOpen, 1, front), true, 'front aim: Open hood')
H.equal(can(trunkOpen, 1, front), false, 'front aim: no Open trunk')
H.equal(can(trunkOpen, 1, { x = 0, y = 0, z = 0.5 }), false, 'middle of the car: no trunk')
H.equal(can(trunkOpen, 1, { x = 0.95, y = -2.0, z = 0.5 }), false, 'side of the rear quarter: no trunk')
H.equal(can(trunkOpen, 1, nil), false, 'no aim point: no trunk')
H.equal(can(trunkClose, 1, rear), false, 'closed trunk: no Close trunk')
f.doors[5] = 1.0
H.equal(can(trunkOpen, 1, rear), false, 'open trunk: no Open trunk')
H.equal(can(trunkClose, 1, rear), true, 'open trunk: Close trunk')
f.doors[4] = 1.0
H.equal(can(hoodClose, 1, front), true, 'open hood: Close hood')

-- The native's 1 (FiveM's BOOL true) counts as a lid; true is accepted too.
reset()
H.equal(D.hasDoor(1, 'trunk'), true, 'GetIsDoorValid 1: trunk present')
env.GetIsDoorValid = function() return true end
H.equal(D.hasDoor(1, 'hood'), true, 'GetIsDoorValid true: hood present')
env.GetIsDoorValid = function() return f.valid and 1 or false end

-- A vehicle without the lid hides the entry.
reset(); f.valid = false
H.equal(can(trunkOpen, 1, rear), false, 'no trunk door: hidden')
H.equal(can(hoodOpen, 1, front), false, 'no hood door: hidden')
H.equal(can(storage, 1, rear), false, 'no trunk door: no storage entry')

-- Rear/mid-engine model: trunk is the bonnet lid at the front.
reset()
H.equal(can(trunkOpen, 2, front), true, 'front-boot model: trunk is at the front')
H.equal(can(hoodOpen, 2, rear), true, 'front-boot model: hood is at the rear')
H.equal(can(trunkOpen, 2, rear), false, 'front-boot model: nothing trunk-like at the rear')
trunkOpen.onSelect(2)
H.equal(f.doorCalls[1], 'open:4', 'front-boot model trunk opens door 4')

-- Selecting opens the lid after taking control, then closes it.
reset()
trunkOpen.onSelect(1)
H.equal(f.doorCalls[1], 'open:5', 'trunk opens boot door')
H.equal(f.controlled[1], 1, 'network control requested for sync')
trunkClose.onSelect(1)
H.equal(f.doorCalls[2], 'shut:5', 'trunk closes boot door')
hoodOpen.onSelect(1)
H.equal(f.doorCalls[3], 'open:4', 'hood opens bonnet door')

-- No control: nothing changes and the player is told.
reset(); f.controlOk = false
trunkOpen.onSelect(1)
H.equal(#f.doorCalls, 0, 'no control: door untouched')
H.equal(f.notices[#f.notices], 'Could not reach the vehicle. Try again.', 'no control: notice')

-- Locks: opening from outside is refused, closing and inside are fine.
reset(); f.lockedBag = true
trunkOpen.onSelect(1)
H.equal(#f.doorCalls, 0, 'locked: trunk stays shut from outside')
H.equal(f.notices[#f.notices], 'This vehicle is locked.', 'locked: notice')
f.doors[5] = 1.0
trunkClose.onSelect(1)
H.equal(f.doorCalls[1], 'shut:5', 'locked: an open trunk can still be closed')
f.doors[5] = 0.0; f.doorCalls = {}
f.inVehicle = 1
trunkOpen.onSelect(1)
H.equal(f.doorCalls[1], 'open:5', 'locked: allowed from inside the vehicle')
f.inVehicle = 0; f.doors[5] = 0.0; f.doorCalls = {}
doors.respectLocks = false
trunkOpen.onSelect(1)
H.equal(f.doorCalls[1], 'open:5', 'respectLocks off: locked trunk opens')

-- Commands: driver seat only.
reset()
f.inVehicle, f.seat = 1, -1
f.commands.trunk()
H.equal(f.doorCalls[1], 'open:5', '/trunk opens the trunk')
f.commands.trunk()
H.equal(f.doorCalls[2], 'shut:5', '/trunk closes it again')
f.commands.hood()
H.equal(f.doorCalls[3], 'open:4', '/hood opens the hood')
f.commands.hood()
H.equal(f.doorCalls[4], 'shut:4', '/hood closes it again')
f.doorCalls = {}
f.seat = 7
f.commands.trunk()
H.equal(#f.doorCalls, 0, 'passenger seat: /trunk does nothing')
H.equal(f.notices[#f.notices], 'You must be in the driver seat.', 'passenger seat: notice')
f.inVehicle = 0
f.commands.hood()
H.equal(f.notices[#f.notices], 'You must be in the driver seat.', 'on foot: /hood tells the driver-seat rule')
f.seat, f.inVehicle = -1, 1
f.lockedBag = true
f.commands.trunk()
H.equal(f.doorCalls[1], 'open:5', 'driver seat of a locked vehicle can still open the trunk')
f.doors[5] = 0.0; f.doorCalls = {}
f.valid = false
f.commands.hood()
H.equal(f.notices[#f.notices], 'This vehicle has no hood.', 'no hood: notice')
f.valid = true
doors.commands = false
f.doorCalls = {}
f.commands.trunk()
H.equal(#f.doorCalls, 0, 'commands switched off at runtime: ignored')

-- Config switches hide the entries.
reset(); doors.targetOptions = false
H.equal(can(trunkOpen, 1, rear), false, 'targetOptions off: no trunk toggle')
H.equal(can(storage, 1, rear), true, 'targetOptions off: storage entry stays')
reset(); doors.enabled = false
H.equal(can(trunkOpen, 1, rear) or can(storage, 1, rear) or can(hoodOpen, 1, front), false, 'enabled off: nothing')
reset(); doors.inventoryOption = false
H.equal(can(storage, 1, rear), false, 'inventoryOption off: no storage entry')

-- Trunk storage entry opens the trunk inventory and follows the trunk rules.
reset()
H.equal(can(storage, 1, rear), true, 'rear aim: trunk storage shown')
H.equal(can(storage, 1, front), false, 'front aim: no trunk storage')
storage.onSelect(1)
H.equal(#f.opened, 1, 'storage: one request')
H.equal(f.opened[1].kind, 'trunk', 'storage: trunk requested')
H.equal(f.opened[1].id, 501, 'storage: only the network id is sent')
reset(); f.lockedBag = true
storage.onSelect(1)
H.equal(#f.opened, 0, 'storage: locked vehicle refused')
H.equal(f.notices[#f.notices], 'This vehicle is locked.', 'storage: locked notice')
reset(); env.Config.qbinventory.vehicles.trunkEnabled = false
H.equal(can(storage, 1, rear), false, 'trunkEnabled off: no storage entry')

H.finish()
