-- Server-authoritative Ammu-Nation registration.
--
-- This file has no network event. The generic kora_inventory open transport may
-- receive a client request for `shop:ammunation`, but RegisterShop's access
-- callback below re-resolves the player's ped, routing bucket and position on
-- the server before every open and every session revalidation.
--
-- The "must be standing at one of these counters" policy itself lives in
-- server/shops/location_policy.lua, shared with liquorstore.lua and
-- convenience.lua.

local shop = assert(
    Config.qbinventory and Config.qbinventory.shops and Config.qbinventory.shops.ammunation,
    'qbinventory Ammu-Nation configuration is required'
)

local function isAtApprovedLocation(source)
    return isAtApprovedShopLocation(shop, source, 'not at an Ammu-Nation counter')
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
    weightLimit = shop.weightLimit,
    currency = shop.currency,
    inventory = shop.inventory,
    access = access,
})

-- Restocking. Purchases deplete the shared shelf; this tops every configured
-- row back up to its declared amount (a row that sold out returns whole). It
-- only ever raises a level, never lowers one, and it goes through the same
-- locked shop-stock funnel as any other restock integration.
local function report(message, ...)
    print(('^3[kora_inventory]^7 Ammu-Nation restock: ' .. message):format(...))
end

local mismatchReported = {}
local function restock()
    local current, err = exports.kora_inventory:GetShopItems(shop.id)
    if not current then
        return false, err
    end
    local changes = {}
    for index, row in ipairs(shop.inventory or {}) do
        local slot = math.floor(tonumber(row.slot) or index)
        local stocked = current[slot]
        if not stocked then
            changes[#changes + 1] = { slot = slot, name = row.name, entry = { name = row.name, amount = row.amount, price = row.price } }
        elseif stocked.name ~= row.name then
            -- Persisted stock keeps its slots, so a reordered config leaves a
            -- different item here. Say so once instead of skipping silently.
            local seen = slot .. ':' .. tostring(stocked.name) .. ':' .. row.name
            if not mismatchReported[seen] then
                mismatchReported[seen] = true
                report('slot %d holds %s, not the configured %s; that row is not restocked', slot, tostring(stocked.name), row.name)
            end
        elseif stocked.amount < row.amount then
            local entry = {}
            for field, value in pairs(stocked) do entry[field] = value end
            entry.amount = row.amount
            changes[#changes + 1] = { slot = slot, name = row.name, entry = entry }
        end
    end
    if #changes == 0 then
        return true
    end
    local shelf = {}
    for slot, item in pairs(current) do shelf[slot] = item end
    for _, change in ipairs(changes) do shelf[change.slot] = change.entry end
    local ok, reason = exports.kora_inventory:SetShopItems(shop.id, shelf)
    if ok then
        return true
    end
    -- The shelf is written as a whole, so one bad row would block every
    -- other. Retry row by row: keep each row that fits and name each that
    -- does not (and why), instead of one bare reason for the whole shop.
    local failed = 0
    for _, change in ipairs(changes) do
        local previous = current[change.slot]
        current[change.slot] = change.entry
        local rowOk, rowReason = exports.kora_inventory:SetShopItems(shop.id, current)
        if not rowOk then
            current[change.slot] = previous
            failed = failed + 1
            report('slot %d (%s x%d) not restocked: %s', change.slot, change.name, change.entry.amount, tostring(rowReason))
        end
    end
    if failed > 0 then
        return false, ('%d of %d rows not restocked (%s)'):format(failed, #changes, tostring(reason))
    end
    return true
end

local function runRestock()
    local ok, restocked, reason = pcall(restock)
    if not ok or restocked == false then
        print(('^3[kora_inventory]^7 Ammu-Nation restock failed: %s'):format(tostring(ok and reason or restocked)))
    end
end

local restockQueued = false
if type(CreateThread) == 'function' and type(Wait) == 'function' then
    local minutes = tonumber(shop.restockIntervalMinutes) or 0
    if shop.limitedStock ~= false and minutes > 0 then
        -- One long sleep per interval; nothing runs in between.
        CreateThread(function()
            while true do
                Wait(math.floor(minutes * 60000))
                runRestock()
            end
        end)
    end
end
if shop.limitedStock == false and type(AddEventHandler) == 'function' then
    -- Unlimited stock: refill just after the purchase commits (the event fires
    -- inside the purchase lock, so it is deferred to avoid re-entering it).
    AddEventHandler('qbinventory:server:itemPurchased', function(_, purchase)
        if restockQueued or type(purchase) ~= 'table' or purchase.shopId ~= shop.id then
            return
        end
        restockQueued = true
        SetTimeout(0, function()
            restockQueued = false
            runRestock()
        end)
    end)
end

-- Returning the narrow policy surface makes deterministic smoke coverage and
-- server integrations possible without making a new client-facing API.
return {
    id = shop.id,
    key = shopKey,
    access = access,
    isAtApprovedLocation = isAtApprovedLocation,
    restock = restock,
}
