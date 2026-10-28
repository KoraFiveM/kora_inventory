-- Liquor counters share one finite-stock shop -- the same shape as
-- Ammu-Nation, and for the same reasons. The location list is duplicated
-- deliberately: client/shops/liquorstore.lua uses it only to present local
-- interaction zones and blips, while server/shops/liquorstore.lua
-- independently verifies the source's live server position and routing bucket
-- before every open.
--
-- Keep stock rows declarative. server.lua turns each row into the canonical
-- registry-backed item record (label, image, weight, unique and metadata) at
-- registration time; never copy those presentation/authority fields here.
--
-- Every stock row must be a real item in kora_core's shared registry. Nothing new
-- is invented here: a liquor store that stocked ids the registry has never
-- heard of would present unbuyable slots with no label and no weight.

Config = Config or {}
Config.qbinventory = Config.qbinventory or {}
Config.qbinventory.shops = Config.qbinventory.shops or {}

Config.qbinventory.shops.liquorstore = {
    id = 'liquorstore',
    label = 'Liquor',
    slots = 16,
    maxWeight = 30000,
    currency = 'cash',
    interactionDistance = 2.25,
    blip = {
        enabled = true,
        sprite = 93,
        color = 21,
        scale = 0.7,
        shortRange = true,
        -- The category groups all liquor shops; the name identifies this
        -- storefront without forcing every liquor shop to share its brand.
        category = 'Liquor',
    },

    inventory = {
        -- Alcohol
        { name = 'beer', amount = 60, price = 12 },
        { name = 'whiskey', amount = 30, price = 45 },

        -- Soft drinks
        { name = 'water_bottle', amount = 80, price = 8 },
        { name = 'soda', amount = 60, price = 10 },

        -- Counter snacks
        { name = 'chocolate_bar', amount = 50, price = 14 },
        { name = 'sandwich', amount = 30, price = 18 },
        { name = 'bread', amount = 40, price = 9 },
    },

    -- Counter positions. Each entry needs an explicit `bucket`: the server-side
    -- access check fails closed on a missing or non-numeric one rather than
    -- widening the shop's opening surface (see server/shops/liquorstore.lua).
    locations = {
        { name = "Rob's Liquor", x = 1135.81, y = -982.28, z = 46.42, heading = 280.0, bucket = 0 }, -- Little Bighorn Ave
        { name = "Rob's Liquor", x = -1222.92, y = -906.98, z = 12.33, heading = 30.0, bucket = 0 }, -- Prosperity St, Vespucci
        { name = "Rob's Liquor", x = -1487.55, y = -379.11, z = 40.16, heading = 135.0, bucket = 0 }, -- San Andreas Ave, Morningwood
        { name = "Rob's Liquor", x = -2968.24, y = 390.91, z = 15.04, heading = 85.0, bucket = 0 }, -- Great Ocean Hwy, Chumash
        { name = "Rob's Liquor", x = 1166.02, y = 2708.93, z = 38.16, heading = 180.0, bucket = 0 }, -- Route 68, Harmony
        { name = '24/7', x = 24.50, y = -1346.19, z = 29.50, heading = 266.78, bucket = 0 }, -- Strawberry
        { name = '24/7', x = 373.18, y = 326.51, z = 103.57, heading = 255.77, bucket = 0 }, -- Clinton Ave
    },
}
