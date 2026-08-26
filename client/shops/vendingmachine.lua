-- World presentation only. qbtarget's addModel matches every currently- and
-- future-streamed prop of these models anywhere on the map (unlike qblib's
-- own QB.interact.addTargetModel, a one-shot snapshot of what's streamed in
-- at call time) -- exactly what a feature with no curated location list
-- needs. The reported entity's own coordinates travel with the open request
-- so the server can bounds-check them (see server/shops/vendingmachine.lua);
-- selecting this away from a real machine is harmless on its own since the
-- server still re-derives the player's actual position independently.

local shop = assert(Config.qbinventory and Config.qbinventory.shops and Config.qbinventory.shops.vendingmachine,
    'qbinventory vending machine configuration is required')

exports.qbtarget:addModel(shop.models, {
    {
        label = ('Browse %s'):format(shop.label),
        icon = 'shopping-basket',
        onSelect = function(entity)
            local coords = GetEntityCoords(entity)
            exports.qbinventory:openInventory('shop', {
                id = shop.id,
                coords = { x = coords.x, y = coords.y, z = coords.z },
            })
        end,
    },
}, shop.interactionDistance)
