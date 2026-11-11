-- Run from kora_inventory: lua test/smoke/vehicles_client.lua
-- Real client/vehicles.lua and the real inventory-key hook in client/compat.lua;
-- only GTA natives and the transport are faked.
local H = dofile('test/harness.lua')

local f = { opened = {}, notices = {}, now = 10000, vehicles = {}, state = {} }
local env = setmetatable({}, { __index = _G })
env.Config = { kora_inventory = { vehicles = {
    enabled = true, gloveboxEnabled = true, trunkEnabled = true, bootReach = 1.8, respectLocks = true,
    frontBootModels = { 'Adder', 'zentorno' }, bootSkipClasses = { 8, 13, 21 },
} } }
env.LocalPlayer = { state = {} }
env.KoraInventory = { clientApi = {
    getCurrentSession = function() return f.session end,
    openInventory = function(kind, id) f.opened[#f.opened + 1] = { kind = kind, id = id } end,
} }
local Kora = {
    cache = { vehicle = function() return f.seated or false end, coords = function() return f.coords end },
    notify = { send = function(payload) f.notices[#f.notices + 1] = payload.message end },
}
env.Kora = Kora
env.GetGameTimer = function() return f.now end
env.GetHashKey = function(name) return 'hash:' .. name end
env.GetGamePool = function() local list = {} for id in pairs(f.vehicles) do list[#list + 1] = id end table.sort(list) return list end
env.GetEntityCoords = function(id) return f.vehicles[id].origin end
env.GetEntityModel = function(id) return 'hash:' .. f.vehicles[id].model end
env.GetVehicleClass = function(id) return f.vehicles[id].class end
env.GetModelDimensions = function() return { x = -1, y = -2.2, z = 0 }, { x = 1, y = 2.2, z = 1 } end
env.GetOffsetFromEntityInWorldCoords = function(id, x, y, z)
    local o = f.vehicles[id].origin
    return { x = o.x + x, y = o.y + y, z = o.z + z } -- vehicles face +y
end
env.Entity = function(id) return { state = { ['kora_vehiclekeys:locked'] = f.vehicles[id].bag } } end
env.GetVehicleDoorLockStatus = function(id) return f.vehicles[id].lock or 0 end
env.NetworkGetEntityIsNetworked = function(id) return f.vehicles[id].networked ~= false end
env.NetworkGetNetworkIdFromEntity = function(id) return 500 + id end
env.AddEventHandler = function() end
assert(loadfile('client/vehicles.lua', 't', env))()
local V = env.KoraInventory.vehicleStorage

local function reset(coords)
    f.opened, f.notices, f.session, f.seated, f.coords = {}, {}, nil, nil, coords
    f.now = f.now + 5000 -- clear the key-repeat cooldown
    env.LocalPlayer.state.inv_busy = nil
    env.Config.kora_inventory.vehicles.enabled = true
    env.Config.kora_inventory.vehicles.trunkEnabled = true
    env.Config.kora_inventory.vehicles.gloveboxEnabled = true
    env.Config.kora_inventory.vehicles.respectLocks = true
end
local function car(id, model, class)
    f.vehicles[id] = { model = model, class = class or 6, origin = { x = 0, y = 0, z = 0 } }
    return f.vehicles[id]
end

-- Glovebox when seated.
local sultan = car(1, 'sultan')
reset({ x = 0, y = 0, z = 0 })
f.seated = 1
H.equal(V.tryOpen(), true, 'seated: inventory key is handled by vehicle storage')
H.equal(#f.opened, 1, 'seated: one open request')
H.equal(f.opened[1].kind, 'glovebox', 'seated: glovebox requested')
H.equal(f.opened[1].id, 501, 'seated: only the network id is sent')
H.equal(V.tryOpen(), true, 'key repeat inside the cooldown is swallowed')
H.equal(#f.opened, 1, 'key repeat does not send a second request')
reset({ x = 0, y = 0, z = 0 })
f.seated = 1
f.session = { token = 't' }
H.equal(V.tryOpen(), false, 'an open session leaves the key to the close toggle')
H.equal(#f.opened, 0, 'no request while a session is open')
reset({ x = 0, y = 0, z = 0 })
f.seated = 1
env.Config.kora_inventory.vehicles.gloveboxEnabled = false
H.equal(V.tryOpen(), false, 'gloveboxEnabled=false falls back to the player inventory')
env.Config.kora_inventory.vehicles.enabled = false
env.Config.kora_inventory.vehicles.gloveboxEnabled = true
H.equal(V.tryOpen(), false, 'enabled=false disables vehicle storage')
reset({ x = 0, y = 0, z = 0 })
f.seated = 1
sultan.networked = false
H.equal(V.tryOpen(), true, 'un-networked vehicle is handled with a notice')
H.equal(#f.opened, 0, 'un-networked vehicle sends no request')
H.equal(#f.notices, 1, 'un-networked vehicle tells the player')
sultan.networked = nil

-- Trunk at the rear of a normal car.
reset({ x = 0, y = -3.5, z = 0 })
H.equal(V.tryOpen(), true, 'sultan: rear boot opens the trunk')
H.equal(f.opened[1].kind, 'trunk', 'sultan: trunk requested')
H.equal(f.opened[1].id, 501, 'sultan: network id sent')
reset({ x = 0, y = 3.5, z = 0 })
H.equal(V.tryOpen(), false, 'sultan: front bumper is not a boot')
reset({ x = 5, y = 0, z = 0 })
H.equal(V.tryOpen(), false, 'sultan: beside the car is not a boot')
H.equal(#f.opened, 0, 'no request away from the boot')
reset({ x = 0, y = -3.5, z = 3.5 })
H.equal(V.tryOpen(), false, 'a different floor is not the boot')

-- Front-boot (rear-engine) model.
sultan.model = 'adder'
reset({ x = 0, y = 3.5, z = 0 })
H.equal(V.tryOpen(), true, 'adder: front boot opens the trunk')
H.equal(f.opened[1].kind, 'trunk', 'adder: trunk requested')
reset({ x = 0, y = -3.5, z = 0 })
H.equal(V.tryOpen(), false, 'adder: the rear is the engine, not a boot')
env.Config.kora_inventory.vehicles.frontBootModels = { 'sultan' }
sultan.model = 'sultan'
reset({ x = 0, y = 3.5, z = 0 })
H.equal(V.tryOpen(), true, 'front-boot list is config driven and read at use time')

-- Locked vehicle.
env.Config.kora_inventory.vehicles.frontBootModels = {}
reset({ x = 0, y = -3.5, z = 0 })
sultan.bag = true
H.equal(V.tryOpen(), false, 'locked (keys state): player inventory still opens')
H.equal(#f.opened, 0, 'locked: no trunk request')
H.equal(f.notices[1], 'This vehicle is locked.', 'locked: clear notify')
reset({ x = 0, y = -3.5, z = 0 })
sultan.bag, sultan.lock = nil, 2
H.equal(V.tryOpen(), false, 'locked (native status) is refused')
H.equal(#f.notices, 1, 'native lock notifies too')
reset({ x = 0, y = -3.5, z = 0 })
sultan.bag = false
H.equal(V.tryOpen(), true, 'keys state unlocked wins over a stale native status')
reset({ x = 0, y = -3.5, z = 0 })
sultan.bag, sultan.lock = true, nil
env.Config.kora_inventory.vehicles.respectLocks = false
H.equal(V.tryOpen(), true, 'respectLocks=false allows a locked trunk')
sultan.bag = nil

-- Excluded classes, trunk switch, nearest boot.
reset({ x = 0, y = -3.5, z = 0 })
sultan.class = 8
H.equal(V.tryOpen(), false, 'motorcycle class has no boot')
sultan.class = 6
env.Config.kora_inventory.vehicles.trunkEnabled = false
H.equal(V.tryOpen(), false, 'trunkEnabled=false disables the trunk')
reset({ x = 0, y = -3.5, z = 0 })
local far = car(2, 'sultan')
far.origin = { x = 0, y = -6.3, z = 0 } -- its front boot is 0.3 m from the player (the sultan boot is 1.0 m)
far.model = 'adder'
env.Config.kora_inventory.vehicles.frontBootModels = { 'adder' }
H.equal(V.tryOpen(), true, 'two candidates: one request is made')
H.equal(f.opened[1].id, 502, 'the closest boot wins')

-- The inventory key reaches this module before the player inventory.
local compat = assert(io.open('client/compat.lua', 'r')):read('*a')
H.ok(compat:find('KoraInventory.vehicleStorage.tryOpen()', 1, true), 'inventory key tries vehicle storage first')
local vehiclesAt = compat:find('vehicleStorage.tryOpen()', 1, true)
local selfAt = compat:find('openSelf()\nend, false)', 1, true)
H.ok(vehiclesAt and selfAt and vehiclesAt < selfAt, 'vehicle storage is tried before the player inventory')
local manifest = assert(io.open('fxmanifest.lua', 'r')):read('*a')
H.ok(manifest:find("'client/vehicles.lua'", 1, true), 'client/vehicles.lua ships in the manifest')
H.ok(not assert(io.open('client/vehicles.lua', 'r')):read('*a'):find('os%.'), 'no os library in client Lua')
H.finish()
