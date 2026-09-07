-- Rob's Liquor world presentation. These zones are UX only: selecting this
-- option supplies just the fixed shop ID to qbinventory's normal transport.
-- The server repeats all location and routing-bucket validation before it
-- opens the session, so triggering this event away from a counter is harmless.

local shop = assert(Config.qbinventory and Config.qbinventory.shops and Config.qbinventory.shops.liquorstore,
    'qbinventory liquor store configuration is required')

local function openLiquorStore()
    exports.qbinventory:openInventory('shop', shop.id)
end

RegisterNetEvent('qbinventory:client:openLiquorStore', openLiquorStore)

local function registerLiquorStoreTargets()
    for _, location in ipairs(shop.locations or {}) do
        exports.qbtarget:addSphereZone({
            coords = { x = location.x, y = location.y, z = location.z },
            radius = shop.interactionDistance,
            options = {
                {
                    label = ('Browse %s'):format(shop.label),
                    icon = 'wine',
                    onSelect = openLiquorStore,
                },
            },
        })
    end
end

registerLiquorStoreTargets()
AddEventHandler('onClientResourceStart', function(resource)
    if resource == 'qbtarget' then registerLiquorStoreTargets() end
end)

for _, location in ipairs(shop.locations or {}) do
    if shop.blip and shop.blip.enabled then
        QB.blips.create({ x = location.x, y = location.y, z = location.z }, shop.blip)
    end
end
