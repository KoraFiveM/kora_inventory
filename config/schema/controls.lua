-- /config editor schema for the native controls overlay (Config.kora_inventory.ui.controls).
if not (Kora and Kora.config and Kora.config.adopt) then return end
local ui = Config.kora_inventory.ui
local controls = ui.controls or {}
ui.controls = controls

controls.button = Kora.config.boolean(controls.button, {
    label = 'Controls button',
    description = 'Shows a keyboard button in the top bar of the inventory. Pressing it lists the controls (Esc, Enter, mouse, Shift, Ctrl and Alt) using the game\'s own on-screen button prompts, only for the features that are switched on. Turn it off to remove the button and never show the prompts. Applies the next time the inventory opens.',
    live = true,
})
controls.defaultVisible = Kora.config.boolean(controls.defaultVisible, {
    label = 'Show controls by default',
    description = 'When on, the controls prompts appear the first time a player opens the inventory, until they press the keyboard button to hide them. Once a player has used the button, their own choice is remembered on their machine instead. Has no effect when the controls button is off. Applies the next time the inventory opens.',
    live = true,
})
