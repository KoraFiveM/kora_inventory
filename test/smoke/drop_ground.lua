-- A dropped prop rests on the ground instead of sinking: the model's lowest
-- point (GetModelDimensions min.z) and Config groundOffset decide its Z.
local H = dofile('test/harness.lua')

QbInventory = nil
dofile('shared.lua')
local groundedZ = QbInventory.groundedZ
H.equal(groundedZ(10.0, -0.25, 0.0), 10.25, 'a model with min.z -0.25 is lifted by 0.25')
H.equal(groundedZ(10.0, 0.0, 0.5), 10.5, 'groundOffset is added after placement')
H.equal(groundedZ(10.0, -0.25, -0.05), 10.2, 'a negative offset sinks it back down')
H.equal(groundedZ(10.0), 10.0, 'missing dimensions/offset leave the ground Z alone')

local function run(drops, natives)
    local calls, threads = {}, {}
    local env = {}
    for key, value in pairs(_G) do env[key] = value end
    env.Config = { qbinventory = { drops = drops } }
    env.QbInventory = QbInventory
    env.GetCurrentResourceName = function() return 'kora_inventory' end
    env.GetInvokingResource = function() return nil end
    env.NetworkIsSessionStarted = function() return false end
    env.Wait = function() end
    env.CreateThread = function(fn) threads[#threads + 1] = fn end
    local handlers = {}
    env.RegisterNetEvent = function(name, cb) handlers[name] = cb end
    env.AddEventHandler = function() end
    env.GetGroundZFor_3dCoord = function(_, _, z) return true, z - 1.0 end
    env.RequestCollisionAtCoord = function() end
    env.HasCollisionLoadedAroundEntity = function() return true end
    env.DoesEntityExist = function() return true end
    env.GetEntityModel = function() return 1 end
    env.GetModelDimensions = function() return { z = -0.3 } end
    env.GetEntityCoords = function() return { x = 1, y = 2, z = natives.placedZ } end
    env.PlaceObjectOnGroundProperly = function() calls.place = true; return natives.placeOk end
    env.SetEntityCoordsNoOffset = function(_, x, y, z) calls.z = z end
    env.exports = { kora_target = { addSphereZone = function() return 1 end, removeZone = function() end } }
    env.QB = { entities = { create = function() return 7 end, remove = function() end },
        callback = { trigger = function() return {} end } }
    assert(loadfile('client/drops.lua', 't', env))()
    handlers['qbinventory:client:dropCreated']('a', { x = 1, y = 2, z = 5.0 })
    threads[2]()
    return calls
end

local fallback = run({ groundOffset = 0.1 }, { placeOk = false })
H.ok(fallback.place, 'PlaceObjectOnGroundProperly is tried first')
H.equal(fallback.z, 5.0 - -0.3 + 0.1, 'fallback uses the traced ground Z, model min.z and the offset')

local placed = run({}, { placeOk = true, placedZ = 4.0 })
H.equal(placed.z, nil, 'default offset leaves a properly placed prop alone')

local nudged = run({ groundOffset = 0.2 }, { placeOk = true, placedZ = 4.0 })
H.equal(nudged.z, 4.2, 'groundOffset is applied after PlaceObjectOnGroundProperly')

local off = run({ placeOnGround = false, groundOffset = 1.0 }, { placeOk = true })
H.equal(off.place, nil, 'placeOnGround = false skips all placement')
H.equal(off.z, nil, 'and ignores groundOffset')

H.finish()
