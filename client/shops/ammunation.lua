-- Ammu-Nation world presentation. These zones are UX only: selecting this
-- option supplies just the fixed shop ID to qbinventory's normal transport.
-- The server repeats all location and routing-bucket validation before it
-- opens the session, so triggering this event away from a counter is harmless.

local shop = assert(Config.qbinventory and Config.qbinventory.shops and Config.qbinventory.shops.ammunation,
    'qbinventory Ammu-Nation configuration is required')

local function openAmmunation()
    exports.qbinventory:openInventory('shop', shop.id)
end

RegisterNetEvent('qbinventory:client:openAmmunation', openAmmunation)

for index, location in ipairs(shop.locations or {}) do
    local zoneName = ('qbinventory:ammunation:%d'):format(index)
    QB.interact.addCircleZone(zoneName, {
        x = location.x,
        y = location.y,
        z = location.z,
    }, shop.interactionDistance, {
        {
            label = ('Browse %s'):format(shop.label),
            icon = 'shopping-basket',
            action = openAmmunation,
        },
    }, false)

    if shop.blip and shop.blip.enabled then
        QB.blips.create({ x = location.x, y = location.y, z = location.z }, shop.blip)
    end
end
