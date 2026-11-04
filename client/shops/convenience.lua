-- Convenience-store world presentation. These zones are UX only: selecting this
-- option supplies just the fixed shop ID to kora_inventory's normal transport.
-- The server repeats all location and routing-bucket validation before it
-- opens the session, so triggering this event away from a counter is harmless.

local shop = assert(
    Config.qbinventory and Config.qbinventory.shops and Config.qbinventory.shops.convenience,
    'qbinventory convenience store configuration is required'
)
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

local targets = QbInventory.shopLocationTargets(shop, function(location)
    return {
        {
            label = ('Open shop (%s)'):format(location.name),
            icon = 'basket-shopping',
            onSelect = openConvenienceStore,
            -- The clerk ped offers the same option while it is spawned.
            canInteract = function() return not QbInventory.shopClerkActive(location) end,
        },
    }
end)

local function registerConvenienceStoreTargets()
    if not enabled then return end
    targets.register()
end

registerConvenienceStoreTargets()
AddEventHandler('onClientResourceStart', function(resource)
    if resource == 'kora_target' then
        registerConvenienceStoreTargets()
    end
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource == 'kora_target' then
        targets.clear()
    end
end)

if enabled then
    QbInventory.shopLocationBlips(shop, Config.qbinventory.shops.convenience.blip.category,
        function(location)
            return {
                sprite = shop.blip.sprite,
                color = shop.blip.color,
                scale = shop.blip.scale,
                shortRange = shop.blip.shortRange,
                category = shop.blip.category,
                name = location.name,
                info = shop.blip.info,
            }
        end,
        function(location)
            return {
                title = location.name,
                rows = {
                    { kind = 'wrappedText', value = "Browse this store's snacks, drinks and supplies." },
                },
            }
        end)
end
