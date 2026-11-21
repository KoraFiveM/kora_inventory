-- /config editor schema for layouts, quick slots, ammo info, QoL and trunk cargo.
if not (Kora and Kora.config and Kora.config.adopt) then return end

local cfg = Config.kora_inventory
local K = Kora.config
local APPLY_OPEN = ' Applies the next time a player opens their inventory.'

local function ensure(parent, key)
    if type(parent[key]) ~= 'table' then parent[key] = {} end
    return parent[key]
end

local ui = ensure(cfg, 'ui')
local weapons = ensure(cfg, 'weapons')
local quickSlots = ensure(cfg, 'quickSlots')
local vehicles = ensure(cfg, 'vehicles')
local ammoInfo = ensure(weapons, 'ammoInfo')
local trunkCargo = ensure(vehicles, 'trunkCargo')
local layouts = ensure(ui, 'layouts')
local weightWarnings = ensure(ui, 'weightWarnings')

-- Inventory layouts ---------------------------------------------------------

ui.layout = K.enum(ui.layout, {
    label = 'Default inventory layout',
    description = 'The inventory window layout every player gets by default: Classic is the original two-panel window, Loadout adds an equipment-focused side panel, Compact is a smaller single-column window, and Dock pins the inventory to the screen edge. Players can override it when players may choose their layout is on.' .. APPLY_OPEN,
    options = {
        { value = 'classic', label = 'Classic (original window)' },
        { value = 'loadout', label = 'Loadout' },
        { value = 'compact', label = 'Compact' },
        { value = 'dock', label = 'Dock' },
    },
    live = true,
})

local layoutLabels = {
    classic = 'Classic',
    loadout = 'Loadout',
    compact = 'Compact',
    dock = 'Dock',
}
for _, id in ipairs({ 'classic', 'loadout', 'compact', 'dock' }) do
    layouts[id] = K.boolean(layouts[id], {
        label = ('Allow the %s layout'):format(layoutLabels[id]),
        description = ('When off, the %s layout is hidden from the layout picker and cannot be used, even as the server default. If every layout is switched off, Classic stays available.'):format(layoutLabels[id]) .. APPLY_OPEN,
        live = true,
    })
end

ui.playerLayoutChoice = K.boolean(ui.playerLayoutChoice, {
    label = 'Players may choose their layout',
    description = 'When on, players pick their own inventory layout in the kora_hud /ui editor (Inventory layout). When off, everyone gets the default layout. Needs kora_hud and the personal inventory placement setting. Read when the /ui editor opens.',
    live = true,
})

-- Quick slots ---------------------------------------------------------------

quickSlots.enabled = K.boolean(quickSlots.enabled, {
    label = 'Quick slots',
    description = 'Shows quick slots (shortcuts to a weapon, ammo, phone or radio you carry) beside the inventory and registers their hotkeys. Turning this off removes the rail and the keybinds. The list of slots itself (slots) is not editable here; change it in config.lua. Needs a resource restart: keybinds are registered once at start.',
})

quickSlots.hideWhenMissing = K.boolean(quickSlots.hideWhenMissing, {
    label = 'Hide empty quick slots',
    description = 'When on, a quick slot with no matching item is hidden. When off, it shows as a greyed placeholder.' .. APPLY_OPEN,
    live = true,
})

quickSlots.showKeyHints = K.boolean(quickSlots.showKeyHints, {
    label = 'Show quick slot key hints',
    description = 'Shows the bound key on each quick slot in the inventory.' .. APPLY_OPEN,
    live = true,
})

if type(quickSlots.drawer) == 'table' then
    quickSlots.drawer.startCollapsed = K.boolean(quickSlots.drawer.startCollapsed, {
        label = 'Quick slot drawer starts collapsed',
        description = 'When on, the quick slot drawer on the side of the inventory starts folded into a thin handle until the player opens it. After a player opens or closes it once, their own choice is remembered.' .. APPLY_OPEN,
        live = true,
    })
end

quickSlots.inHotbarHud = K.boolean(quickSlots.inHotbarHud, {
    label = 'Quick slots in the hotbar display',
    description = 'Includes filled quick slots in the on-screen hotbar shown when a player presses the show-hotbar key. Applies the next time the hotbar is shown.',
    live = true,
})

-- Ammo info -----------------------------------------------------------------

ammoInfo.enabled = K.boolean(ammoInfo.enabled, {
    label = 'Ammo info',
    description = 'Shows which ammunition a weapon takes and which weapons an ammo item fits. Turning it off removes this information from weapon and ammo views. Applies the next time a player opens or refreshes their inventory.',
    live = true,
})

ammoInfo.where = K.enum(ammoInfo.where, {
    label = 'Where ammo info appears',
    description = 'Choose whether ammo information is shown in the item inspector, in the right-click menu, or both. Applies the next time a player opens their inventory.',
    options = {
        { value = 'inspector', label = 'Item inspector only' },
        { value = 'menu', label = 'Right-click menu only' },
        { value = 'both', label = 'Inspector and right-click menu' },
    },
    live = true,
})

ammoInfo.showLoaded = K.boolean(ammoInfo.showLoaded, {
    label = 'Show rounds loaded in the weapon',
    description = 'Includes how many rounds are currently loaded in the weapon. Applies the next time a player opens or refreshes their inventory.',
    live = true,
})

ammoInfo.showCompatible = K.boolean(ammoInfo.showCompatible, {
    label = 'Show compatible weapons on ammo',
    description = 'Ammo items list the weapons they fit. Applies the next time a player opens or refreshes their inventory.',
    live = true,
})

-- Inventory quality of life -------------------------------------------------

ui.rightClick = K.enum(ui.rightClick, {
    label = 'Right-click action',
    description = 'What right-clicking an item does: Split opens the split-stack dialog, Menu opens a small context menu (Use, Split, Drop, Give, Ammo info, Copy) showing only what applies, None does nothing. This replaces the older right-click splits stacks switch.' .. APPLY_OPEN,
    options = {
        { value = 'split', label = 'Split stack dialog' },
        { value = 'menu', label = 'Context menu' },
        { value = 'none', label = 'Nothing' },
    },
    live = true,
})

ui.quickTransfer = K.boolean(ui.quickTransfer, {
    label = 'Shift-click quick transfer',
    description = 'Shift+click moves a whole stack to the other open inventory. The server still checks every move.' .. APPLY_OPEN,
    live = true,
})

ui.modifierDrag = K.boolean(ui.modifierDrag, {
    label = 'Ctrl and Alt drag amounts',
    description = 'Ctrl+drag moves half a stack and Alt+drag moves a single item. The server still checks every move.' .. APPLY_OPEN,
    live = true,
})

ui.quickAmounts = K.boolean(ui.quickAmounts, {
    label = 'Quick amount buttons',
    description = 'Shows 1, 5, 10, half and All buttons beside the amount slider.' .. APPLY_OPEN,
    live = true,
})

ui.filters = K.boolean(ui.filters, {
    label = 'Category filter chips',
    description = 'Shows category chips (All, Weapons, Ammo, Consumables, Other) that dim non-matching slots.' .. APPLY_OPEN,
    live = true,
})

ui.tooltips = K.boolean(ui.tooltips, {
    label = 'Item tooltips',
    description = 'Shows a tooltip when hovering a filled slot.' .. APPLY_OPEN,
    live = true,
})

weightWarnings.enabled = K.boolean(weightWarnings.enabled, {
    label = 'Weight warnings',
    description = 'Colours the weight bar amber when a player is getting heavy and red when almost full.' .. APPLY_OPEN,
    live = true,
})

weightWarnings.warnAt = K.number(weightWarnings.warnAt, {
    label = 'Weight warning level',
    description = 'Fraction of the maximum weight at which the weight bar turns amber (0.75 = 75 percent).' .. APPLY_OPEN,
    min = 0.01,
    max = 1,
    step = 0.01,
    live = true,
})

weightWarnings.dangerAt = K.number(weightWarnings.dangerAt, {
    label = 'Weight danger level',
    description = 'Fraction of the maximum weight at which the weight bar turns red (0.95 = 95 percent). Never lower than the warning level.' .. APPLY_OPEN,
    min = 0.01,
    max = 1,
    step = 0.01,
    live = true,
})

-- Trunk cargo ---------------------------------------------------------------

trunkCargo.enabled = K.boolean(trunkCargo.enabled, {
    label = 'Visible trunk cargo',
    description = 'Draws props for the items stored in a vehicle trunk, visible through the open boot. Cosmetic only: the server still owns the trunk contents. Applies within a second or two.',
    live = true,
})

trunkCargo.drawDistance = K.number(trunkCargo.drawDistance, {
    label = 'Trunk cargo draw distance (metres)',
    description = 'How close a player must be to a vehicle for its cargo props to be created on their screen. Lower values save performance. Applies within a second or two.',
    min = 5,
    max = 100,
    step = 1,
    live = true,
})

trunkCargo.maxProps = K.integer(trunkCargo.maxProps, {
    label = 'Maximum cargo props per trunk',
    description = 'The most item props drawn in one trunk. Lower values save performance. Applies within a second or two.',
    min = 1,
    max = 24,
    step = 1,
    live = true,
})

trunkCargo.fallbackModel = K.string(trunkCargo.fallbackModel, {
    label = 'Fallback cargo prop model',
    description = 'Prop model used for items that have no model of their own. It must be a valid non-vehicle, non-ped model. Restart the resource after changing it.',
    minLength = 1,
    advanced = true,
})

trunkCargo.models = K.map(trunkCargo.models, K.string('', { minLength = 1 }), {
    label = 'Cargo prop models by item',
    description = 'Maps an item name to the prop model drawn for it in the trunk. Restart the resource after changing it.',
    advanced = true,
})

trunkCargo.bounds = K.map(trunkCargo.bounds, K.object({
    min = K.vector3({ x = -1.0, y = -1.0, z = 0.0 }, { label = 'Box minimum corner' }),
    max = K.vector3({ x = 1.0, y = 1.0, z = 1.0 }, { label = 'Box maximum corner' }),
}), {
    label = 'Cargo box by vehicle model',
    description = 'Maps a vehicle spawn name to the box (in the vehicle model space) where cargo is placed, to calibrate custom vehicles. Restart the resource after changing it.',
    advanced = true,
})
