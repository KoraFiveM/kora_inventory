-- /config editor schema for item decay / expiry (Config.kora_inventory.decay).
if not (Kora and Kora.config and Kora.config.adopt) then return end
local cfg = Config.kora_inventory.decay

cfg.enabled = Kora.config.boolean(cfg.enabled, {
    label = 'Enable item decay',
    description = 'When on, items with a decay rule spoil in real time and are converted into another item (for example sandwich to garbage) or removed once fully decayed. Items already in inventories start their clock the first time the server sees them, so nothing spoils retroactively. Turn it off to freeze every clock and stop spoiling. Applies on the next inventory view, use or move.',
    live = true,
})
cfg.defaultAction = Kora.config.enum(cfg.defaultAction, {
    label = 'What happens to spoiled items',
    description = 'Convert: a spoiled item becomes the item named in its rule (same slot and amount), or is removed when its rule names none. Remove: every spoiled item is simply removed. Applies the next time an item spoils.',
    options = {
        { value = 'convert', label = 'Convert into another item when the rule names one' },
        { value = 'remove', label = 'Always remove' },
    },
    scope = 'server',
    live = true,
})
cfg.showInInspector = Kora.config.boolean(cfg.showInInspector, {
    label = 'Show "Expires in" in the item inspector',
    description = 'Adds an "Expires in 1h 20m" row to the item details for items that decay. Applies the next time an inventory is viewed.',
    live = true,
})
cfg.showOnSlot = Kora.config.boolean(cfg.showOnSlot, {
    label = 'Show a freshness bar on slots',
    description = 'Draws a thin bar on the slot of every decaying item. It turns amber when the item is close to spoiling and red when it is almost gone. Applies the next time a player opens their inventory.',
    live = true,
})
cfg.warnBelow = Kora.config.number(cfg.warnBelow, {
    label = 'Warn when this much life is left',
    description = 'Fraction of an item\'s life left (0.25 = 25%) below which its freshness bar turns amber. Below 10% it is always red. Applies the next time a player opens their inventory.',
    min = 0.0,
    max = 1.0,
    step = 0.05,
    live = true,
})
cfg.sweepSeconds = Kora.config.integer(cfg.sweepSeconds, {
    label = 'Spoil check interval (seconds)',
    description = 'How often the server checks the inventories of players who are online, so food spoils even if they never open their inventory. 0 turns the check off: items then only spoil when an inventory is viewed or an item is used or moved. Values between 1 and 29 are treated as 30. Applies within a few seconds.',
    min = 0,
    max = 86400,
    step = 30,
    advanced = true,
    scope = 'server',
    live = true,
})
cfg.mergePolicy = Kora.config.enum(cfg.mergePolicy, {
    label = 'Stacking items of different ages',
    description = 'Oldest: stacks of the same item merge and the whole stack spoils with its oldest member (the safe choice). Separate: items only stack when they were created at the same time, so differently aged items keep their own stacks. Applies the next time items are stacked.',
    options = {
        { value = 'oldest', label = 'Merge, spoiling with the oldest' },
        { value = 'separate', label = 'Keep differently aged items apart' },
    },
    live = true,
})

local pause = cfg.pauseIn
for _, entry in ipairs({
    { 'stash', 'Stashes', 'stashes' },
    { 'trunk', 'Vehicle trunks', 'vehicle trunks' },
    { 'glovebox', 'Gloveboxes', 'vehicle gloveboxes' },
    { 'container', 'Portable containers', 'portable containers (backpacks, cases)' },
    { 'drop', 'Ground drops', 'items dropped on the ground' },
}) do
    pause[entry[1]] = Kora.config.boolean(pause[entry[1]], {
        label = 'Pause decay in: ' .. entry[2],
        description = ('When on, time does not count while an item sits in %s (like a fridge), and the time spent there is not counted when it comes out. Player inventories always count. Applies the next time the inventory is viewed.'):format(entry[3]),
        scope = 'server',
        live = true,
        advanced = true,
    })
end

cfg.items = Kora.config.map(cfg.items, Kora.config.object({
    lifetime = Kora.config.integer(172800, {
        label = 'Lifetime (seconds)',
        description = 'Real-time seconds until a new item of this kind is fully decayed (86400 = one day).',
        min = 60,
        max = 31536000,
        step = 60,
    }),
    into = Kora.config.optional(nil, Kora.config.string('', { minLength = 1 }), {
        label = 'Becomes item',
        description = 'Item name the spoiled item turns into, keeping its amount (for example garbage). Leave unset to remove it.',
    }),
}), {
    label = 'Decaying items',
    description = 'Which items spoil, by exact item name: the lifetime in seconds and the item they turn into. An entry here wins over a decay field on the kora_core item definition. Applies to items created from now on; items already stamped keep the lifetime they were created with.',
    scope = 'server',
    live = true,
    advanced = true,
})
