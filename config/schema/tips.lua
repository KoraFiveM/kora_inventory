-- /config editor schema for the first-time tip card (Config.kora_inventory.ui.tips).
if not (Kora and Kora.config and Kora.config.adopt) then return end
local ui = Config.kora_inventory.ui
local tips = ui.tips or {}
ui.tips = tips

tips.enabled = Kora.config.boolean(tips.enabled, {
    label = 'First-time tips',
    description = 'Shows a small dismissible tip card at the bottom of the inventory for players who are new to it. Only tips for features that are switched on are shown. Applies the next time the inventory opens.',
})
tips.maxShows = Kora.config.integer(tips.maxShows, {
    label = 'Tip card openings',
    description = 'The tip card appears on at most this many openings of the inventory per player (kept on their own machine). Players can also press Got it to hide it for good. Applies the next time the inventory opens.',
    min = 1,
    max = 50,
    step = 1,
})
