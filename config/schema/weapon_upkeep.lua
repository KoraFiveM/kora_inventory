-- /config editor schema for weapon jams, repair kits, cleaning and repair counters.
if not (Kora and Kora.config and Kora.config.adopt) then return end
local weapons = Config.kora_inventory.weapons
local jams, repair = weapons.jams, weapons.repair
local counters = repair.counters

jams.enabled = Kora.config.boolean(jams.enabled, {
    label = 'Enable weapon jams',
    description = 'When on, every shot the server accepts has a small chance to jam the weapon (higher as its durability falls). A jammed weapon cannot fire until the player holds the clear-jam key. Melee, throwables and weapons that take no ammunition never jam. Applies from the next shot.',
    scope = 'server',
    live = true,
})
jams.baseChance = Kora.config.number(jams.baseChance, {
    label = 'Jam chance per shot at full durability',
    description = 'Chance (0 to 1, so 0.002 is 0.2%) that one accepted shot jams a weapon at 100% durability. The chance rises towards the low-durability value as the weapon wears. Applies from the next shot.',
    min = 0, max = 1, step = 0.001,
    scope = 'server', live = true,
})
jams.lowDurabilityChance = Kora.config.number(jams.lowDurabilityChance, {
    label = 'Jam chance per shot at low durability',
    description = 'Chance (0 to 1, so 0.03 is 3%) that one accepted shot jams a weapon at or below the low-durability threshold. Applies from the next shot.',
    min = 0, max = 1, step = 0.001,
    scope = 'server', live = true,
})
jams.lowDurabilityBelow = Kora.config.number(jams.lowDurabilityBelow, {
    label = 'Low durability threshold (percent)',
    description = 'At or below this durability a weapon uses the full low-durability jam chance; between this and 100% the chance is blended. Applies from the next shot.',
    min = 0, max = 100, step = 1,
    scope = 'server', live = true,
})
jams.clearTime = Kora.config.integer(jams.clearTime, {
    label = 'Jam clearing time (milliseconds)',
    description = 'How long the progress bar runs when a player clears a jam. 0 clears it instantly. The server runs and times the bar. Applies the next time a jam is cleared.',
    min = 0, max = 30000, step = 100,
    scope = 'server', live = true,
})

repair.enabled = Kora.config.boolean(repair.enabled, {
    label = 'Enable repair kits and weapon cleaning',
    description = 'When on, the listed repair kit items and the cleaning item repair or clean the weapon the player is holding. Turn it off to leave those items to other resources. Changes apply after kora_inventory restarts, because the use handlers are registered when item definitions load.',
    scope = 'server',
})
repair.maxDurability = Kora.config.number(repair.maxDurability, {
    label = 'Maximum repairable durability (percent)',
    description = 'Kits, cleaning and repair counters never raise a weapon above this durability (100 is the hard ceiling). Applies the next time a weapon is repaired.',
    min = 1, max = 100, step = 1,
    scope = 'server', live = true,
})
repair.kits = Kora.config.map(repair.kits, Kora.config.object({
    restore = Kora.config.number(25, {
        label = 'Durability restored', min = 0, max = 100, step = 1,
    }),
    time = Kora.config.integer(4000, {
        label = 'Repair time (milliseconds)', min = 0, max = 60000, step = 100,
    }),
}), {
    label = 'Repair kit items',
    description = 'Maps each repair kit item name to how many durability points one kit restores and how long the progress bar takes. Only items listed here get a built-in use handler, so other resources keep theirs. The restore amount and time apply the next time a kit is used; adding or removing an item applies after kora_inventory restarts.',
    scope = 'server',
    advanced = true,
})
repair.cleaning.item = Kora.config.string(repair.cleaning.item, {
    label = 'Cleaning kit item',
    description = 'Item name that cleans the weapon the player is holding. Applies after kora_inventory restarts.',
    minLength = 1,
    scope = 'server',
    advanced = true,
})
repair.cleaning.clearsJam = Kora.config.boolean(repair.cleaning.clearsJam, {
    label = 'Cleaning clears jams',
    description = 'When on, using the cleaning item on a jammed weapon clears the jam. Applies the next time the item is used.',
    scope = 'server',
    live = true,
})
repair.cleaning.restore = Kora.config.number(repair.cleaning.restore, {
    label = 'Durability restored by cleaning',
    description = 'Durability points a cleaning restores. Applies the next time the item is used.',
    min = 0, max = 100, step = 1,
    scope = 'server', live = true,
})
repair.cleaning.time = Kora.config.integer(repair.cleaning.time, {
    label = 'Cleaning time (milliseconds)',
    description = 'Length of the cleaning progress bar. Applies the next time the item is used.',
    min = 0, max = 60000, step = 100,
    scope = 'server', live = true,
})

counters.enabled = Kora.config.boolean(counters.enabled, {
    label = 'Enable weapon repair counters',
    description = 'When on, players can pay at the configured counters to repair the weapon they are holding. The counter points are listed in config.lua (weapons.repair.counters.locations); with none listed nothing appears. The server checks distance and charges the price. Changes apply after kora_inventory restarts, because the interaction zones are registered at start.',
})
counters.pricePerPoint = Kora.config.number(counters.pricePerPoint, {
    label = 'Repair price per durability point',
    description = 'Money charged for each missing durability point (rounded up to whole money) when a weapon is repaired at a counter. Applies from the next repair quote.',
    min = 0, max = 100000, step = 1,
    scope = 'server', live = true,
})
counters.account = Kora.config.enum(counters.account, {
    label = 'Repair counter payment account',
    description = 'Which account counter repairs are charged to. Applies from the next repair.',
    options = {
        { value = 'cash', label = 'Cash' },
        { value = 'bank', label = 'Bank' },
    },
    scope = 'server', live = true,
})
