-- Kora food loaded by kora_core at boot.
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
    item('sandwich',       'Sandwich',                220,  'sandwich.webp',        true,  'Filling.', { dropProp = 'prop_sandwich_01' }),
    item('bread',          'Bread',                   120,  'bread.webp',           true,  'Filling.'),
    item('chocolate_bar',  'Chocolate Bar',           80,   'chocolate_bar.webp',   true,  'A quick snack.', { dropProp = 'prop_choc_ego' }),
    item('grape',          'Grape',                   100,  'grape.webp',           false, 'Mmmmh yummie, grapes'),
    item('tosti',          'Grilled Cheese Sandwich', 200,  'tosti.webp',           true,  'Nice to eat', { dropProp = 'prop_sandwich_01' }),
    item('burger',         'Burger',                  220,  'burger.webp',          true,  'A burger.', { dropProp = 'prop_cs_burger_01' }),
    item('mustard',        'Mustard',                 500,  'mustard.webp',         true,  'A bottle of mustard.', { dropProp = 'v_ret_247_mustard' }),
}
