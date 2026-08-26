-- Server-authoritative vending machine registration.
--
-- Unlike Ammu-Nation (server/shops/ammunation.lua), there is no fixed
-- location list to check the source against -- a vending machine is any
-- `Config.qbinventory.shops.vendingmachine.models` prop a mapper placed
-- anywhere, and FXServer has no way to independently query a static map
-- prop's position; only networked entities are server-visible. Real
-- qb-inventory accepts exactly this trade-off (github.com/qbcore-fivem/
-- qb-inventory, server/main.lua's openVending -> OpenShop distance check
-- against client-supplied coords) rather than inventing a stronger guarantee
-- the platform can't back up, and this module matches that same bar.
--
-- The client-reported coordinates are trusted only as far as "the source's
-- own live server position is actually near here right now" -- a forged
-- coordinate still has to be within `shop.interactionDistance` of where the
-- server independently believes the player is. Once verified, the approval
-- is remembered for a short window so mid-purchase session revalidation
-- (qbinventory's own validSession, which re-checks access on every transfer
-- but has no fresh client data to offer) doesn't kick the player out for
-- continuing a purchase they already legitimately started.

local shop = assert(Config.qbinventory and Config.qbinventory.shops and Config.qbinventory.shops.vendingmachine,
    'qbinventory vending machine configuration is required')

local approvals = {} -- source -> GetGameTimer() expiry

local function hasValidCoords(coords)
    return type(coords) == 'table'
        and type(coords.x) == 'number' and type(coords.y) == 'number' and type(coords.z) == 'number'
end

local function isNearMachine(source, coords)
    return hasValidCoords(coords) and QB.distance.player(source, coords, shop.interactionDistance)
end

local function access(source, inventory, opts)
    if not inventory or inventory.type ~= 'shop' or inventory.id ~= shop.id then
        return false, 'invalid shop'
    end

    -- Fresh coordinates only ever arrive on the initial open request (see
    -- client/shops/vendingmachine.lua); a bare open with no coords always
    -- fails here rather than silently falling through to the approval cache.
    if opts and opts.coords ~= nil then
        if not isNearMachine(source, opts.coords) then return false, 'not at a vending machine' end
        approvals[source] = GetGameTimer() + (Config.qbinventory.sessionTtl or 120000)
        return true
    end

    local expiry = approvals[source]
    if not expiry or GetGameTimer() > expiry then return false, 'not at a vending machine' end
    return true
end

AddEventHandler('playerDropped', function() approvals[source] = nil end)

local shopKey = exports.qbinventory:RegisterShop(shop.id, {
    label = shop.label,
    slots = shop.slots,
    maxWeight = shop.maxWeight,
    currency = shop.currency,
    inventory = shop.inventory,
    access = access,
})

return {
    id = shop.id,
    key = shopKey,
    access = access,
    isNearMachine = isNearMachine,
}
