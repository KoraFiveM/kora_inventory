-- /config editor schema for drag-to-combine (Config.kora_inventory.combine).
if not (Kora and Kora.config and Kora.config.adopt) then return end

local combine = Config.kora_inventory.combine

combine.enabled = Kora.config.boolean(combine.enabled, {
    label = 'Drag items together to combine them',
    description = 'When on, dropping one item onto a different item in your own inventory asks "Combine / Cancel" if a recipe pairs them (for example rolling paper and weed make a joint). When off, dropping swaps or stacks the two items as usual and the server refuses combine requests. The server reads this on every attempt, so a change applies at once; players see the popover change the next time they open their inventory.',
    live = true,
})

combine.progress = Kora.config.boolean(combine.progress, {
    label = 'Show a progress bar while combining',
    description = 'When on, a recipe with a time above 0 shows the progress bar and the two items stay locked until it finishes or is cancelled. When off, every combine completes immediately. Applies on the next combine.',
    scope = 'server',
    live = true,
})

combine.recipes = Kora.config.list(combine.recipes, Kora.config.object({
    a = Kora.config.string('', {
        label = 'First item',
        description = 'Item name of one ingredient (for example rolling_paper). Recipes work in either drag order.',
        minLength = 1,
        maxLength = 64,
    }),
    b = Kora.config.string('', {
        label = 'Second item',
        description = 'Item name of the other ingredient (for example weed).',
        minLength = 1,
        maxLength = 64,
    }),
    result = Kora.config.string('', {
        label = 'Result item',
        description = 'Item name given when the recipe completes (for example joint). It must exist in kora_core shared items.',
        minLength = 1,
        maxLength = 64,
    }),
    amount = Kora.config.integer(1, {
        label = 'Result amount',
        description = 'How many of the result item are given.',
        min = 1,
        max = 10000,
        step = 1,
    }),
    consumeA = Kora.config.integer(1, {
        label = 'First item used up',
        description = 'How many of the first item are consumed. 0 keeps it, for example for a tool.',
        min = 0,
        max = 10000,
        step = 1,
    }),
    consumeB = Kora.config.integer(1, {
        label = 'Second item used up',
        description = 'How many of the second item are consumed. 0 keeps it.',
        min = 0,
        max = 10000,
        step = 1,
    }),
    time = Kora.config.integer(0, {
        label = 'Progress bar time (milliseconds)',
        description = 'How long the progress bar runs. 0 combines instantly. Ignored while the progress bar option above is off.',
        min = 0,
        max = 20000,
        step = 100,
    }),
    label = Kora.config.string('Combine', {
        label = 'Question and bar text',
        description = 'Shown as the question on the confirm popover ("Roll a joint?") and as the progress bar text.',
        minLength = 1,
        maxLength = 80,
    }),
}), {
    label = 'Combine recipes',
    description = 'The item pairs players can drag together. The server holds the only copy of the amounts and results; players only see each pair and its label. Resources can add more recipes with the registerCombination export; a pair listed here cannot be registered again. Applies on the next combine, and players see new pairs the next time they open their inventory.',
    live = true,
    advanced = false,
})
