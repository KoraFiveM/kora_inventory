-- Ammu-Nation is configured as one shared, finite-stock shop. The location
-- list is duplicated deliberately: client/shops/ammunation.lua uses it only
-- to present local interaction zones, while server/shops/ammunation.lua
-- independently verifies the source's live server position and bucket.
--
-- Keep stock rows declarative. server.lua turns each row into the canonical
-- registry-backed item record (label, image, weight, unique and metadata) at
-- registration time; never copy those presentation/authority fields here.

Config = Config or {}
Config.qbinventory = Config.qbinventory or {}
Config.qbinventory.shops = Config.qbinventory.shops or {}

Config.qbinventory.shops.ammunation = {
    id = 'ammunation',
    label = 'Ammu-Nation',
    slots = 32,
    maxWeight = 40000,
    currency = 'cash',
    interactionDistance = 2.25,
    blip = {
        enabled = true,
        sprite = 110,
        color = 1,
        scale = 0.72,
        shortRange = true,
        -- Must be a Kora.blips category; an unknown value logs a warning and
        -- the blip is created without a category.
        category = 'Weapons',
        name = 'Ammu-Nation',
    },

    -- Each row is a real kora_core shared weapon or ammo item. Keep native
    -- AMMO_* values out of shop stock: players buy the registered inventory
    -- packs (for example `pistol_ammo`), never synthetic ammo identifiers.
    inventory = {
        -- Melee and handguns
        { name = 'weapon_knife', amount = 40, price = 250 },
        { name = 'weapon_bat', amount = 25, price = 500 },
        { name = 'weapon_pistol', amount = 20, price = 7500 },
        { name = 'weapon_combatpistol', amount = 16, price = 9500 },
        { name = 'weapon_appistol', amount = 12, price = 18000 },
        { name = 'weapon_pistol50', amount = 10, price = 20000 },
        { name = 'weapon_snspistol', amount = 20, price = 5500 },
        { name = 'weapon_heavypistol', amount = 12, price = 16000 },
        { name = 'weapon_vintagepistol', amount = 10, price = 11000 },
        { name = 'weapon_revolver', amount = 8, price = 24000 },

        -- Long guns
        { name = 'weapon_microsmg', amount = 10, price = 28000 },
        { name = 'weapon_smg', amount = 8, price = 35000 },
        { name = 'weapon_pumpshotgun', amount = 10, price = 30000 },
        { name = 'weapon_sawnoffshotgun', amount = 10, price = 22000 },
        { name = 'weapon_assaultrifle', amount = 6, price = 55000 },
        { name = 'weapon_carbinerifle', amount = 8, price = 50000 },
        { name = 'weapon_advancedrifle', amount = 6, price = 65000 },
        { name = 'weapon_specialcarbine', amount = 6, price = 60000 },
        { name = 'weapon_bullpuprifle', amount = 6, price = 58000 },
        { name = 'weapon_sniperrifle', amount = 4, price = 90000 },
        { name = 'weapon_marksmanrifle', amount = 4, price = 75000 },

        -- Standard kora_core ammunition packs
        { name = 'pistol_ammo', amount = 160, price = 450 },
        { name = 'smg_ammo', amount = 120, price = 700 },
        { name = 'shotgun_ammo', amount = 120, price = 650 },
        { name = 'rifle_ammo', amount = 120, price = 900 },
        { name = 'mg_ammo', amount = 40, price = 1800 },
        { name = 'snp_ammo', amount = 40, price = 2200 },
    },

    -- A shop opening is valid only when the server observes the source in one
    -- of these exact locations and in the listed routing bucket. Do not make
    -- an unrestricted location entry: a client can request the shop ID from
    -- anywhere, but cannot satisfy the server's access callback from there.
    locations = {
        { x = 809.49, y = -2157.27, z = 29.62, heading = 330.0, bucket = 0 },
        { x = 1693.41, y = 3760.16, z = 34.71, heading = 225.0, bucket = 0 },
        { x = -330.68, y = 6083.45, z = 31.45, heading = 45.0, bucket = 0 },
        { x = 252.63, y = -50.00, z = 69.94, heading = 72.0, bucket = 0 },
        { x = 22.09, y = -1107.28, z = 29.80, heading = 160.0, bucket = 0 },
        { x = 2567.48, y = 294.30, z = 108.73, heading = 270.0, bucket = 0 },
        { x = -1117.59, y = 2698.60, z = 18.55, heading = 130.0, bucket = 0 },
        { x = 842.44, y = -1033.42, z = 28.19, heading = 0.0, bucket = 0 },
        { x = -3172.50, y = 1085.13, z = 20.84, heading = 245.0, bucket = 0 },
        { x = -1304.00, y = -394.90, z = 36.70, heading = 345.0, bucket = 0 },
        { x = -662.10, y = -935.30, z = 21.83, heading = 90.0, bucket = 0 },
    },
}
