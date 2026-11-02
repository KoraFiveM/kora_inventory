-- Config.showTargetHints -> kora_target drawSprite, and the counter spriteCoords
-- each shop zone is registered with.
local H = dofile('test/harness.lua')

Config = { qbinventory = {} }
dofile('config/shops/liquorstore.lua')
dofile('config/shops/ammunation.lua')
dofile('shared.lua')

local location = { x = 1.0, y = 2.0, z = 3.0 }

Config.showTargetHints = nil
local zone = QbInventory.shopZoneSprite({}, location)
H.equal(zone.drawSprite, nil, 'nil passes no drawSprite so kora_target decides')
H.equal(zone.spriteCoords.x, 1.0, 'the icon sits at the counter')
H.equal(zone.spriteCoords.z, 3.0, 'including its height')

Config.showTargetHints = true
H.equal(QbInventory.shopZoneSprite({}, location).drawSprite, true, 'true forces the icon on')

Config.showTargetHints = false
H.equal(QbInventory.shopZoneSprite({}, location).drawSprite, false, 'false forces the icon off')

Config.showTargetHints = nil
local override = QbInventory.shopZoneSprite({}, { x = 1, y = 2, z = 3, spriteCoords = { x = 9, y = 9, z = 9 } })
H.equal(override.spriteCoords.x, 9, 'a location can override the icon position')

-- The shop clients pass it through when they register.
local zones = {}
RegisterNetEvent = function() end
CreateThread = function() end
GetCurrentResourceName = function() return "kora_inventory" end
AddEventHandler = function() end
exports = {
    kora_inventory = { openInventory = function() end },
    kora_target = {
        addSphereZone = function(_, options) zones[#zones + 1] = options; return #zones end,
        removeZone = function() end,
    },
}
Kora = { blips = { create = function() return 1 end, setInfo = function() end } }

for _, file in ipairs({ 'client/shops/liquorstore.lua', 'client/shops/ammunation.lua' }) do
    for _, hint in ipairs({ 'unset', true, false }) do
        zones = {}
        Config.showTargetHints = hint ~= 'unset' and hint or nil
        dofile(file)
        H.ok(#zones > 0, file .. ' registers zones')
        H.ok(zones[1].spriteCoords, file .. ' gives each zone a spriteCoords')
        H.equal(zones[1].drawSprite, hint ~= 'unset' and hint or nil, file .. ' maps showTargetHints=' .. tostring(hint))
    end
end

H.finish()
