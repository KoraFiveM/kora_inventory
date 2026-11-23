-- Kora drinks loaded by kora_core at boot.
local function item(name, label, weight, image, shouldClose, description, options)
    return {
        name = name,
        label = label,
        weight = weight,
        type = 'item',
        image = image,
        useable = true,
        shouldClose = shouldClose,
        description = description,
        dropProp = options and options.dropProp,
    }
end

return {
    item('water_bottle',   'Water',                   500,  'water_bottle.webp',    true,  'Refreshing.', { dropProp = 'prop_ld_flow_bottle' }),
    item('beer',           'Beer',                    350,  'beer.webp',            true,  'An alcoholic drink.', { dropProp = 'prop_cs_beer_bot_01' }),
    item('whiskey',        'Whiskey',                 400,  'whiskey.webp',         true,  'Strong stuff.', { dropProp = 'prop_cs_whiskey_bottle' }),
    item('soda',           'Soda',                    350,  'ecola.webp',           true,  'Sweet and fizzy.', { dropProp = 'prop_ecola_can' }),
    item('coffee',         'Coffee',                  200,  'coffee.webp',          true,  'Pump 4 Caffeine', { dropProp = 'p_amb_coffeecup_01' }),
    item('grapejuice',     'Grape Juice',             200,  'grape_juice.webp',     false, 'Grape juice is said to be healthy'),
    item('kurkakola',      'Cola',                    500,  'ecola.webp',           true,  'For all the thirsty out there', { dropProp = 'prop_ecola_can' }),
    item('vodka',          'Vodka',                   500,  'vodka_bottle.webp',    true,  'For all the thirsty out there'),
    item('wine',           'Wine',                    300,  'wine.webp',            false, 'Some good wine to drink on a fine evening', { dropProp = 'prop_wine_bot_01' }),
}
