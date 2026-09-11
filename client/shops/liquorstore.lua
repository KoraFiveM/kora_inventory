-- Liquor-store world presentation. These zones are UX only: selecting this
-- option supplies just the fixed shop ID to qbinventory's normal transport.
-- The server repeats all location and routing-bucket validation before it
-- opens the session, so triggering this event away from a counter is harmless.

local shop = assert(
    Config.qbinventory and Config.qbinventory.shops and Config.qbinventory.shops.liquorstore,
    'qbinventory liquor store configuration is required'
)
local targetIds = {}

local function openLiquorStore()
    exports.qbinventory:openInventory('shop', shop.id)
end

RegisterNetEvent('qbinventory:client:openLiquorStore', function()
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    openLiquorStore()
end)

local function registerLiquorStoreTargets()
    for _, targetId in ipairs(targetIds) do
        exports.qbtarget:removeZone(targetId)
    end
    targetIds = {}

    for _, location in ipairs(shop.locations or {}) do
        targetIds[#targetIds + 1] = exports.qbtarget:addSphereZone({
            coords = { x = location.x, y = location.y, z = location.z },
            radius = shop.interactionDistance,
            options = {
                {
                    label = ('Browse %s'):format(location.name),
                    icon = 'wine',
                    onSelect = openLiquorStore,
                },
            },
        })
    end
end

registerLiquorStoreTargets()
AddEventHandler('onClientResourceStart', function(resource)
    if resource == 'qbtarget' then
        registerLiquorStoreTargets()
    end
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource == 'qbtarget' then
        targetIds = {}
    end
end)

for _, location in ipairs(shop.locations or {}) do
    if shop.blip and shop.blip.enabled then
        local blip = QB.blips.create({ x = location.x, y = location.y, z = location.z }, {
            sprite = shop.blip.sprite,
            color = shop.blip.color,
            scale = shop.blip.scale,
            shortRange = shop.blip.shortRange,
            category = shop.blip.category,
            name = location.name,
            info = shop.blip.info,
        })
        if blip and not shop.blip.info then
            QB.blips.setInfo(blip, {
                title = location.name,
                rows = {
                    { kind = 'wrappedText', value = "Browse this store's available drinks and supplies." },
                },
            })
        end
    end
end
