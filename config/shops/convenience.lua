-- Convenience stores (24/7) share one finite-stock shop, the same shape as the
-- liquor store. Before this existed only two 24/7 counters were reachable (as a
-- liquor storefront); every other 24/7 offered nothing but the robbery target.
-- The location list is duplicated deliberately: client/shops/convenience.lua
-- uses it only for interaction zones and blips, while server/shops/convenience.lua
-- independently verifies the live server position and routing bucket before
-- every open.
--
-- The zone sits on the counter, apart from kora_robberies register/safe zones,
-- so the 'Open shop' option never replaces the robbery options.
--
-- Config.qbinventory.shops.convenience.enabled = false removes the shop, its
-- targets and its blips (default true). Stock rows must be real items in
-- the kora_core shared registry; labels and weights come from the registry.

Config = Config or {}
Config.qbinventory = Config.qbinventory or {}
Config.qbinventory.shops = Config.qbinventory.shops or {}

Config.qbinventory.shops.convenience = {
    id = "convenience",
    label = "24/7",
    enabled = true,
    slots = 16,
    maxWeight = 30000,
    currency = "cash",
    interactionDistance = 2.25,
    blip = {
        enabled = true,
        sprite = 52,
        color = 2,
        scale = 0.7,
        shortRange = true,
        -- Must be a Kora.blips category (see Kora.blips.getCategories()), e.g.
        -- "Convenience". An unknown value logs a warning and the blip is
        -- created without a category instead of raising a script error.
        category = "Convenience",
    },

    inventory = {
        { name = "water_bottle", amount = 80, price = 8 },
        { name = "soda", amount = 60, price = 10 },
        { name = "coffee", amount = 40, price = 7 },
        { name = "chocolate_bar", amount = 50, price = 14 },
        { name = "sandwich", amount = 30, price = 18 },
        { name = "bread", amount = 40, price = 9 },
    },

    -- Every entry needs an explicit numeric `bucket` (the server check fails
    -- closed without one). Coordinates are the standard 24/7 till positions.
    locations = {
        { name = "24/7", x = 24.50, y = -1346.19, z = 29.50, heading = 266.78, bucket = 0 }, -- Strawberry
        { name = "24/7", x = 373.18, y = 326.51, z = 103.57, heading = 255.77, bucket = 0 }, -- Clinton Ave
        { name = "24/7", x = 2557.46, y = 381.38, z = 108.62, heading = 0.0, bucket = 0 }, -- Palomino Fwy
        { name = "24/7", x = 1163.37, y = -323.80, z = 69.21, heading = 100.0, bucket = 0 }, -- Mirror Park
        { name = "24/7", x = -3039.12, y = 584.38, z = 7.91, heading = 15.0, bucket = 0 }, -- Ineseno Rd, Chumash
        { name = "24/7", x = -3242.16, y = 1000.54, z = 12.83, heading = 355.0, bucket = 0 }, -- Barbareno Rd
        { name = "24/7", x = 547.43, y = 2671.71, z = 42.16, heading = 95.0, bucket = 0 }, -- Harmony
        { name = "24/7", x = 1961.14, y = 3740.69, z = 32.34, heading = 300.0, bucket = 0 }, -- Sandy Shores
        { name = "24/7", x = 2678.07, y = 3279.35, z = 55.24, heading = 330.0, bucket = 0 }, -- Senora Fwy
        { name = "24/7", x = 1729.21, y = 6414.13, z = 35.04, heading = 245.0, bucket = 0 }, -- Paleto Bay
        { name = "24/7", x = 1698.39, y = 4924.40, z = 42.06, heading = 325.0, bucket = 0 }, -- Grapeseed
    },
}
