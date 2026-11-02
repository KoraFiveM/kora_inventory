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

-- Shopkeeper peds (Config.qbinventory.shops.ammunation.shopkeeper). Purely
-- presentation: they are scoped local entities that exist only while the
-- player is near, and the server never trusts them.
local shopkeepers = {}
local stoppedResources = {}

local function resourceRunning(name)
    if stoppedResources[name] then
        return false
    end
    return type(GetResourceState) == 'function' and GetResourceState(name) == 'started'
end

local function shopkeeperSpot(location)
    local options = shop.shopkeeper
    if type(options) ~= 'table' or options.enabled == false then
        return nil
    end
    if location.shopkeeper == false or type(location.ped) ~= 'table' then
        return nil
    end
    if location.shopkeeperUnlessStarted and resourceRunning(location.shopkeeperUnlessStarted) then
        return nil
    end
    return location.ped, options
end

local function refreshShopkeepers()
    for _, handle in ipairs(shopkeepers) do
        handle.remove()
    end
    shopkeepers = {}

    for _, location in ipairs(shop.locations or {}) do
        local ped, options = shopkeeperSpot(location)
        if ped then
            local ok, handle = pcall(Kora.entities.createScoped, options.model or 's_m_m_ammucountry', {
                x = ped.x,
                y = ped.y,
                -- Config z is floor height; a ped is positioned by its root.
                z = ped.z - 1.0,
                heading = ped.heading,
            }, {
                preset = 'static',
                radius = tonumber(options.radius) or 60.0,
            })
            if ok and handle then
                shopkeepers[#shopkeepers + 1] = handle
            else
                print(('^3[kora_inventory]^7 Ammu-Nation shopkeeper could not be registered: %s'):format(tostring(handle)))
            end
        end
    end
end

CreateThread(function()
    -- Give resources named by shopkeeperUnlessStarted a moment to start.
    Wait(2000)
    refreshShopkeepers()
end)

-- Only a resource a location defers to can change which peds exist.
local function isDeferredTo(resource)
    for _, location in ipairs(shop.locations or {}) do
        if location.shopkeeperUnlessStarted == resource then
            return true
        end
    end
    return false
end

AddEventHandler('onClientResourceStart', function(resource)
    stoppedResources[resource] = nil
    if isDeferredTo(resource) then
        refreshShopkeepers()
    end
end)

AddEventHandler('onClientResourceStop', function(resource)
    if isDeferredTo(resource) then
        stoppedResources[resource] = true
        refreshShopkeepers()
    end
end)

for _, location in ipairs(shop.locations or {}) do
    if shop.blip and shop.blip.enabled then
        local blip = QbInventory.createShopBlip(Config.qbinventory.shops.ammunation.blip.category, { x = location.x, y = location.y, z = location.z }, shop.blip)
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
