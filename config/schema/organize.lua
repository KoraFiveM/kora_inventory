-- /config editor schema for the Sort / Stack-all buttons (Config.kora_inventory.organize).
if not (Kora and Kora.config and Kora.config.adopt) then return end
local cfg = Config.kora_inventory
local organize = cfg.organize or {}
cfg.organize = organize

organize.enabled = Kora.config.boolean(organize.enabled, {
    label = 'Sort and Stack all buttons',
    description = 'Master switch for the Sort and Stack all buttons on every inventory panel (player, stash, trunk, glovebox, container and ground drop; never shops). When off the server refuses the request and the buttons disappear the next time a player opens the inventory.',
    live = true,
})
organize.stack = Kora.config.boolean(organize.stack, {
    label = 'Allow Stack all',
    description = 'Lets players merge partial stacks of the same item with identical metadata into one stack in the lowest slot. Unique items such as weapons with serials are never merged. The server applies a change at once; the button shows or hides the next time the inventory opens.',
    live = true,
})
organize.sort = Kora.config.boolean(organize.sort, {
    label = 'Allow Sort',
    description = 'Lets players stack and then reorder a panel by category, name and original slot. The server applies a change at once; the button shows or hides the next time the inventory opens.',
    live = true,
})
organize.keepHotbar = Kora.config.boolean(organize.keepHotbar, {
    label = 'Keep the hotbar slots in place',
    description = 'When on, sorting a player inventory never moves or empties the first hotbar slots, so number-key bindings and visible weapon carry stay as they were. Matching stacks may still be added to a hotbar stack. Applies on the next Sort or Stack all.',
    live = true,
})
organize.cooldownMs = Kora.config.integer(organize.cooldownMs, {
    label = 'Organize cooldown (milliseconds)',
    description = 'Minimum time between two Sort or Stack all requests from the same player. Applies on the next request.',
    min = 0,
    max = 60000,
    step = 100,
    scope = 'server',
    live = true,
    advanced = true,
})
organize.sortOrder = Kora.config.list(organize.sortOrder,
    Kora.config.enum('other', { options = { 'weapon', 'ammo', 'useable', 'other' } }), {
        label = 'Sort category order',
        description = 'Order in which Sort groups items: weapon, ammo, useable (items with a use action) and other. A category left out of the list sorts last. Applies on the next Sort.',
        scope = 'server',
        live = true,
    })
organize.panelSearch = Kora.config.boolean(organize.panelSearch, {
    label = 'Search box on every panel',
    description = 'Shows a small search box in each panel header that dims the slots that do not match in that panel only. Applies the next time the inventory opens.',
})
