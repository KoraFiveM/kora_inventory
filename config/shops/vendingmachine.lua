-- Vending machines are the one shop type with no curated location list --
-- unlike Ammu-Nation (config/shops/ammunation.lua), a vending machine can be
-- any `models` prop a mapper drops anywhere on the map, so there is no fixed
-- coordinate set to check the source against. Real qb-inventory (github.com/
-- qbcore-fivem/qb-inventory, config/config.lua + server/main.lua) accepts
-- exactly this trade-off: it trusts the client-reported prop coordinates and
-- only bounds-checks the player's live server position against them. This
-- shop matches that same trust boundary (see server/shops/vendingmachine.lua)
-- rather than inventing a stronger guarantee FXServer has no way to provide --
-- these props are static map geometry, never networked entities the server
-- can independently query.

Config = Config or {}
Config.qbinventory = Config.qbinventory or {}
Config.qbinventory.shops = Config.qbinventory.shops or {}

Config.qbinventory.shops.vendingmachine = {
    id = 'vendingmachine',
    label = 'Vending Machine',
    slots = 2,
    maxWeight = 40000,
    currency = 'cash',
    interactionDistance = 2.5,

    -- Every default GTA V vending machine prop. `client/shops/vendingmachine.lua`
    -- targets these by model everywhere they're streamed in, not a fixed list.
    models = {
        'prop_vend_soda_01',
        'prop_vend_soda_02',
        'prop_vend_water_01',
        'prop_vend_coffe_01',
    },

    -- Reuses this project's own item catalogue (qbcore/shared/items.lua)
    -- rather than porting upstream's `kurkakola` name verbatim -- this
    -- registry already departs from upstream naming elsewhere (e.g.
    -- `water_bottle` is labelled "Water", not "Bottle of Water").
    inventory = {
        { name = 'water_bottle', amount = 50, price = 4 },
        { name = 'soda', amount = 50, price = 5 },
    },
}
