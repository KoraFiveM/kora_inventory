-- Test helper: loads server/shops/location_policy.lua (the manifest loads it before the
-- shop files; they call its global isAtApprovedShopLocation) with a Kora.util.nearest stub.
-- Run from the repo root, after the test defined GetPlayerPed/GetEntityCoords/etc.:
--   dofile('test/shop_location_policy.lua')
Kora = Kora or {}
Kora.util = Kora.util or {}
Kora.util.nearest = function(list, position, opts)
    local best, bestDistance
    for _, entry in pairs(list) do
        if opts.bucketOf == nil or opts.bucketOf(entry) == opts.bucket then
            local dx, dy, dz = position.x - entry.x, position.y - entry.y, position.z - entry.z
            local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
            if (opts.radius == nil or distance <= opts.radius) and (bestDistance == nil or distance < bestDistance) then
                best, bestDistance = entry, distance
            end
        end
    end
    return best, bestDistance
end
dofile('server/shops/location_policy.lua')
