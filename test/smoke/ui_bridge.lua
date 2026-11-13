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
H.ok(source:find("Kora.notify.send({", 1, true),
    'rejected inventory actions are presented as notifications')

Config = {}
dofile('config.lua')
local images = Config.kora_inventory.ui.images
H.equal(images.localPath, 'nui://kora_inventory/images', 'artwork uses kora_inventory NUI paths')
H.equal(images.preferLocal, true, 'bundled artwork is preferred over remote fallbacks')

H.equal(Config.kora_inventory.ui.scale, 1.0, 'UI scale defaults to 1.0 so the layout is unchanged')
H.ok(source:find('scale = Kora.util.clamp(tonumber(ui.scale) or 1.0, 0.5, 2.0)', 1, true),
    'the scale is read live and clamped on every config push')

H.equal(Config.kora_inventory.ui.rightClickSplit, true, 'right-click split defaults on')
H.ok(source:find('rightClickSplit = ui.rightClickSplit ~= false', 1, true), 'rightClickSplit is pushed to the NUI on every config push')

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

H.equal(images.cdn, 'https://cdn.koraframe.work/inventory', 'items with no local artwork fall back to the inventory CDN')
H.equal(images.cdnExtension, 'webp', 'the inventory CDN serves webp')

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
dofile(arg[1] or 'client/ui.lua')

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
KoraInventory = { clientApi = { submitIntent = function(...) return submit(...) end } }
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
    H.ok(file == 'client/ui.lua' or file == 'fft_hooks.lua', 'unexpected NUI callback owner: ' .. file)
end
scan:close()
local registered = 0
for name in pairs(nui) do
    registered = registered + 1
    H.ok(name == 'kora_inventory:nui:intent' or name == 'kora_inventory:nui:close' or name == 'fft:result' or name == 'fft:observed', 'unexpected NUI callback ' .. name)
end
H.equal(registered, 4, 'gameplay and optional development callbacks are covered')
H.finish()
