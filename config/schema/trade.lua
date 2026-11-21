-- /config editor schema for the two-sided player trade window.
if not (Kora and Kora.config and Kora.config.adopt) then return end
local cfg = Config.kora_inventory
local trade = cfg.trade
-- An older config.lua without the block: the code falls back to its defaults.
if type(trade) ~= 'table' then return end

trade.enabled = Kora.config.boolean(trade.enabled, {
    label = 'Enable player trading',
    description = 'Lets two nearby players open a trade window to swap items and cash after both confirm. Turning it off hides the Trade button, refuses new requests and ends any trade that is open. Applies immediately.',
    live = true,
})
trade.slots = Kora.config.integer(trade.slots, {
    label = 'Trade offer slots per player',
    description = 'How many different item stacks each player can put in a trade. The window shows the new number the next time a player opens their inventory; the server applies it to the next offer.',
    min = 1,
    max = 32,
    step = 1,
    live = true,
})
trade.allowCash = Kora.config.boolean(trade.allowCash, {
    label = 'Allow cash in trades',
    description = 'Lets each player add cash to their side of a trade (the cash account, or the cash item when cash is carried as an item). The cash field appears or disappears the next time a player opens their inventory; the server applies it to the next action.',
    live = true,
})
trade.distance = Kora.config.number(trade.distance, {
    label = 'Trade distance (metres)',
    description = 'How close the two players must stand to request, keep open and complete a trade. A trade ends when they move further apart. Applies immediately.',
    min = 0.5,
    max = 50.0,
    step = 0.5,
    scope = 'server',
    live = true,
})
trade.requestTimeout = Kora.config.integer(trade.requestTimeout, {
    label = 'Trade request answer time (seconds)',
    description = 'How long the asked player has to accept or decline a trade request before it expires. Applies to the next request.',
    min = 5,
    max = 120,
    step = 1,
    scope = 'server',
    live = true,
})
trade.confirmDelay = Kora.config.integer(trade.confirmDelay, {
    label = 'Trade confirm countdown (seconds)',
    description = 'After both players press Ready the offers freeze for this long before Confirm can be pressed, so neither side can swap an item at the last second. Applies to the next time both players are ready.',
    min = 0,
    max = 30,
    step = 1,
    scope = 'server',
    live = true,
    advanced = true,
})
trade.maxDuration = Kora.config.integer(trade.maxDuration, {
    label = 'Maximum trade length (seconds)',
    description = 'A trade window still open after this long is cancelled with no changes. Applies immediately, including to open trades.',
    min = 30,
    max = 3600,
    step = 10,
    scope = 'server',
    live = true,
    advanced = true,
})
trade.requestCooldown = Kora.config.integer(trade.requestCooldown, {
    label = 'Trade request cooldown (seconds)',
    description = 'How long a player must wait after sending a trade request before sending another, to stop request spam. Applies to the next request.',
    min = 0,
    max = 600,
    step = 1,
    scope = 'server',
    live = true,
    advanced = true,
})
trade.command = Kora.config.string(trade.command, {
    label = 'Trade chat command',
    description = 'Chat command (without the slash) that asks the nearest player to trade. Leave empty for no command. Changes apply after kora_inventory restarts.',
    maxLength = 32,
    pattern = '^[%w_%-]*$',
    advanced = true,
})
