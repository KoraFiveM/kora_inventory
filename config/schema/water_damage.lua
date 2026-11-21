-- /config editor schema for water damage to electronics (Config.kora_inventory.waterDamage).
if not (Kora and Kora.config and Kora.config.adopt) then return end
local cfg = Config.kora_inventory.waterDamage

cfg.enabled = Kora.config.boolean(cfg.enabled, {
    label = 'Water damage',
    description = 'When on, a player who has been swimming may damage the electronics listed below that they carry in their pockets. Items stored inside a bag are never damaged. Applies on the next swim report.',
    live = true,
})
cfg.swimSeconds = Kora.config.integer(cfg.swimSeconds, {
    label = 'Seconds swimming before damage (seconds)',
    description = 'How long a player must keep swimming or be underwater before their game reports it. The server also accepts at most one report every ten seconds. Applies from the next time a player enters the water.',
    min = 1,
    max = 120,
    step = 1,
    live = true,
})
cfg.items = Kora.config.map(cfg.items,
    Kora.config.object({
        chance = Kora.config.number(1.0, { min = 0, max = 1, step = 0.05, label = 'Chance per report' }),
    }), {
        scope = 'server',
        live = true,
        label = 'Items damaged by water',
        description = 'Maps an item name to the chance (0 to 1) that one carried stack of it is damaged each time the player reports swimming. Applies on the next swim report.',
    })
cfg.mode = Kora.config.enum(cfg.mode, {
    options = {
        { value = 'flag', label = 'Mark as water damaged (cannot be used until repaired)' },
        { value = 'convert', label = 'Turn into another item' },
        { value = 'remove', label = 'Destroy the item' },
    },
    label = 'What water damage does',
    description = 'Flag keeps the item but blocks using it until it is repaired. Convert replaces it with the item chosen below. Remove deletes it. Applies on the next swim report.',
    scope = 'server',
    live = true,
})
cfg.into = Kora.config.optional(cfg.into, Kora.config.string('', { minLength = 1 }), {
    label = 'Item a damaged item turns into',
    description = 'Only used when water damage turns items into another item, for example garbage. If it is not set or the item does not exist, damaged items are marked instead of converted. Applies on the next swim report.',
    scope = 'server',
    live = true,
})
cfg.repairItem = Kora.config.string(cfg.repairItem, {
    label = 'Repair item',
    description = 'Using one of this item repairs the first water damaged item in the player’s pockets and consumes the repair item. Applies on the next use.',
    minLength = 1,
    scope = 'server',
    live = true,
})
cfg.protectedBy = Kora.config.list(cfg.protectedBy, Kora.config.string('', { minLength = 1 }), {
    label = 'Waterproof item names',
    description = 'Reserved for waterproof carriers. Items inside any portable bag are already never damaged; only pockets are checked. Changing this has no effect yet.',
    scope = 'server',
    advanced = true,
})
