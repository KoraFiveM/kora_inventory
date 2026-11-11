-- World presentation only. kora_target's addModel matches every currently- and
-- future-streamed prop of these models anywhere on the map (unlike kora_lib's
-- own Kora.interact.addTargetModel, a one-shot snapshot of what's streamed in
-- at call time) -- exactly what a feature with no curated location list
-- needs. The reported entity's own coordinates travel with the open request
-- so the server can bounds-check them (see server/shops/vendingmachine.lua);
-- selecting this away from a real machine is harmless on its own since the
-- server still re-derives the player's actual position independently.

local shop = assert(
    Config.kora_inventory and Config.kora_inventory.shops and Config.kora_inventory.shops.vendingmachine,
    'kora_inventory vending machine configuration is required'
)

-- Registered again whenever kora_target (re)starts: its registrations do not
-- survive a restart, and a call at load would throw if it were not running.
local registered = false
local function registerVendingTargets()
    if registered then return end
    if type(GetResourceState) == 'function' and GetResourceState('kora_target') ~= 'started' then
        return
    end
    local ok, id = pcall(function()
        return exports.kora_target:addModel(shop.models, {
            {
                label = ('Browse %s'):format(shop.label),
                icon = 'shopping-basket',
                onSelect = function(entity)
                    local coords = GetEntityCoords(entity)
                    exports.kora_inventory:openInventory('shop', {
                        id = shop.id,
                        coords = { x = coords.x, y = coords.y, z = coords.z },
                    })
                end,
            },
        }, shop.interactionDistance)
    end)
    if ok and id then
        registered = true
    else
        print(('[kora_inventory] Failed to register vending targets: %s'):format(tostring(id)))
    end
end

registerVendingTargets()

AddEventHandler('onClientResourceStart', function(resource)
    if resource == 'kora_target' then
        registerVendingTargets()
    end
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource == 'kora_target' then registered = false end
end)
