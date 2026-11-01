-- A bad configured blip category must warn once, fall back to no category and
-- must not abort the blip loop.
local H = dofile("test/harness.lua")

Config = { qbinventory = {} }
dofile("shared.lua")

local created, warnings = {}, {}
Kora = { blips = { create = function(_, options)
    if options.category == "Convenience Store" then
        error("Unknown blip category Convenience Store.")
    end
    created[#created + 1] = options
    return #created
end } }
local realPrint = print
print = function(message) warnings[#warnings + 1] = message end

local blip = QbInventory.createShopBlip("Config.x.blip.category", { x = 1, y = 2, z = 3 },
    { category = "Convenience Store", name = "24/7" })
print = realPrint

H.equal(blip, 1, "blip is still created after a bad category")
H.equal(created[1].category, nil, "fallback blip has no category")
H.equal(created[1].name, "24/7", "fallback keeps other options")
H.equal(#warnings, 1, "one warning is logged")
H.equal(warnings[1]:find("Config.x.blip.category", 1, true) ~= nil and warnings[1]:find("Convenience Store", 1, true) ~= nil, true, "warning names option and value")

H.finish()
