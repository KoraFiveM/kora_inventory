-- Repeated kora_target starts must replace, not duplicate, convenience-store options.
local H = dofile('test/harness.lua')

Config = { qbinventory = {} }
dofile('config/shops/convenience.lua')
dofile('shared.lua')

local shop = Config.qbinventory.shops.convenience
shop.locations = {
    { name = "24/7", x = 10, y = 20, z = 30 },
    { name = '24/7', x = 40, y = 50, z = 60 },
}

local handlers, activeZones, nextId = {}, {}, 0
RegisterNetEvent = function() end
AddEventHandler = function(name, callback)
    handlers[name] = handlers[name] or {}
    handlers[name][#handlers[name] + 1] = callback
end

exports = {
    kora_inventory = { openInventory = function() end },
    kora_target = {
        addSphereZone = function(_, options)
            nextId = nextId + 1
            activeZones[nextId] = options
            return nextId
        end,
        removeZone = function(_, id)
            activeZones[id] = nil
            return true
        end,
    },
}
local createdBlips = {}
Kora = { blips = {
    create = function(_, options)
        createdBlips[#createdBlips + 1] = options
        return #createdBlips
    end,
    setInfo = function() return true end,
} }
dofile('client/shops/convenience.lua')

local function activeZoneCount()
    local count = 0
    for _ in pairs(activeZones) do count = count + 1 end
    return count
end

for _, callback in ipairs(handlers.onClientResourceStart or {}) do callback('kora_target') end
for _, callback in ipairs(handlers.onClientResourceStart or {}) do callback('kora_target') end
H.equal(activeZoneCount(), #shop.locations, 'repeated target starts leave one shop option at each counter')
H.equal(createdBlips[1].category, 'Convenience Store', '24/7 blips use the convenience category')
H.equal(createdBlips[1].name, "24/7", 'the first blip uses its location storefront')
H.equal(createdBlips[2].name, '24/7', 'the second blip uses its location storefront')
H.equal(createdBlips[1].label, nil, 'the caller leaves map-label composition to kora_lib')

H.finish()
