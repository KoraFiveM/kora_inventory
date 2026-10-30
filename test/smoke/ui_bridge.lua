local H = dofile('test/harness.lua')
local file = assert(io.open('client/ui.lua', 'r'))
local source = file:read('*a')
file:close()

H.ok(source:find("type%(payload%.patch%) == 'table'"),
    'unwraps the client transport { token, patch } envelope')
H.ok(source:find('token, patch = payload.token, payload.patch', 1, true),
    'keeps the session token paired with the inner authoritative patch')
H.ok(source:find("send('qbinventory:nui:sessionPatched', wire)", 1, true),
    'forwards the normalised authoritative patch to the browser')
H.ok(source:find("'qbinventory:client:itemBox'", 1, true),
    'relays inventory-owned item receipt payloads to the bundled UI')
H.ok(source:find("send('qbinventory:nui:itemBox', payload)", 1, true),
    'item receipts can render without an inventory session')
H.ok(source:find("QB.notify.send({", 1, true),
    'rejected inventory actions are presented as notifications')

Config = {}
dofile('config.lua')
local images = Config.qbinventory.ui.images
H.equal(images.localPath, 'nui://kora_inventory/images', 'artwork uses kora_inventory NUI paths')
H.equal(images.preferLocal, true, 'bundled artwork is preferred over remote fallbacks')

H.equal(Config.qbinventory.ui.scale, 1.0, 'UI scale defaults to 1.0 so the layout is unchanged')
H.ok(source:find('scale = math.max(0.5, math.min(2.0, tonumber(ui.scale) or 1.0))', 1, true),
    'the scale is read live and clamped on every config push')

H.equal(Config.qbinventory.ui.rightClickSplit, true, 'right-click split defaults on')
H.ok(source:find('rightClickSplit = ui.rightClickSplit ~= false', 1, true), 'rightClickSplit is pushed to the NUI on every config push')

local canonicalImage = io.open('images/advancedlockpick.png', 'rb')
H.ok(canonicalImage ~= nil, 'canonical qb-inventory artwork is bundled')
if canonicalImage then canonicalImage:close() end

-- Exercise the actual bridge; host presentation calls only record messages.
local handlers, messages = {}, {}
AddEventHandler = function(name, callback) handlers[name] = callback end
RegisterNetEvent = AddEventHandler
RegisterNUICallback = function() end
SetNuiFocus, TriggerEvent = function() end, function() end
SendNUIMessage = function(message) messages[#messages + 1] = message end
GetCurrentResourceName = function() return 'kora_inventory' end
QBTheme = { refresh = function() end }
QB = { notify = { send = function() end } }
dofile(arg[1] or 'client/ui.lua')
local function view(id, revision)
    return { key = id, revision = revision, items = {}, slots = 4 }
end
local function compact(id, revision)
    return { key = id, revision = revision, inventory = view(id, revision) }
end
handlers['qbinventory:ui:sessionOpened']({ token = 'A', primary = view('player:1', 3), secondary = view('player:2', 5) })
H.equal(messages[#messages].data.player.id, 'player:1', 'primary server key becomes the player view id')
H.equal(messages[#messages].data.secondary.id, 'player:2', 'inspected player keeps a separate view id')
H.equal(messages[#messages].data.revision, 3, 'open keeps primary revision')
H.equal(messages[#messages].data.secondaryRevision, 5, 'open keeps secondary revision')

handlers['qbinventory:ui:sessionPatched']({ token = 'A', patch = compact('player:1', 4) })
local patch = messages[#messages].data
H.equal(patch.player.id, 'player:1', 'primary compact update reaches player panel')
H.equal(patch.secondary, nil, 'primary update leaves secondary untouched')
H.equal(patch.revision, 4, 'primary counter stays in primary revision')

for _, form in ipairs({ 'wrapped', 'legacy', 'direct' }) do
    local changed = compact('player:2', 6)
    if form == 'wrapped' then
        handlers['qbinventory:ui:sessionPatched']({ token = 'A', patch = changed })
    elseif form == 'legacy' then
        handlers['qbinventory:ui:sessionPatched']('A', changed)
    else
        changed.token = 'A'
        handlers['qbinventory:ui:sessionPatched'](changed)
    end
    patch = messages[#messages].data
    H.equal(patch.sessionId, 'A', form .. ' compact update keeps session id')
    H.equal(patch.player, nil, form .. ' inspected update leaves player panel untouched')
    H.equal(patch.secondary.id, 'player:2', form .. ' inspected update reaches secondary panel')
    H.equal(patch.revision, nil, form .. ' inspected counter cannot replace primary revision')
    H.equal(patch.secondaryRevision, 6, form .. ' inspected counter reaches secondary revision')
end

local snapshot = { sessionId = 'A', player = { id = 'player:1' }, secondary = { id = 'player:2' } }
handlers['qbinventory:ui:sessionPatched']({ token = 'A', patch = {
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
handlers['qbinventory:ui:sessionPatched']({ token = 'stale', patch = compact('player:1', 10) })
handlers['qbinventory:ui:sessionPatched']({ token = 'A', patch = compact('player:3', 10) })
handlers['qbinventory:ui:sessionPatched']({ token = 'A', patch = compact('stash:other', 10) })
H.equal(#messages, count, 'stale tokens and inventories outside the session are ignored')
handlers['qbinventory:ui:sessionClosed']({ token = 'A' })
count = #messages
handlers['qbinventory:ui:sessionPatched']({ token = 'A', patch = compact('player:2', 10) })
H.equal(#messages, count, 'closed session ignores delayed compact updates')

handlers['qbinventory:ui:sessionOpened']({ token = 'B', player = { id = 'player:3', revision = 1 } })
count = #messages
handlers['qbinventory:ui:sessionPatched']({ token = 'B', patch = compact('player:2', 10) })
H.equal(#messages, count, 'solo reopen cannot reuse the old secondary identity')
handlers['qbinventory:ui:sessionPatched']({ token = 'B', patch = compact('player:3', 2) })
H.equal(messages[#messages].data.player.id, 'player:3', 'reopen replaces primary identity')

handlers['qbinventory:ui:sessionOpened']({ token = 'C', primary = view('player:1', 10), secondary = view('stash:locker', 20) })
handlers['qbinventory:ui:sessionPatched']({ token = 'C', patch = compact('stash:locker', 21) })
patch = messages[#messages].data
H.equal(patch.secondary.id, 'stash:locker', 'storage compact update still reaches secondary panel')
H.equal(patch.player, nil, 'storage update leaves player untouched')
H.equal(patch.revision, nil, 'storage counter leaves primary revision untouched')
H.equal(patch.secondaryRevision, 21, 'storage counter reaches secondary revision')
H.finish()
