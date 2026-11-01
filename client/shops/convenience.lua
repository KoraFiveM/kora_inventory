-- Convenience-store world presentation. These zones are UX only: selecting this
-- option supplies just the fixed shop ID to kora_inventory's normal transport.
-- The server repeats all location and routing-bucket validation before it
-- opens the session, so triggering this event away from a counter is harmless.

local shop = assert(
    Config.qbinventory and Config.qbinventory.shops and Config.qbinventory.shops.convenience,
    'qbinventory convenience store configuration is required'
)
local targetIds = {}
local enabled = shop.enabled ~= false

local function openConvenienceStore()
    exports.kora_inventory:openInventory('shop', shop.id)
end

RegisterNetEvent('qbinventory:client:openConvenienceStore', function()
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    openConvenienceStore()
end)

local function registerConvenienceStoreTargets()
    if not enabled then return end
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
                    label = ('Open shop (%s)'):format(location.name),
                    icon = 'basket-shopping',
                    onSelect = openConvenienceStore,
                },
            },
        }, location))
    end
end

registerConvenienceStoreTargets()
AddEventHandler('onClientResourceStart', function(resource)
    if resource == 'kora_target' then
        registerConvenienceStoreTargets()
    end
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource == 'kora_target' then
        targetIds = {}
    end
end)

for _, location in ipairs(enabled and shop.locations or {}) do
    if shop.blip and shop.blip.enabled then
        local blip = QbInventory.createShopBlip(Config.qbinventory.shops.convenience.blip.category, { x = location.x, y = location.y, z = location.z }, {
            sprite = shop.blip.sprite,
            color = shop.blip.color,
            scale = shop.blip.scale,
            shortRange = shop.blip.shortRange,
            category = shop.blip.category,
            name = location.name,
            info = shop.blip.info,
        })
        if blip and not shop.blip.info then
            Kora.blips.setInfo(blip, {
                title = location.name,
                rows = {
                    { kind = 'wrappedText', value = "Browse this store's snacks, drinks and supplies." },
                },
            })
        end
    end
end
