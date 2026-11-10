-- Ammu-Nation shopkeeper peds: on by default for every store, configurable per
-- store, spawned at floor height minus the ped root offset, and deferred to a
-- resource that supplies its own clerk (kora_mdt at Legion Square).
local H = dofile("test/harness.lua")

Config = { kora_inventory = {} }
dofile("config/shops/ammunation.lua")
dofile("shared.lua")
local shop = Config.kora_inventory.shops.ammunation

H.equal(shop.shopkeeper.enabled, true, "shopkeepers default on")
H.equal(shop.limitedStock, true, "stock is limited by default")
H.equal(shop.restockIntervalMinutes, 30, "stock refills every 30 minutes by default")

local expectedPeds = {
    ["-661.67,-933.26"] = 175.79, ["809.26,-2159.28"] = 352.70, ["1692.49,3761.49"] = 226.57,
    ["-331.27,6085.68"] = 225.48, ["253.64,-51.28"] = 69.81, ["2567.27,292.41"] = 358.82,
    ["-1118.68,2700.34"] = 221.58, ["841.78,-1035.43"] = 1.50, ["-1304.09,-395.16"] = 71.33,
    ["-3173.48,1089.19"] = 243.41, ["23.24,-1105.29"] = 159.43,
}
local found = 0
for _, location in ipairs(shop.locations) do
    H.ok(location.ped, "every store has a shopkeeper spot")
    local key = ("%.2f,%.2f"):format(location.ped.x, location.ped.y)
    H.equal(expectedPeds[key], location.ped.heading, "ped heading for " .. key)
    found = found + 1
    if location.x == -1305.58 then H.equal(location.y, -394.77, "Morningwood marker corrected") end
    if location.x == -3172.04 then H.equal(location.y, 1088.26, "Chumash marker corrected") end
end
H.equal(found, 11, "all eleven stores are configured")

local handlers, spawned, running = {}, {}, {}
RegisterNetEvent = function() end
AddEventHandler = function(name, callback)
    handlers[name] = handlers[name] or {}
    handlers[name][#handlers[name] + 1] = callback
end
local threads = {}
CreateThread = function(fn) threads[#threads + 1] = fn end
Wait = function() end
GetCurrentResourceName = function() return "kora_inventory" end
GetResourceState = function(name) return running[name] and "started" or "missing" end
exports = {
    kora_inventory = { openInventory = function() end },
    kora_target = { addSphereZone = function() return 1 end, removeZone = function() end },
}
Kora = {
    blips = {},
    entities = { createScoped = function(model, coords, options)
        local entry = { model = model, coords = coords, options = options, removed = false }
        spawned[#spawned + 1] = entry
        return { remove = function() entry.removed = true end }
    end },
}
shop.blip.enabled = false
dofile("client/shops/ammunation.lua")
local function live()
    local out = {}
    for _, entry in ipairs(spawned) do if not entry.removed then out[#out + 1] = entry end end
    return out
end
local function start()
    for _, fn in ipairs(threads) do fn() end
    threads = {}
end

start()
H.equal(#live(), 11, "every store gets a ped when nothing else supplies a clerk")
local legion
for _, entry in ipairs(live()) do
    H.equal(entry.options.preset, "static", "the clerk is frozen and invincible")
    H.equal(entry.model, "s_m_m_ammucountry", "the configured model is used")
    if entry.coords.x == 23.24 then legion = entry end
end
H.equal(legion.coords.z, 28.80, "ped spawns 1.0 below the configured floor height")
H.equal(legion.coords.heading, 159.43, "Legion Square ped faces the configured heading")

-- kora_mdt running: Legion Square keeps its records clerk only.
running.kora_mdt = true
for _, callback in ipairs(handlers.onClientResourceStart) do callback("kora_mdt") end
H.equal(#live(), 10, "no second ped at Legion Square while kora_mdt supplies the clerk")
running.kora_mdt = nil
for _, callback in ipairs(handlers.onClientResourceStop) do callback("kora_mdt") end
H.equal(#live(), 11, "the shop ped returns when kora_mdt stops")
for _, callback in ipairs(handlers.onClientResourceStart) do callback("kora_target") end
H.equal(#live(), 11, "unrelated resources do not respawn the peds")

-- Per-store and global opt-outs.
shop.locations[1].shopkeeper = false
for _, callback in ipairs(handlers.onClientResourceStop) do callback("kora_mdt") end
H.equal(#live(), 10, "a store can opt out of its ped")
shop.shopkeeper.enabled = false
for _, callback in ipairs(handlers.onClientResourceStop) do callback("kora_mdt") end
H.equal(#live(), 0, "shopkeeper.enabled = false removes every ped")

H.finish()
