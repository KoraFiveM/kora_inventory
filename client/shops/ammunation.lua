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

local function registerAmmunationTargets()
    for _, location in ipairs(shop.locations or {}) do
        exports.qbtarget:addSphereZone({
            coords = { x = location.x, y = location.y, z = location.z },
            radius = shop.interactionDistance,
            options = {
                {
                    label = ('Browse %s'):format(shop.label),
                    icon = 'shopping-basket',
                    onSelect = openAmmunation,
                },
            },
        })
    end
end

registerAmmunationTargets()
AddEventHandler('onClientResourceStart', function(resource)
    if resource == 'qbtarget' then registerAmmunationTargets() end
end)

for _, location in ipairs(shop.locations or {}) do
    if shop.blip and shop.blip.enabled then
        local blip = QB.blips.create({ x = location.x, y = location.y, z = location.z }, shop.blip)
        if blip and not shop.blip.info then
            QB.blips.setInfo(blip, {
                title = shop.label,
                rows = {
                    { kind = 'wrappedText', value = 'Browse this store\'s available weapons and equipment.' },
                },
            })
        end
    end
end
