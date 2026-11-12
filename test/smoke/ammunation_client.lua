-- Ammu-Nation's target registrations must be replaceable. The target resource
-- can restart independently, and duplicate lifecycle events must not leave two
-- identical Browse Ammu-Nation options at every counter.
local H = dofile('test/harness.lua')

Config = { kora_inventory = {} }
dofile('config/shops/ammunation.lua')
dofile('shared.lua')

local shop = Config.kora_inventory.shops.ammunation
shop.locations = {
    { x = 10, y = 20, z = 30 },
    { x = 40, y = 50, z = 60 },
}
shop.blip.enabled = false

local handlers, activeZones, nextId = {}, {}, 0
RegisterNetEvent = function() end
CreateThread = function() end -- shopkeeper spawning is covered by ammunation_shopkeepers.lua
GetCurrentResourceName = function() return "kora_inventory" end
AddEventHandler = function(name, callback)
    handlers[name] = handlers[name] or {}
    handlers[name][#handlers[name] + 1] = callback
end

exports = {
    kora_inventory = {
        openInventory = function() end,
    },
    kora_target = {
        addSphereZone = function(_, options)
            nextId = nextId + 1
            activeZones[nextId] = options
            return nextId
        end,
        removeZone = function(_, id)
            local removed = activeZones[id] ~= nil
            activeZones[id] = nil
            return removed
        end,
    },
}

Kora = { blips = {} }
dofile('client/shops/ammunation.lua')

local function countActiveZones()
    local count = 0
    for _ in pairs(activeZones) do count = count + 1 end
    return count
end

H.equal(countActiveZones(), #shop.locations, 'initial load registers one target per Ammu-Nation counter')

for _, callback in ipairs(handlers.onClientResourceStart or {}) do callback('kora_target') end
H.equal(countActiveZones(), #shop.locations, 'a kora_target start replaces existing Ammu-Nation targets')

for _, callback in ipairs(handlers.onClientResourceStart or {}) do callback('kora_target') end
H.equal(countActiveZones(), #shop.locations, 'repeated kora_target starts cannot duplicate Ammu-Nation targets')

for _, callback in ipairs(handlers.onClientResourceStop or {}) do callback('kora_target') end
-- kora_target's own stop handler removes its zone registrations before the next
-- instance starts. Simulate that independent cleanup here.
activeZones = {}
for _, callback in ipairs(handlers.onClientResourceStart or {}) do callback('kora_target') end
H.equal(countActiveZones(), #shop.locations, 'a restarted kora_target instance does not remove targets registered after its stop')

H.finish()
