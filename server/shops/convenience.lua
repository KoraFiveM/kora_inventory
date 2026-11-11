-- Server-authoritative Convenience store registration.
--
-- This file has no network event. The generic kora_inventory open transport may
-- receive a client request for `shop:convenience`, but RegisterShop's access
-- callback below re-resolves the player's ped, routing bucket and position on
-- the server before every open and every session revalidation -- so triggering
-- the client zone's action away from a counter is harmless.
--
-- The "must be standing at one of these counters" policy itself lives in
-- server/shops/location_policy.lua, shared with ammunation.lua and
-- liquorstore.lua.

local shop = assert(
    Config.kora_inventory and Config.kora_inventory.shops and Config.kora_inventory.shops.convenience,
    'kora_inventory convenience store configuration is required'
)

if shop.enabled == false then
    return nil
end

local function isAtApprovedLocation(source)
    return isAtApprovedShopLocation(shop, source, 'not at a convenience store counter')
end

local function access(source, inventory)
    -- Avoid turning this callback into a generic location policy if somebody
    -- reuses it on another inventory by mistake.
    if not inventory or inventory.type ~= 'shop' or inventory.id ~= shop.id then
        return false, 'invalid shop'
    end
    return isAtApprovedLocation(source)
end

local shopKey = exports.kora_inventory:RegisterShop(shop.id, {
    label = shop.label,
    slots = shop.slots,
    maxWeight = shop.maxWeight,
    currency = shop.currency,
    inventory = shop.inventory,
    access = access,
})

-- Returning the narrow policy surface makes deterministic smoke coverage and
-- server integrations possible without making a new client-facing API.
return {
    id = shop.id,
    key = shopKey,
    access = access,
    isAtApprovedLocation = isAtApprovedLocation,
}
