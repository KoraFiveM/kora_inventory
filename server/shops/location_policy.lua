-- Shared "must be standing at one of these counters" policy for location-gated
-- shops (ammunation.lua, liquorstore.lua, convenience.lua). Loads before all
-- three; see their file headers for why this was extracted rather than copied
-- a third time.

---Whether `source`'s ped is at one of `shop.locations`: matching routing
---bucket, within `shop.interactionDistance` (default 2.25). Every default
---location entry has an explicit bucket; a missing/invalid bucket or missing
---coordinates fails closed rather than widening the shop's opening surface.
---@param shop table
---@param source integer
---@param notAtLocationReason string
---@return boolean ok
---@return string? reason
function isAtApprovedShopLocation(shop, source, notAtLocationReason)
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return false, 'player entity unavailable'
    end

    local candidates = {}
    for _, location in ipairs(shop.locations or {}) do
        if
            type(location.bucket) == 'number'
            and type(location.x) == 'number'
            and type(location.y) == 'number'
            and type(location.z) == 'number'
        then
            candidates[#candidates + 1] = location
        end
    end

    local nearest = Kora.util.nearest(candidates, GetEntityCoords(ped), {
        radius = tonumber(shop.interactionDistance) or 2.25,
        bucketOf = function(location) return location.bucket end,
        bucket = GetPlayerRoutingBucket(source),
        coordsOf = function(location) return location end,
    })

    if nearest then
        return true
    end

    return false, notAtLocationReason
end
