-- Run from the resource root: lua test/smoke/trunk_animation.lua
-- Real client/vehicles.lua trunk animation lifecycle; natives, events and the
-- thread scheduler are faked.
local H = dofile('test/harness.lua')

local f = { now = 1000, session = nil, dead = false, coords = { x = 0, y = -2.5, z = 0 }, log = {}, handlers = {}, threads = {}, door = 0.0, playing = false }
local env = setmetatable({}, { __index = _G })
env.Config = { qbinventory = { vehicles = {
    enabled = true, bootReach = 1.8, frontBootModels = {},
    trunkAnimation = { enabled = true, dict = 'mini@repair', clip = 'fixing_a_ped', flag = 49, openDoor = true },
} } }
env.LocalPlayer = { state = {} }
env.QbInventory = { clientApi = {
    getCurrentSession = function() return f.session end,
    openInventory = function() end,
} }
env.QB = { cache = { vehicle = function() return false end, coords = function() return f.coords end }, notify = { send = function() end } }
env.Kora = env.QB
env.GetGameTimer = function() return f.now end
env.GetHashKey = function(n) return n end
env.GetEntityModel = function() return 'm' end
env.GetModelDimensions = function() return { x = -1, y = -2.2, z = 0 }, { x = 1, y = 2.2, z = 1 } end
env.GetOffsetFromEntityInWorldCoords = function(_, x, y, z) return { x = x, y = y, z = z } end
env.PlayerPedId = function() return 99 end
env.GetEntityCoords = function() return f.coords end
env.IsEntityDead = function() return f.dead end
env.DoesEntityExist = function() return true end
env.GetCurrentResourceName = function() return 'kora_inventory' end
env.TaskTurnPedToFaceCoord = function() f.log[#f.log + 1] = 'turn' end
env.GetVehicleDoorAngleRatio = function() return f.door end
env.NetworkHasControlOfEntity = function() return true end
env.NetworkRequestControlOfEntity = function() end
env.SetVehicleDoorOpen = function() f.door = 1.0; f.log[#f.log + 1] = 'open' end
env.SetVehicleDoorShut = function() f.door = 0.0; f.log[#f.log + 1] = 'shut' end
env.HasAnimDictLoaded = function() return true end
env.RequestAnimDict = function() end
env.TaskPlayAnim = function() f.playing = true; f.log[#f.log + 1] = 'anim' end
env.IsEntityPlayingAnim = function() return f.playing end
env.StopAnimTask = function() f.playing = false; f.log[#f.log + 1] = 'stop' end
env.AddEventHandler = function(name, fn) f.handlers[name] = f.handlers[name] or {}; table.insert(f.handlers[name], fn) end
env.Wait = function(ms) coroutine.yield(ms) end
env.CreateThread = function(fn) f.threads[#f.threads + 1] = coroutine.create(fn) end
local function pump(ms)
    f.now = f.now + (ms or 300)
    for _, t in ipairs(f.threads) do
        if coroutine.status(t) == 'suspended' then assert(coroutine.resume(t)) end
    end
end
local function fire(name, ...) for _, fn in ipairs(f.handlers[name] or {}) do fn(...) end end
assert(loadfile('client/vehicles.lua', 't', env))()
local V = env.QbInventory.vehicleStorage

local function open(kind, key)
    f.log, f.threads, f.door, f.playing, f.dead = {}, {}, 0.0, false, false
    f.coords = { x = 0, y = -2.5, z = 0 }
    f.session = { token = 't' }
    -- request() records the pending trunk through tryOpen's path
    env.GetGamePool = function() return { 1 } end
    env.GetVehicleClass = function() return 6 end
    env.GetVehicleDoorLockStatus = function() return 0 end
    env.Entity = function() return { state = {} } end
    env.NetworkGetEntityIsNetworked = function() return true end
    env.NetworkGetNetworkIdFromEntity = function() return 5 end
    f.session = nil
    f.now = f.now + 5000
    V.tryOpen()
    f.session = { token = 't' }
    fire('qbinventory:ui:sessionOpened', { token = 't', secondary = { key = key } })
    pump()
end

-- Trunk opens: turn, door opens, anim plays.
open('trunk', 'trunk:ABC123')
H.equal(table.concat(f.log, ','), 'turn,open,anim', 'trunk open: face, open door, play anim')
pump(); H.equal(f.playing, true, 'anim keeps playing while session is open')

-- Normal close.
f.session = nil
fire('qbinventory:ui:sessionClosed', { token = 't' })
H.equal(f.playing, false, 'close stops the anim')
H.equal(f.door, 0.0, 'close shuts the door we opened')

-- Death while open.
open('trunk', 'trunk:ABC123')
f.dead = true; pump()
H.equal(f.playing, false, 'death stops the anim')
H.equal(f.door, 0.0, 'death shuts the door')

-- Moving away.
open('trunk', 'trunk:ABC123')
f.coords = { x = 0, y = -20, z = 0 }; pump()
H.equal(f.playing, false, 'walking away stops the anim')

-- Session vanishes without a close event (item use / forced close).
open('trunk', 'trunk:ABC123')
f.session = nil; pump()
H.equal(f.playing, false, 'missing session stops the anim')

-- Resource stop.
open('trunk', 'trunk:ABC123')
fire('onClientResourceStop', 'kora_inventory')
H.equal(f.playing, false, 'resource stop stops the anim')
H.equal(f.door, 0.0, 'resource stop shuts the door')

-- A door that was already open is left open.
f.log, f.threads, f.playing = {}, {}, false
f.door = 1.0
f.session = nil; f.now = f.now + 5000; V.tryOpen(); f.session = { token = 't' }
fire('qbinventory:ui:sessionOpened', { token = 't', secondary = { key = 'trunk:X' } }); pump()
fire('qbinventory:ui:sessionClosed', { token = 't' })
H.equal(f.door, 1.0, 'pre-opened door is not closed')
H.equal(f.playing, false, 'anim stopped')

-- Disabled: nothing happens.
env.Config.qbinventory.vehicles.trunkAnimation.enabled = false
open('trunk', 'trunk:ABC123')
H.equal(#f.log, 0, 'disabled: no door or anim')
env.Config.qbinventory.vehicles.trunkAnimation.enabled = true

-- Non-trunk session (stash) never animates.
open('stash', 'stash:foo')
H.equal(#f.log, 0, 'stash session does not animate')

H.finish()
