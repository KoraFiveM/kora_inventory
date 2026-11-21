-- /config editor schema for what a searcher sees and may open in another
-- player's inventory (Config.kora_inventory.search).
if not (Kora and Kora.config and Kora.config.adopt) then return end
local cfg = Config.kora_inventory.search

cfg.hideContainerContents = Kora.config.boolean(cfg.hideContainerContents, {
    label = 'Hide bag contents when searching a player',
    description = 'When on, bags and backpacks in a searched player’s inventory are shown as closed: nothing about what is inside them is sent to the searcher. Turn it off to show them like any other item. Applies from the next inventory view.',
    scope = 'server',
    live = true,
})
cfg.openContainers = Kora.config.boolean(cfg.openContainers, {
    label = 'Searchers may open a player’s bag',
    description = 'When on, someone who is allowed to search another player can also open that player’s bag or backpack to look inside it, as long as they stay in range. Turn it off so bags can never be opened this way. Applies on the next open request.',
    live = true,
})
cfg.openTime = Kora.config.integer(cfg.openTime, {
    label = 'Time to open a searched bag (milliseconds)',
    description = 'How long the searcher’s progress bar runs before the bag opens. 0 opens it instantly. The server runs the bar on the searcher’s screen and refuses an answer that comes back too early, then checks everything again before opening. Applies on the next open request.',
    min = 0,
    max = 20000,
    step = 100,
    live = true,
})
