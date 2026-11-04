-- Liquor-store world presentation. These zones are UX only: selecting this
-- option supplies just the fixed shop ID to kora_inventory's normal transport.
-- The server repeats all location and routing-bucket validation before it
-- opens the session, so triggering this event away from a counter is harmless.

local shop = assert(
    Config.qbinventory and Config.qbinventory.shops and Config.qbinventory.shops.liquorstore,
    'qbinventory liquor store configuration is required'
)

local function openLiquorStore()
    exports.kora_inventory:openInventory('shop', shop.id)
end

RegisterNetEvent('qbinventory:client:openLiquorStore', function()
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    openLiquorStore()
end)

local targets = QbInventory.shopLocationTargets(shop, function(location)
    return {
        {
            label = ('Browse %s'):format(location.name),
            icon = 'wine',
            onSelect = openLiquorStore,
            -- The clerk ped offers the same option while it is spawned.
            canInteract = function() return not QbInventory.shopClerkActive(location) end,
        },
    }
end)

targets.register()
AddEventHandler('onClientResourceStart', function(resource)
    if resource == 'kora_target' then
        targets.register()
    end
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource == 'kora_target' then
        targets.clear()
    end
end)

QbInventory.shopLocationBlips(shop, Config.qbinventory.shops.liquorstore.blip.category,
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
                { kind = 'wrappedText', value = "Browse this store's available drinks and supplies." },
            },
        }
    end)
