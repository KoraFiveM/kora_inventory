-- Controls overlay: GTA's native instructional buttons (through kora_lib's
-- Kora.instructional) listing what the mouse and keyboard do in the inventory
-- window. Pure presentation. It is client-local, nothing here reaches the
-- server, and it never reads or changes inventory state. The browser asks for
-- it with the `kora_inventory:controls` NUI callback (client/ui.lua).
KoraInventory = KoraInventory or {}

-- GTA control ids. The glyph kora_lib draws for each comes from
-- GetControlInstructionalButton, so these are chosen for the key they show:
--   200 INPUT_FRONTEND_PAUSE_ALTERNATE -> Esc (199 is the P pause key; 322 is
--       the cutscene-skip control, which also reads Esc but names an unrelated
--       action, so 200, the pause menu's own Esc binding, is the one used)
--   201 INPUT_FRONTEND_ACCEPT          -> Enter
--   24  INPUT_ATTACK                   -> left mouse
--   25  INPUT_AIM                      -> right mouse
--   21  INPUT_SPRINT                   -> Shift
--   36  INPUT_DUCK                     -> Ctrl
--   19  INPUT_CHARACTER_WHEEL          -> Alt
local CONTROL = {
    close = 200, use = 201, mouseLeft = 24, mouseRight = 25,
    shift = 21, ctrl = 36, alt = 19,
}

local function defaultText(_, fallback)
    return fallback
end

---Reads `ui.controls` with its defaults: the toggle button is on, the overlay
---starts hidden. Read at call time so a live /config edit applies on the next
---open.
---@param ui table|nil Config.kora_inventory.ui
---@return { button: boolean, defaultVisible: boolean }
local function settings(ui)
    local controls = type(ui) == 'table' and type(ui.controls) == 'table' and ui.controls or {}
    return {
        button = controls.button ~= false,
        defaultVisible = controls.defaultVisible == true,
    }
end

-- 'split' | 'menu' | 'none'; same rule as client/ui.lua's rightClickMode (the
-- legacy boolean is only read when `rightClick` is absent or invalid).
local function rightClick(ui)
    local mode = ui.rightClick
    if mode == 'split' or mode == 'menu' or mode == 'none' then
        return mode
    end
    return ui.rightClickSplit == false and 'none' or 'split'
end

---The instructional buttons for the features enabled in `ui`. Listed in the
---order they are drawn: the essentials first, then the optional modifiers.
---@param ui table|nil Config.kora_inventory.ui (read by the caller at call time)
---@param text fun(key: string, fallback: string): string|nil locale lookup
---@return { label: string, control: integer }[]
local function buttons(ui, text)
    ui = type(ui) == 'table' and ui or {}
    text = text or defaultText
    local function label(key, fallback)
        return text('inventory.controls_' .. key, fallback)
    end

    local list = {
        { label = label('close', 'Close inventory'), control = CONTROL.close },
        { label = label('use', 'Use selected item'), control = CONTROL.use },
        { label = label('drag', 'Drag: move / stack'), control = CONTROL.mouseLeft },
        { label = label('drag_out', 'Drag outside: drop'), control = CONTROL.mouseLeft },
        { label = label('double_click', 'Double-click: use'), control = CONTROL.mouseLeft },
    }

    local mode = rightClick(ui)
    if mode == 'split' then
        list[#list + 1] = { label = label('split', 'Split stack'), control = CONTROL.mouseRight }
    elseif mode == 'menu' then
        list[#list + 1] = { label = label('item_menu', 'Item menu'), control = CONTROL.mouseRight }
    end

    if ui.quickTransfer ~= false then
        list[#list + 1] = { label = label('quick_transfer', '+ click: quick transfer'), control = CONTROL.shift }
    end
    if ui.modifierDrag ~= false then
        list[#list + 1] = { label = label('move_half', '+ drag: move half'), control = CONTROL.ctrl }
        list[#list + 1] = { label = label('move_one', '+ drag: move one'), control = CONTROL.alt }
    end
    return list
end

local handle

local function visible()
    return handle ~= nil and handle.isVisible() == true
end

---Hides the overlay. Safe to call at any time (no overlay, kora_lib missing).
local function hide()
    local current = handle
    handle = nil
    if current and current.isVisible() then
        current.hide()
    end
end

---Shows (or refreshes) the overlay from the current config.
---@param ui table|nil Config.kora_inventory.ui
---@return boolean shown
local function show(ui)
    if not (Kora and Kora.instructional and Kora.instructional.show) then
        return false
    end
    local list = buttons(ui, KoraInventory.text)
    local ok, result = pcall(function()
        if visible() then
            handle.setButtons(list)
            return handle
        end
        return Kora.instructional.show(list)
    end)
    if not ok then
        handle = nil
        if Kora.logging and Kora.logging.warn then
            Kora.logging.warn('controls.show_failed', 'Controls overlay could not be shown', { error = tostring(result) })
        end
        return false
    end
    handle = result
    return true
end

KoraInventory.controls = {
    settings = settings,
    buttons = buttons,
    show = show,
    hide = hide,
    isVisible = visible,
}
