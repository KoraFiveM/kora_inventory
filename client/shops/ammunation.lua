-- Ammu-Nation world presentation. These zones are UX only: selecting this
-- option supplies just the fixed shop ID to kora_inventory's normal transport.
-- The server repeats all location and routing-bucket validation before it
-- opens the session, so triggering this event away from a counter is harmless.

local shop = assert(
    Config.qbinventory and Config.qbinventory.shops and Config.qbinventory.shops.ammunation,
    'qbinventory Ammu-Nation configuration is required'
)
local targetIds = {}

local function openAmmunation()
    exports.kora_inventory:openInventory('shop', shop.id)
end

RegisterNetEvent('qbinventory:client:openAmmunation', function()
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    openAmmunation()
end)

local function registerAmmunationTargets()
    for _, targetId in ipairs(targetIds) do
        exports.kora_target:removeZone(targetId)
    end
    targetIds = {}

    for _, location in ipairs(shop.locations or {}) do
        targetIds[#targetIds + 1] = exports.kora_target:addSphereZone(QbInventory.shopZoneSprite({
            coords = { x = location.x, y = location.y, z = location.z },
            radius = shop.interactionDistance,
            options = {
                {
                    label = ('Browse %s'):format(shop.label),
                    icon = 'shopping-basket',
                    onSelect = openAmmunation,
                },
            },
        }, location))
    end
end

registerAmmunationTargets()
AddEventHandler('onClientResourceStart', function(resource)
    if resource == 'kora_target' then
        registerAmmunationTargets()
    end
end)

AddEventHandler('onClientResourceStop', function(resource)
    -- kora_target removes every zone it owns on stop. Forget the stale IDs so a
    -- new kora_target instance cannot mistake a reused ID for one of ours.
    if resource == 'kora_target' then
        targetIds = {}
    end
end)

for _, location in ipairs(shop.locations or {}) do
    if shop.blip and shop.blip.enabled then
        local blip = Kora.blips.create({ x = location.x, y = location.y, z = location.z }, shop.blip)
        if blip and not shop.blip.info then
            Kora.blips.setInfo(blip, {
                title = shop.label,
                rows = {
                    { kind = 'wrappedText', value = "Browse this store's available weapons and equipment." },
                },
            })
        end
    end
end
