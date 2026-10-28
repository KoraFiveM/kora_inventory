-- Server-authoritative Ammu-Nation registration.
--
-- This file has no network event. The generic kora_inventory open transport may
-- receive a client request for `shop:ammunation`, but RegisterShop's access
-- callback below re-resolves the player's ped, routing bucket and position on
-- the server before every open and every session revalidation.

local shop = assert(
    Config.qbinventory and Config.qbinventory.shops and Config.qbinventory.shops.ammunation,
    'qbinventory Ammu-Nation configuration is required'
)

local function distanceSquared(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return dx * dx + dy * dy + dz * dz
end

local function isAtApprovedLocation(source)
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return false, 'player entity unavailable'
    end

    local playerBucket = GetPlayerRoutingBucket(source)
    local playerCoords = GetEntityCoords(ped)
    local maximumDistance = tonumber(shop.interactionDistance) or 2.25
    local maximumDistanceSquared = maximumDistance * maximumDistance

    for _, location in ipairs(shop.locations or {}) do
        -- Every default entry has an explicit bucket. A missing/invalid bucket
        -- is a configuration error and therefore fails closed instead of
        -- widening the shop's opening surface.
        if
            type(location.bucket) == 'number'
            and playerBucket == location.bucket
            and type(location.x) == 'number'
            and type(location.y) == 'number'
            and type(location.z) == 'number'
            and distanceSquared(playerCoords, location) <= maximumDistanceSquared
        then
            return true
        end
    end

    return false, 'not at an Ammu-Nation counter'
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
