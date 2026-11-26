-- Controls overlay (client/controls.lua): the button list is a pure function of
-- the ui config, and show/hide drive Kora.instructional handles. No FXServer.
local H = dofile('test/harness.lua')

-- Defaults ship in config.lua and the /config schema registers both keys live.
Config = nil
dofile('config.lua')
local controlsConfig = Config.kora_inventory.ui.controls
H.equal(controlsConfig.button, true, 'the controls button defaults on')
H.equal(controlsConfig.defaultVisible, false, 'the overlay defaults to hidden')

local recorded = {}
local function builder(kind)
    return function(default, options)
        recorded[#recorded + 1] = { kind = kind, default = default, options = options }
        return default
    end
end
Kora = { config = setmetatable({ adopt = function(value) return value end }, { __index = function(_, kind) return builder(kind) end }) }
dofile('config/schema/controls.lua')
H.equal(#recorded, 2, 'the schema registers both controls keys')
for _, entry in ipairs(recorded) do
    H.equal(entry.kind, 'boolean', 'controls keys are booleans')
    H.equal(entry.options.live, true, 'controls keys are read at call time, so they are live')
    H.ok(entry.options.label and entry.options.description, 'controls keys are labelled and described')
end

Kora = nil
KoraInventory = nil
dofile('client/controls.lua')
local controls = KoraInventory.controls

local function byLabel(list)
    local out = {}
    for _, button in ipairs(list) do out[button.label] = button.control end
    return out
end
local function has(list, label) return byLabel(list)[label] ~= nil end

-- settings(): tolerant of missing or malformed config.
H.equal(controls.settings(nil).button, true, 'no config: the button is on')
H.equal(controls.settings({}).defaultVisible, false, 'no controls table: hidden by default')
H.equal(controls.settings({ controls = { button = false } }).button, false, 'button = false is honoured')
H.equal(controls.settings({ controls = { defaultVisible = true } }).defaultVisible, true, 'defaultVisible = true is honoured')
H.equal(controls.settings({ controls = 'bad' }).button, true, 'a malformed controls value falls back to the defaults')

-- Full list with everything on. Modifier actions are two entries each so the
-- overlay can merge them into Shift+LMB / Ctrl+LMB / Alt+LMB.
local all = controls.buttons(Config.kora_inventory.ui)
local map = byLabel(all)
H.equal(#all, 12, 'every feature on lists twelve buttons (three modifier chords)')
H.equal(map['Close inventory'], 200, 'Esc closes (INPUT_FRONTEND_PAUSE_ALTERNATE)')
H.equal(map['Use selected item'], 201, 'Enter uses the selection (INPUT_FRONTEND_ACCEPT)')
H.equal(map['Drag: move / stack'], 24, 'left mouse drags')
H.equal(map['Drag outside: drop'], 24, 'left mouse drops outside the window')
H.equal(map['Double-click: use'], 24, 'double-click uses')
H.equal(map['Split stack'], 25, 'right mouse splits with the default rightClick mode')
local function controlsOf(list, label)
    local out = {}
    for _, button in ipairs(list) do if button.label == label then out[#out + 1] = button.control end end
    return out
end
H.equal(controlsOf(all, 'Quick transfer')[1], 21, 'Shift is the first half of quick transfer')
H.equal(controlsOf(all, 'Quick transfer')[2], 24, 'LMB is the click half of quick transfer')
H.equal(controlsOf(all, 'Move half')[1], 36, 'Ctrl is the first half of move half')
H.equal(controlsOf(all, 'Move half')[2], 24, 'LMB is the drag half of move half')
H.equal(controlsOf(all, 'Move one')[1], 19, 'Alt is the first half of move one')
H.equal(controlsOf(all, 'Move one')[2], 24, 'LMB is the drag half of move one')
H.equal(all[1].control, 21, 'the list starts with the dual-keycap modifier chords')
H.equal(all[#all].control, 201, 'Use selected closes the list')
-- Keyboard controls carry a name for kora_lib to show when GTA has no glyph;
-- mouse buttons do not need one.
local function fallbackOf(list, label, control)
    for _, button in ipairs(list) do
        if button.label == label and (control == nil or button.control == control) then
            return button.keyFallback
        end
    end
end
H.equal(fallbackOf(all, 'Close inventory'), 'Esc', 'Esc is named for the close key')
H.equal(fallbackOf(all, 'Quick transfer', 21), 'Shift', 'Shift is named')
H.equal(fallbackOf(all, 'Move half', 36), 'Ctrl', 'Ctrl is named')
H.equal(fallbackOf(all, 'Move one', 19), 'Alt', 'Alt is named')
H.equal(fallbackOf(all, 'Drag: move / stack'), nil, 'mouse buttons have no fallback')
H.equal(fallbackOf(all, 'Quick transfer', 24), nil, 'the click half of a chord has no fallback')
for _, button in ipairs(all) do
    H.equal(type(button.label), 'string', 'every button has a label')
    H.ok(button.label ~= '', 'every label is non-empty')
    H.equal(type(button.control), 'number', 'every button uses exactly one input source, a control id')
    H.equal(button.command, nil, 'no command source')
    H.equal(button.keybind, nil, 'no keybind source')
end

-- Feature toggles.
local noQuick = controls.buttons({ quickTransfer = false })
H.ok(not has(noQuick, 'Quick transfer'), 'quickTransfer = false drops the Shift chord')
H.ok(has(noQuick, 'Move half'), 'modifier drag stays listed')
local noMod = controls.buttons({ modifierDrag = false })
H.ok(not has(noMod, 'Move half') and not has(noMod, 'Move one'), 'modifierDrag = false drops Ctrl and Alt chords')
H.ok(has(noMod, 'Quick transfer'), 'quick transfer stays listed')
local bare = controls.buttons({ quickTransfer = false, modifierDrag = false, rightClick = 'none' })
H.equal(#bare, 5, 'with every optional feature off only the basics remain')

-- Right-click modes, including the legacy boolean.
H.ok(has(controls.buttons({ rightClick = 'split' }), 'Split stack'), 'split mode lists Split stack')
local menu = controls.buttons({ rightClick = 'menu' })
H.equal(byLabel(menu)['Item menu'], 25, 'menu mode lists Item menu on the right mouse')
H.ok(not has(menu, 'Split stack'), 'menu mode has no Split stack')
local none = controls.buttons({ rightClick = 'none' })
H.ok(not has(none, 'Split stack') and not has(none, 'Item menu'), 'none omits the right mouse button')
H.ok(not has(controls.buttons({ rightClickSplit = false }), 'Split stack'), 'legacy rightClickSplit = false omits it when rightClick is absent')
H.ok(has(controls.buttons({ rightClick = 'bogus', rightClickSplit = true }), 'Split stack'), 'an invalid mode falls back to the legacy flag')

-- Labels come from the locale function, with the English text as the fallback.
local keys = {}
controls.buttons({}, function(key, fallback) keys[#keys + 1] = key; return 'x:' .. fallback end)
H.ok(#keys >= 9, 'every label goes through the locale lookup')
for _, key in ipairs(keys) do H.ok(key:find('^inventory%.controls_'), 'locale keys live under inventory.controls_*: ' .. key) end
H.ok(has(controls.buttons({}, function(_, fallback) return 'x:' .. fallback end), 'x:Close inventory'), 'translated text is used')

-- The English locale carries every key the builder asks for.
local en = dofile('locales/en.lua')
for _, key in ipairs(keys) do
    H.ok(en.inventory[key:gsub('^inventory%.', '')], 'locales/en.lua has ' .. key)
end

-- show / hide against a recording kora_lib.
local shown, hidden, handleSeq, updated = {}, 0, 0, 0
local function newHandle(list)
    handleSeq = handleSeq + 1
    local alive = true
    shown[#shown + 1] = list
    return {
        setButtons = function(buttons) updated = updated + 1; shown[#shown + 1] = buttons; return alive end,
        hide = function() hidden = hidden + 1; alive = false; return true end,
        isVisible = function() return alive end,
    }
end
Kora = { instructional = { show = newHandle } }
KoraInventory.text = nil

H.equal(controls.isVisible(), false, 'hidden to begin with')
controls.hide()
H.equal(hidden, 0, 'hiding when nothing is shown is a no-op')
H.equal(controls.show({ quickTransfer = false }), true, 'show succeeds')
H.equal(controls.isVisible(), true, 'visible after show')
H.equal(#shown[1], 10, 'the list is built from the config passed at call time (modifier chords are two entries)')
H.equal(controls.show({ quickTransfer = false, modifierDrag = false }), true, 'showing again refreshes instead of stacking a second display')
H.equal(handleSeq, 1, 'only one display is created')
H.equal(updated, 1, 'the existing display is updated')
H.equal(#shown[#shown], 6, 'the refreshed list reflects the new config')
controls.hide()
H.equal(hidden, 1, 'hide closes the display')
H.equal(controls.isVisible(), false, 'not visible after hide')
controls.hide()
H.equal(hidden, 1, 'a second hide does nothing')

-- A kora_lib failure never raises, and a missing kora_lib simply shows nothing.
Kora = { instructional = { show = function() error('boom') end }, logging = { warn = function() end } }
H.equal(controls.show({}), false, 'a failing kora_lib reports false instead of raising')
H.equal(controls.isVisible(), false, 'and nothing is left visible')
Kora = {}
H.equal(controls.show({}), false, 'without Kora.instructional nothing is shown')

H.finish()
