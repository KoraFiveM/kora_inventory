local logSpy = dofile('test/logging_spy.lua')
local H = dofile('test/harness.lua')
local file = assert(io.open('client/ui.lua', 'r'))
local source = file:read('*a')
file:close()

H.ok(source:find("type%(payload%.patch%) == 'table'"),
    'unwraps the client transport { token, patch } envelope')
H.ok(source:find('token, patch = payload.token, payload.patch', 1, true),
    'keeps the session token paired with the inner authoritative patch')
H.ok(source:find("send('kora_inventory:nui:sessionPatched', wire)", 1, true),
    'forwards the normalised authoritative patch to the browser')
H.ok(source:find("'kora_inventory:client:itemBox'", 1, true),
    'relays inventory-owned item receipt payloads to the bundled UI')
H.ok(source:find("send('kora_inventory:nui:itemBox', payload)", 1, true),
    'item receipts can render without an inventory session')
H.ok(source:find('Wait(2000)', 1, true),
    'client locale push waits two seconds for React to load')
H.ok(source:find("send('kora_inventory:nui:locales', locales)", 1, true),
    'resolved client locales are sent to the React UI')
local localeManifest = assert(io.open('fxmanifest.lua', 'r')):read('*a')
H.ok(localeManifest:find("'locales/*.lua'", 1, true),
    'the English Lua locale is included in the resource files')
H.ok(source:find("Kora.notify.send({", 1, true),
    'rejected inventory actions are presented as notifications')

Config = {}
dofile('config.lua')
local images = Config.kora_inventory.ui.images
H.equal(images.localPath, 'nui://kora_inventory/images', 'artwork uses kora_inventory NUI paths')
H.equal(images.extensions[1], 'webp', 'local WebP artwork is tried first')
H.equal(images.allowRemote, nil, 'inventory artwork does not use remote URL fallbacks')

H.equal(Config.kora_inventory.ui.scale, 1.0, 'UI scale defaults to 1.0 so the layout is unchanged')
H.ok(source:find('scale = Kora.util.clamp(tonumber(ui.scale) or 1.0, 0.5, 2.0)', 1, true),
    'the scale is read live and clamped on every config push')

H.equal(Config.kora_inventory.ui.rightClickSplit, true, 'right-click split defaults on')
H.ok(source:find('rightClickSplit = ui.rightClickSplit ~= false', 1, true), 'rightClickSplit is pushed to the NUI on every config push')
H.equal(Config.kora_inventory.ui.rightClick, 'split', 'right-click defaults to the split dialog')
H.ok(source:find('rightClick = rightClickMode(ui),', 1, true), 'rightClick is pushed to the NUI on every config push')

for _, key in ipairs({ 'quickTransfer', 'modifierDrag', 'quickAmounts', 'filters', 'tooltips' }) do
    H.equal(Config.kora_inventory.ui[key], true, key .. ' defaults on')
    H.ok(source:find(key .. ' = ui.' .. key .. ' ~= false', 1, true), key .. ' is pushed to the NUI on every config push')
end
H.equal(Config.kora_inventory.ui.weightWarnings.warnAt, 0.75, 'weight warning threshold defaults to 0.75')
H.equal(Config.kora_inventory.ui.weightWarnings.dangerAt, 0.95, 'weight danger threshold defaults to 0.95')
H.ok(source:find('weightWarnings = weightWarnings()', 1, true), 'weightWarnings is pushed to the NUI')

H.equal(Config.kora_inventory.ui.optimisticMoves, true, 'optimistic moves default on')
H.ok(source:find('optimisticMoves = ui.optimisticMoves ~= false', 1, true), 'optimisticMoves is pushed to the NUI on every config push')

H.equal(Config.kora_inventory.ui.queueMoves, true, 'drags queue behind a pending move by default instead of being refused')
H.ok(source:find('queueMoves = ui.queueMoves ~= false', 1, true), 'queueMoves is pushed to the NUI on every config push')
H.equal(Config.kora_inventory.ui.moveTimeoutMs, 6000, 'move timeout defaults to 6000 ms: nothing blocks while the direct transport waits')
H.equal(Config.kora_inventory.ui.directTransport, true, 'the direct transport defaults on')
H.ok(source:find('directTransport = directTransport(),', 1, true), 'directTransport is pushed to the NUI on every config push')
H.equal(Config.kora_inventory.ui.moveTimeout, nil, 'the legacy seconds option is not set by default')
H.ok(source:find('moveTimeoutMs = moveTimeoutMs(),', 1, true),
    'the move timeout is read live and pushed in milliseconds')

H.equal(images.cdn, nil, 'inventory artwork does not use a CDN fallback')

-- Exercise the actual bridge; host presentation calls only record messages.
local handlers, messages = {}, {}
AddEventHandler = function(name, callback) handlers[name] = callback end
RegisterNetEvent = AddEventHandler
local nui = {}
RegisterNUICallback = function(name, fn) nui[name] = fn end
SetNuiFocus, TriggerEvent = function() end, function() end
GetGameTimer = function() return 0 end
local timers = {}
SetTimeout = function(ms, fn) timers[#timers + 1] = { ms = ms, fn = fn } end
SendNUIMessage = function(message) messages[#messages + 1] = message end
GetCurrentResourceName = function() return 'kora_inventory' end
KoraTheme = { refresh = function() end }
local inVehicle, cacheHandlers = false, {}
Kora = {
    notify = { send = function() end },
    cache = { vehicle = function() return inVehicle and 1 or nil end, onChange = function(key, fn) cacheHandlers[key] = fn end },
    util = { clamp = function(value, min, max)
        if value < min then return min end
        if value > max then return max end
        return value
    end },
}
-- The controls overlay module loads before the bridge (see fxmanifest.lua).
local overlay = { shown = 0, hidden = 0, lastButtons = nil, alive = false }
Kora.instructional = { show = function(buttons)
    overlay.shown, overlay.lastButtons, overlay.alive = overlay.shown + 1, buttons, true
    return {
        setButtons = function(list) overlay.lastButtons = list; return true end,
        hide = function() overlay.hidden, overlay.alive = overlay.hidden + 1, false; return true end,
        isVisible = function() return overlay.alive end,
    }
end }
dofile('client/controls.lua')
dofile(arg[1] or 'client/ui.lua')
-- client/admin_ui.lua later registers its own onResourceStop in this stub.
local uiResourceStop = handlers['onResourceStop']

-- Hotbar overlay position: Config.Hotbar offsets, switched by vehicle state.
H.equal(Config.Hotbar.bottomOffset, 90, 'hotbar on-foot offset defaults to 90px')
H.equal(Config.Hotbar.vehicleBottomOffset, 130, 'hotbar vehicle offset defaults to 130px')
handlers['kora_inventory:ui:hotbarShow']({ slots = {}, seconds = 5 })
H.equal(messages[#messages].data.bottom, 90, 'the hotbar is shown at the on-foot offset')
inVehicle = true
handlers['kora_inventory:ui:hotbarShow']({ slots = {}, seconds = 5 })
H.equal(messages[#messages].data.bottom, 130, 'the hotbar is shown at the vehicle offset when seated')
inVehicle = false
cacheHandlers.vehicle()
H.equal(messages[#messages].action, 'kora_inventory:nui:hotbarPosition', 'leaving a vehicle repositions the visible hotbar')
H.equal(messages[#messages].data.bottom, 90, 'and uses the on-foot offset again')
local function view(id, revision)
    return { key = id, revision = revision, items = {}, slots = 4 }
end
local function compact(id, revision)
    return { key = id, revision = revision, inventory = view(id, revision) }
end
handlers['kora_inventory:ui:sessionOpened']({ token = 'A', primary = view('player:1', 3), secondary = view('player:2', 5) })
H.equal(messages[#messages].data.player.id, 'player:1', 'primary server key becomes the player view id')
H.equal(messages[#messages].data.secondary.id, 'player:2', 'inspected player keeps a separate view id')
H.equal(messages[#messages].data.revision, 3, 'open keeps primary revision')
H.equal(messages[#messages].data.secondaryRevision, 5, 'open keeps secondary revision')

handlers['kora_inventory:ui:sessionPatched']({ token = 'A', patch = compact('player:1', 4) })
local patch = messages[#messages].data
H.equal(patch.player.id, 'player:1', 'primary compact update reaches player panel')
H.equal(patch.secondary, nil, 'primary update leaves secondary untouched')
H.equal(patch.revision, 4, 'primary counter stays in primary revision')

for _, form in ipairs({ 'wrapped', 'legacy', 'direct' }) do
    local changed = compact('player:2', 6)
    if form == 'wrapped' then
        handlers['kora_inventory:ui:sessionPatched']({ token = 'A', patch = changed })
    elseif form == 'legacy' then
        handlers['kora_inventory:ui:sessionPatched']('A', changed)
    else
        changed.token = 'A'
        handlers['kora_inventory:ui:sessionPatched'](changed)
    end
    patch = messages[#messages].data
    H.equal(patch.sessionId, 'A', form .. ' compact update keeps session id')
    H.equal(patch.player, nil, form .. ' inspected update leaves player panel untouched')
    H.equal(patch.secondary.id, 'player:2', form .. ' inspected update reaches secondary panel')
    H.equal(patch.revision, nil, form .. ' inspected counter cannot replace primary revision')
    H.equal(patch.secondaryRevision, 6, form .. ' inspected counter reaches secondary revision')
end

local snapshot = { sessionId = 'A', player = { id = 'player:1' }, secondary = { id = 'player:2' } }
handlers['kora_inventory:ui:sessionPatched']({ token = 'A', patch = {
    player = { id = 'player:1', items = {} }, secondary = { id = 'player:2', items = {} },
    revision = 8, secondaryRevision = 9, snapshot = snapshot,
} })
patch = messages[#messages].data
H.equal(patch.player.id, 'player:1', 'normalized primary form is retained')
H.equal(patch.secondary.id, 'player:2', 'normalized secondary form is retained')
H.equal(patch.revision, 8, 'normalized primary counter is retained')
H.equal(patch.secondaryRevision, 9, 'normalized secondary counter is retained')
H.equal(patch.snapshot, snapshot, 'snapshot form passes through unchanged')
local count = #messages
handlers['kora_inventory:ui:sessionPatched']({ token = 'stale', patch = compact('player:1', 10) })
handlers['kora_inventory:ui:sessionPatched']({ token = 'A', patch = compact('player:3', 10) })
handlers['kora_inventory:ui:sessionPatched']({ token = 'A', patch = compact('stash:other', 10) })
H.equal(#messages, count, 'stale tokens and inventories outside the session are ignored')
handlers['kora_inventory:ui:sessionClosed']({ token = 'A' })
count = #messages
handlers['kora_inventory:ui:sessionPatched']({ token = 'A', patch = compact('player:2', 10) })
H.equal(#messages, count, 'closed session ignores delayed compact updates')

handlers['kora_inventory:ui:sessionOpened']({ token = 'B', player = { id = 'player:3', revision = 1 } })
count = #messages
handlers['kora_inventory:ui:sessionPatched']({ token = 'B', patch = compact('player:2', 10) })
H.equal(#messages, count, 'solo reopen cannot reuse the old secondary identity')
handlers['kora_inventory:ui:sessionPatched']({ token = 'B', patch = compact('player:3', 2) })
H.equal(messages[#messages].data.player.id, 'player:3', 'reopen replaces primary identity')

handlers['kora_inventory:ui:sessionOpened']({ token = 'C', primary = view('player:1', 10), secondary = view('stash:locker', 20) })
handlers['kora_inventory:ui:sessionPatched']({ token = 'C', patch = compact('stash:locker', 21) })
patch = messages[#messages].data
H.equal(patch.secondary.id, 'stash:locker', 'storage compact update still reaches secondary panel')
H.equal(patch.player, nil, 'storage update leaves player untouched')
H.equal(patch.revision, nil, 'storage counter leaves primary revision untouched')
H.equal(patch.secondaryRevision, 21, 'storage counter reaches secondary revision')

-- Every NUI callback must answer on every path. A callback that never calls cb
-- leaves the browser's fetch pending: the move then sits locked until the UI's
-- own timeout fires, which is exactly the "busy cursor, cannot drag" report.
local function answers(name, data, label)
    local calls = {}
    nui[name](data, function(result) calls[#calls + 1] = result end)
    H.equal(#calls, 1, name .. ' answers exactly once: ' .. label)
    return calls[1]
end
handlers['kora_inventory:ui:sessionOpened']({ token = 'D', primary = view('player:1', 1) })
local envelope = function(intent, payload)
    return { sessionId = 'D', token = 'D', intent = intent, payload = payload }
end
local submit
KoraInventory = { controls = KoraInventory.controls, clientApi = { submitIntent = function(...) return submit(...) end } }
submit = function() return true end
H.equal(answers('kora_inventory:nui:intent', envelope('move', {}), 'accepted').ok, true, 'an accepted intent reports ok')
submit = function() return false, 'over weight' end
H.equal(answers('kora_inventory:nui:intent', envelope('move', {}), 'rejected').error, 'over weight', 'a rejection carries the reason')
submit = function() error('transport exploded') end
local failed = answers('kora_inventory:nui:intent', envelope('move', {}), 'transport raises')
H.equal(failed.ok, false, 'an error inside the transport still answers the browser')
submit = function() return true end
for label, data in pairs({
    ['nil data'] = false, ['empty table'] = {}, ['stale session'] = { sessionId = 'old', token = 'D', intent = 'move', payload = {} },
    ['bad token'] = { sessionId = 'D', token = 1, intent = 'move', payload = {} },
    ['unknown intent'] = envelope('teleport', {}), ['bad payload'] = envelope('move', 'x'),
}) do
    local result = answers('kora_inventory:nui:intent', data or nil, label)
    H.equal(result.ok, false, 'invalid intent is refused: ' .. label)
end
-- A server that never replies: the transport blocks (here: parks the thread) and
-- the deadline answers the browser instead, once, with the late result dropped.
do
    local calls = {}
    timers = {}
    submit = function() return true end
    nui['kora_inventory:nui:intent'](envelope('move', {}), function(result) calls[#calls + 1] = result end)
    H.equal(#calls, 1, 'a prompt reply answers once')
    H.equal(#timers, 1, 'a deadline is armed for a move')
    H.equal(timers[1].ms, 6000, 'the deadline is the configured move timeout')
    timers[1].fn()
    H.equal(#calls, 1, 'the deadline firing after the answer does not answer twice')

    -- Deadline first: the transport never returns before the timer.
    calls, timers = {}, {}
    local routine = coroutine.wrap(function()
        submit = function() coroutine.yield() return true end
        nui['kora_inventory:nui:intent'](envelope('move', {}), function(result) calls[#calls + 1] = result end)
    end)
    routine()
    H.equal(#calls, 0, 'nothing is answered while the server round trip is outstanding')
    timers[1].fn()
    H.equal(#calls, 1, 'the deadline answers the browser')
    H.equal(calls[1].ok, false, 'the deadline answer is a failure')
    H.equal(calls[1].error, 'timeout', 'and says why')
    routine()
    H.equal(#calls, 1, 'the late server result is ignored')

    -- use may wait on a progress bar: no deadline.
    timers = {}
    submit = function() return true end
    nui['kora_inventory:nui:intent'](envelope('use', {}), function() end)
    H.equal(#timers, 0, 'use arms no deadline')
    submit = function() return true end
end
-- Direct transport: a request id gets an immediate acknowledgement (the fetch is
-- never left pending) and the verdict follows as an NUI message, exactly once.
do
    local function request(intent, id) local data = envelope(intent, {}) data.requestId = id return data end
    local function results()
        local out = {}
        for _, message in ipairs(messages) do
            if message.action == 'kora_inventory:nui:intentResult' then out[#out + 1] = message.data end
        end
        return out
    end
    for i = #messages, 1, -1 do messages[i] = nil end
    timers = {}
    submit = function() return true end
    local ack = answers('kora_inventory:nui:intent', request('move', 41), 'direct accepted')
    H.equal(ack.pending, true, 'the fetch is acknowledged as pending')
    H.equal(ack.requestId, 41, 'with the browser request id')
    H.equal(#results(), 1, 'the verdict is delivered as a message')
    H.equal(results()[1].requestId, 41, 'tagged with the request id')
    H.equal(results()[1].ok, true, 'a success')
    timers[1].fn()
    H.equal(#results(), 1, 'the deadline firing after the verdict delivers nothing more')

    for i = #messages, 1, -1 do messages[i] = nil end
    submit = function() return false, 'over weight' end
    answers('kora_inventory:nui:intent', request('move', 42), 'direct rejected')
    H.equal(results()[1].ok, false, 'a refusal is delivered as a failure')
    H.equal(results()[1].error, 'over weight', 'with the reason')

    for i = #messages, 1, -1 do messages[i] = nil end
    submit = function() error('transport exploded') end
    answers('kora_inventory:nui:intent', request('move', 43), 'direct raises')
    H.equal(results()[1].ok, false, 'an error inside the transport is delivered as a failure')

    -- A server that never replies: the fetch is long since answered; the deadline delivers the failure.
    for i = #messages, 1, -1 do messages[i] = nil end
    timers = {}
    local calls = {}
    local routine = coroutine.wrap(function()
        submit = function() coroutine.yield() return true end
        nui['kora_inventory:nui:intent'](request('move', 44), function(result) calls[#calls + 1] = result end)
    end)
    routine()
    H.equal(#calls, 1, 'the browser was acknowledged without waiting for the server')
    H.equal(#results(), 0, 'no verdict while the server is silent')
    timers[1].fn()
    H.equal(results()[1].error, 'timeout', 'the deadline delivers a timeout')
    routine()
    H.equal(#results(), 1, 'a late server result is dropped')

    -- use may wait on a progress bar: no deadline.
    timers = {}
    submit = function() return true end
    answers('kora_inventory:nui:intent', request('use', 45), 'direct use')
    H.equal(#timers, 0, 'use arms no deadline here either')

    -- With the option off the blocking reply is used even when an id is sent.
    Config.kora_inventory.ui.directTransport = false
    for i = #messages, 1, -1 do messages[i] = nil end
    submit = function() return true end
    local blocking = answers('kora_inventory:nui:intent', request('move', 46), 'blocking fallback')
    H.equal(blocking.pending, nil, 'directTransport = false replies with the verdict itself')
    H.equal(#results(), 0, 'and delivers no message')
    Config.kora_inventory.ui.directTransport = true
end
answers('kora_inventory:nui:close', nil, 'nil data')
answers('kora_inventory:nui:close', {}, 'empty table')
answers('kora_inventory:nui:close', { sessionId = 'D', token = 'D' }, 'valid close')

-- /ui editor (kora_hud): the window layout is re-validated and only ours is taken.
handlers['kora_hud:ui:apply']('kora_chat', 'inventory', { x = 0.4 })
H.ok(not messages[#messages] or messages[#messages].action ~= 'kora_inventory:nui:layout', 'another owner\'s apply is ignored')
handlers['kora_hud:ui:apply']('kora_inventory', 'inventory', {
    x = 4, y = -0.25, scale = 3, placed = true, settings = { playerSide = 'right', useForTransfer = 'yes' },
})
local layout = messages[#messages]
H.equal(layout.action, 'kora_inventory:nui:layout', 'the layout reaches the NUI')
H.equal(layout.data.x, 1, 'offset is clamped')
H.equal(layout.data.y, -0.25, 'in range offsets pass')
H.equal(layout.data.scale, 1.25, 'scale is clamped to 75-125%')
H.equal(layout.data.playerSide, 'right', 'the side setting passes')
H.equal(layout.data.useForTransfer, false, 'a non-boolean toggle falls back to the config default')
handlers['kora_hud:ui:apply']('kora_inventory', 'inventory', nil)
H.equal(messages[#messages].data.scale, 1, 'a reset restores the default layout')
H.equal(Config.kora_inventory.ui.playerLayout, true, 'the /ui registration defaults on')
H.equal(Config.kora_inventory.ui.playerLayoutTransfer, false, 'stashes use the default layout by default')

-- Layout registry: server default, allowed set and the player's choice.
H.equal(Config.kora_inventory.ui.layout, 'classic', 'the server layout defaults to classic')
H.equal(Config.kora_inventory.ui.playerLayoutChoice, true, 'players may choose a layout by default')
for _, id in ipairs({ 'classic', 'loadout', 'compact', 'dock' }) do
    H.equal(Config.kora_inventory.ui.layouts[id], true, id .. ' layout is allowed by default')
end
H.ok(source:find('playerLayoutChoice = ui.playerLayoutChoice ~= false', 1, true), 'playerLayoutChoice is pushed to the NUI on every config push')
handlers['kora_inventory:ui:sessionOpened']({ token = 'L', primary = view('player:1', 1) })
local function lastConfig()
    for i = #messages, 1, -1 do
        if messages[i].action == 'kora_inventory:nui:config' then return messages[i].data end
    end
end
local pushed = lastConfig()
H.ok(pushed ~= nil, 'opening a session pushes the config')
H.equal(pushed.layout, 'classic', 'the server layout reaches the NUI')
H.equal(pushed.layouts.dock, true, 'the allowed layouts reach the NUI')
H.equal(pushed.playerLayoutChoice, true, 'the player choice flag reaches the NUI')
local uiCfg = Config.kora_inventory.ui
local savedUi = { layout = uiCfg.layout, layouts = uiCfg.layouts, choice = uiCfg.playerLayoutChoice }
uiCfg.layout, uiCfg.layouts, uiCfg.playerLayoutChoice = 'bogus', { dock = false, compact = 'yes' }, false
handlers['kora_inventory:ui:sessionOpened']({ token = 'L2', primary = view('player:1', 1) })
pushed = lastConfig()
H.equal(pushed.layout, 'classic', 'an unknown layout falls back to classic')
H.equal(pushed.layouts.dock, false, 'a layout set to false is not allowed')
H.equal(pushed.layouts.compact, true, 'only an explicit false disables a layout (booleans only)')
H.equal(pushed.playerLayoutChoice, false, 'playerLayoutChoice = false is pushed')
uiCfg.layouts = { classic = false, loadout = false, compact = false, dock = false }
handlers['kora_inventory:ui:sessionOpened']({ token = 'L3', primary = view('player:1', 1) })
H.equal(lastConfig().layouts.classic, true, 'classic stays allowed when everything is disabled')
uiCfg.layout, uiCfg.layouts, uiCfg.playerLayoutChoice = savedUi.layout, savedUi.layouts, savedUi.choice

-- Right-click mode: valid values pass through, anything else falls back to the legacy boolean.
H.equal(lastConfig().rightClick, 'split', 'the right-click mode reaches the NUI')
local savedClick = { mode = uiCfg.rightClick, split = uiCfg.rightClickSplit }
uiCfg.rightClick = 'menu'
handlers['kora_inventory:ui:sessionOpened']({ token = 'R1', primary = view('player:1', 1) })
H.equal(lastConfig().rightClick, 'menu', 'rightClick = menu is pushed')
uiCfg.rightClick = 'none'
handlers['kora_inventory:ui:sessionOpened']({ token = 'R2', primary = view('player:1', 1) })
H.equal(lastConfig().rightClick, 'none', 'rightClick = none is pushed')
uiCfg.rightClick, uiCfg.rightClickSplit = 'bogus', false
handlers['kora_inventory:ui:sessionOpened']({ token = 'R3', primary = view('player:1', 1) })
H.equal(lastConfig().rightClick, 'none', 'an invalid rightClick falls back to the legacy false = none')
uiCfg.rightClick, uiCfg.rightClickSplit = nil, true
handlers['kora_inventory:ui:sessionOpened']({ token = 'R4', primary = view('player:1', 1) })
H.equal(lastConfig().rightClick, 'split', 'an absent rightClick falls back to the legacy true = split')
uiCfg.rightClick, uiCfg.rightClickSplit = savedClick.mode, savedClick.split

-- The editor registration carries the picker (allowed layouts only).
local savedExports, savedState = exports, GetResourceState
local registeredElement
exports = setmetatable({}, { __index = function() return { registerUiElement = function(_, element) registeredElement = element end } end })
GetResourceState = function() return 'started' end
local function layoutSetting()
    registeredElement = nil
    handlers['kora_hud:ui:ready']()
    for _, setting in ipairs(registeredElement and registeredElement.settings or {}) do
        if setting.key == 'layout' then return setting end
    end
end
local picker = layoutSetting()
H.ok(picker ~= nil, 'the /ui editor offers an inventory layout picker')
H.equal(picker.type, 'select', 'the picker is a select')
H.equal(picker.default, 'classic', 'the picker defaults to the server layout')
H.equal(#picker.options, 4, 'every allowed layout is an option')
H.equal(picker.options[2].label, 'Loadout', 'options carry display labels')
uiCfg.layouts = { classic = true, loadout = false, compact = true, dock = false }
picker = layoutSetting()
H.equal(#picker.options, 2, 'disallowed layouts are not offered')
H.equal(picker.options[2].value, 'compact', 'the remaining options keep their order')
uiCfg.playerLayoutChoice = false
H.equal(layoutSetting(), nil, 'playerLayoutChoice = false hides the picker')
uiCfg.layouts, uiCfg.playerLayoutChoice = savedUi.layouts, savedUi.choice
exports, GetResourceState = savedExports, savedState

handlers['kora_hud:ui:apply']('kora_inventory', 'inventory', { settings = { layout = 'dock' } })
H.equal(messages[#messages].data.layout, 'dock', 'a known layout choice reaches the NUI')
handlers['kora_hud:ui:apply']('kora_inventory', 'inventory', { settings = { layout = '../evil' } })
H.equal(messages[#messages].data.layout, nil, 'an unknown layout choice is dropped')
handlers['kora_hud:ui:apply']('kora_inventory', 'inventory', nil)
H.equal(messages[#messages].data.layout, nil, 'a reset carries no layout choice')

local closeIntents = {}
TriggerEvent = function(name, payload) if name == 'kora_inventory:client:submitIntent' then closeIntents[#closeIntents + 1] = payload end end
handlers['kora_inventory:ui:sessionOpened']({ token = 'E', primary = view('player:1', 1) })
handlers['kora_hud:ui:editing'](true)
H.equal(#closeIntents, 1, 'opening the /ui editor closes an open inventory')
H.equal(closeIntents[1].intent, 'close', 'through the normal close intent')
H.equal(closeIntents[1].token, 'E', 'for the active session')
TriggerEvent = function() end

-- Hooks must not register callbacks or exports when the convar is disabled.
-- The manifest always lists fft_hooks.lua; the file itself is the gate.
local hookExports = {}
exports = function(name, fn) hookExports[name] = fn end
dofile('fft_hooks.lua')
H.equal(nui['fft:result'], nil, 'disabled FFT result callback is absent')
H.equal(nui['fft:observed'], nil, 'disabled FFT observation callback is absent')
H.equal(next(hookExports), nil, 'disabled FFT exports are absent')
GetConvar = function(name, fallback) return name == 'fft_kora_hooks' and 'true' or fallback end
GetResourceState = function() return 'started' end
GetInvokingResource = function() return 'untrusted_resource' end
LocalPlayer = {state={fftSession='active-test'}}
-- Exercise the real self-gating hook file with hooks enabled.
dofile('fft_hooks.lua')
local uiSource = io.open(arg[1] or 'client/ui.lua', 'r'):read('*a')
H.ok(not uiSource:lower():find('fft', 1, true), 'client/ui.lua carries no FFT code')
H.equal(hookExports.fftAction('dragBuy', 'soda', 1), false, 'wrong caller rejected')
GetConvar = function(_, fallback) return fallback end
H.equal(hookExports.fftVersion(), 1, 'FFT protocol version')
answers('fft:result', nil, 'nil FFT reply')
answers('fft:result', {}, 'unmatched FFT reply')
answers('fft:result', {request='old', session='old', token='old', ok=true}, 'stale FFT reply')
answers('fft:observed', nil, 'nil FFT observation')
answers('fft:observed', {action='buy', item='soda'}, 'disabled FFT observation')
-- New NUI entry points must have acknowledgment coverage here.
local scan = io.popen("grep -rl RegisterNUICallback client client.lua server.lua shared.lua fft_hooks.lua 2>/dev/null")
for file in scan:lines() do
    H.ok(file == 'client/ui.lua' or file == 'client/admin_ui.lua' or file == 'fft_hooks.lua', 'unexpected NUI callback owner: ' .. file)
end
scan:close()
-- The read-only /invaudit overlay owns two callbacks of its own.
local auditEvents = {}
local priorNetEvent = RegisterNetEvent
RegisterNetEvent = function(name, handler) auditEvents[name] = handler end
Kora.callback = Kora.callback or {}
local auditAnswers = {}
Kora.callback.trigger = function(name, filter) auditAnswers[#auditAnswers + 1] = { name = name, filter = filter }; return { rows = {}, hasMore = false } end
dofile('client/admin_ui.lua')
RegisterNetEvent = priorNetEvent
local registered = 0
for name in pairs(nui) do
    registered = registered + 1
    H.ok(name == 'kora_inventory:nui:intent' or name == 'kora_inventory:nui:close' or name == 'kora_inventory:pinQuickSlot'
        or name == 'kora_inventory:controls' or name == 'kora_inventory:audit:query' or name == 'kora_inventory:audit:close'
        or name == 'fft:result' or name == 'fft:observed', 'unexpected NUI callback ' .. name)
end
H.equal(registered, 8, 'gameplay, audit overlay and optional development callbacks are covered')

-- Controls overlay callback: client-local presentation, never forwarded.
H.ok(nui['kora_inventory:controls'], 'the controls callback is registered')
local controlsConfigPush
for _, message in ipairs(messages) do
    if message.action == 'kora_inventory:nui:config' then controlsConfigPush = message.data.controls end
end
H.ok(controlsConfigPush == nil or controlsConfigPush.button == true, 'the config push carries the controls settings')
local function controlsCall(data)
    local reply
    nui['kora_inventory:controls'](data, function(result) reply = result end)
    return reply
end
local triggered = {}
TriggerEvent = function(name) triggered[#triggered + 1] = name end
handlers['kora_inventory:ui:sessionClosed']({ token = 'E' })
H.equal(controlsCall({ show = true }).visible, false, 'no overlay without an open session')
H.equal(overlay.shown, 0, 'nothing is shown while no inventory session is open')
handlers['kora_inventory:ui:sessionOpened']({ token = 'C1', primary = view('player:1', 1) })
local pushed
for index = #messages, 1, -1 do
    if messages[index].action == 'kora_inventory:nui:config' then pushed = messages[index].data break end
end
H.equal(pushed.controls.button, true, 'config push: the controls button defaults on')
H.equal(pushed.controls.defaultVisible, false, 'config push: the overlay defaults to hidden')
local shownReply = controlsCall({ show = true })
H.equal(shownReply.ok, true, 'showing the overlay in a session succeeds')
H.equal(shownReply.visible, true, 'and reports it visible')
H.equal(overlay.shown, 1, 'one native overlay is created')
H.ok(#overlay.lastButtons >= 5, 'it lists the control buttons')
Config.kora_inventory.ui.quickTransfer = false
controlsCall({ show = true })
H.equal(overlay.shown, 1, 'showing again refreshes the existing overlay')
local labels = {}
for _, button in ipairs(overlay.lastButtons) do labels[button.control] = true end
H.ok(not labels[21], 'the button list follows the current config (quick transfer off, no Shift)')
Config.kora_inventory.ui.quickTransfer = true
H.equal(controlsCall({ show = false }).visible, false, 'toggling off hides it')
H.equal(overlay.hidden, 1, 'the overlay was hidden')
controlsCall({ show = 'yes' })
H.equal(overlay.alive, false, 'only a boolean true shows the overlay')
controlsCall({ show = true })
H.equal(overlay.alive, true, 'shown again')
handlers['kora_inventory:ui:sessionClosed']({ token = 'C1' })
H.equal(overlay.alive, false, 'closing the session always hides the overlay')
Config.kora_inventory.ui.controls = { button = false }
handlers['kora_inventory:ui:sessionOpened']({ token = 'C2', primary = view('player:1', 1) })
H.equal(controlsCall({ show = true }).visible, false, 'button = false means the overlay is never shown')
H.equal(overlay.alive, false, 'and nothing is on screen')
Config.kora_inventory.ui.controls = { button = true }
controlsCall({ show = true })
H.equal(overlay.alive, true, 'shown with the button on again')
handlers['kora_hud:ui:editing'](true)
H.equal(overlay.alive, false, 'opening the /ui editor hides the overlay')
controlsCall({ show = true })
uiResourceStop('kora_inventory')
H.equal(overlay.alive, false, 'stopping the resource hides the overlay')
local submits = 0
for _, name in ipairs(triggered) do if name == 'kora_inventory:client:submitIntent' then submits = submits + 1 end end
H.equal(submits, 1, 'the controls callback forwards nothing to the server (only the editor close intent)')
TriggerEvent = function() end
Config.kora_inventory.ui.controls = { button = true, defaultVisible = false }

-- The audit overlay only reads: a query while it is closed is refused locally,
-- and it never produces an inventory intent.
local auditReply
nui['kora_inventory:audit:query']({ item = 'bread' }, function(result) auditReply = result end)
H.equal(auditReply.error, 'closed', 'audit queries are refused while the overlay is closed')
H.equal(#auditAnswers, 0, 'a closed overlay never reaches the server callback')
nui['kora_inventory:audit:close']({}, function(result) auditReply = result end)
H.equal(auditReply.ok, true, 'closing the audit overlay is always acknowledged')

-- Quick slot pins are answered locally and never become a server intent.
local pinReply
nui['kora_inventory:pinQuickSlot']({ id = 'weapon', slot = 3 }, function(result) pinReply = result end)
H.equal(pinReply.ok, false, 'pinQuickSlot answers when the quick slot module is unavailable')
local pinned
KoraInventory.quickSlotsClient = { pin = function(data) pinned = data; return true end }
nui['kora_inventory:pinQuickSlot']({ id = 'weapon', slot = 3 }, function(result) pinReply = result end)
H.equal(pinReply.ok, true, 'pinQuickSlot reports the module verdict')
H.equal(pinned.id, 'weapon', 'pinQuickSlot hands the body to the quick slot module')
KoraInventory.quickSlotsClient = { pin = function() return false, 'item does not fit this quick slot' end }
nui['kora_inventory:pinQuickSlot']({ id = 'weapon', slot = 2 }, function(result) pinReply = result end)
H.equal(pinReply.error, 'item does not fit this quick slot', 'pinQuickSlot passes the refusal reason back')
KoraInventory.quickSlotsClient = { pin = function() error('boom') end }
nui['kora_inventory:pinQuickSlot']({}, function(result) pinReply = result end)
H.equal(pinReply.ok, false, 'a failing pin handler still answers the browser')
H.finish()
