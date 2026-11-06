-- The bundled UI is intentionally presentation-only. kora_inventory owns session
-- creation, all inventory state and every server request; this bridge just
-- translates its local client events into this resource's NUI wire contract.
-- Locale text with an English fallback (shared.lua's QbInventory.text).
local function localeText(key, fallback, vars)
    local text = QbInventory and QbInventory.text
    return text and text(key, fallback, vars) or fallback
end

local activeSession
local activeToken
local activePlayerId
local activeSecondaryId
local lastSessionChange = 0

local allowedIntents = {
    close = true,
    move = true,
    use = true,
    drop = true,
    give = true,
    buy = true,
    sync = true,
    split = true,
    action = true,
}

local function send(action, data)
    SendNUIMessage({ action = action, data = data })
end

local function pushTheme()
    QBTheme.refresh()
end

-- The presentation half of Config.qbinventory, and the ONLY config that crosses
-- into the browser. Sent as a whole table rather than folded into the theme
-- tokens (which are CSS custom properties, not structured data), and re-sent on
-- every session open so a UI that reloaded mid-session is never left rendering
-- defaults.
--
-- hotbarSlots is included because the NUI draws the hotbar boundary and cannot
-- know where it is otherwise; it stays a read of the same single source
-- client/hotbar.lua binds its keys from, so the outline and the keys cannot
-- disagree.
-- How long the UI, and this bridge, wait for the server to answer a request
-- before giving up on it (ms). Config.qbinventory.ui.moveTimeoutMs, or the
-- older moveTimeout in seconds when only that is configured. With the direct
-- transport the browser's fetch is acknowledged at once, so a long deadline
-- costs nothing (no busy cursor, no snap-back at a normal lag spike); the
-- blocking fallback keeps the short one because its fetch stays pending.
local function directTransport()
    local ui = (Config.qbinventory or {}).ui or {}
    return ui.directTransport ~= false
end

local function moveTimeoutMs()
    local ui = (Config.qbinventory or {}).ui or {}
    local ms = tonumber(ui.moveTimeoutMs)
    if not ms and tonumber(ui.moveTimeout) then
        ms = tonumber(ui.moveTimeout) * 1000
    end
    return math.floor(math.max(500, math.min(60000, ms or (directTransport() and 6000 or 1500))))
end

local function pushConfig()
    local ui = Config.qbinventory.ui or {}

    send('qbinventory:nui:config', {
        hotbarSlots = Config.qbinventory.hotbarSlots,
        centreWhenSolo = ui.centreWhenSolo ~= false,
        showHotbar = ui.showHotbar ~= false,
        rightClickSplit = ui.rightClickSplit ~= false,
        optimisticMoves = ui.optimisticMoves ~= false,
        -- Drags made while a move is awaiting the server are queued rather than
        -- refused (only meaningful with optimisticMoves).
        queueMoves = ui.queueMoves ~= false,
        -- How long the UI waits for the server before rolling a move back.
        moveTimeoutMs = moveTimeoutMs(),
        -- The server's verdict arrives as `qbinventory:nui:intentResult`
        -- instead of holding the browser's fetch open.
        directTransport = directTransport(),
        -- Read on every push so a live config change applies on the next open.
        scale = math.max(0.5, math.min(2.0, tonumber(ui.scale) or 1.0)),
        images = ui.images,
        inspectorDecimals = math.max(0, math.min(3, math.floor(tonumber((Config.Inspector or {}).decimals) or 1))),
        -- Selectable inspector text + Copy button (item as JSON, incl. metadata).
        inspectorCopy = (Config.Inspector or {}).allowCopy ~= false,
        -- Slot border thickness in CSS px.
        slotBorderWidth = math.max(1, math.min(4, tonumber((Config.Slots or {}).borderWidth) or 2)),
    })
end

-- Per-player window placement from kora_hud's /ui editor (position, size,
-- which side the personal inventory sits on, and whether stashes/trunks use
-- the custom position). Presentation only: nothing here reaches the server or
-- inventory state. Without kora_hud, or with Config.qbinventory.ui.playerLayout
-- = false, the window stays exactly as configured.
local UI_ID = 'inventory'
local function uiConfig()
    return (Config.qbinventory or {}).ui or {}
end

local function defaultPlayerLayout()
    return {
        x = 0, y = 0, scale = 1, placed = false,
        playerSide = 'left',
        useForTransfer = uiConfig().playerLayoutTransfer == true,
    }
end
local playerLayout = defaultPlayerLayout()

local function clampNumber(value, min, max, fallback)
    value = tonumber(value)
    if not value or value ~= value then return fallback end
    return math.max(min, math.min(max, value))
end

---Re-validated at this boundary like every other value that reaches the NUI.
local function setPlayerLayout(layout)
    local defaults = defaultPlayerLayout()
    if type(layout) ~= 'table' then
        playerLayout = defaults
    else
        local settings = type(layout.settings) == 'table' and layout.settings or {}
        playerLayout = {
            x = clampNumber(layout.x, -1, 1, 0),
            y = clampNumber(layout.y, -1, 1, 0),
            scale = clampNumber(layout.scale, 0.75, 1.25, 1),
            placed = layout.placed == true,
            playerSide = settings.playerSide == 'right' and 'right' or 'left',
            useForTransfer = type(settings.useForTransfer) == 'boolean' and settings.useForTransfer or defaults.useForTransfer,
        }
    end
    send('qbinventory:nui:layout', playerLayout)
end

local function closeSession(reason)
    if not activeSession then
        return
    end

    send('qbinventory:nui:sessionClosed', {
        sessionId = activeSession,
        reason = reason or 'closed',
    })
    activeSession = nil
    activeToken = nil
    activePlayerId = nil
    activeSecondaryId = nil
    lastSessionChange = GetGameTimer()
    SetNuiFocus(false, false)
end

-- Payload is produced by kora_inventory only. Expected minimum wire shape is
-- { sessionId, token, player, secondary?, revision, secondaryRevision? }.
local function normalizeView(view)
    if type(view) ~= 'table' then
        return nil
    end
    -- kora_inventory's public view calls the server-side inventory identifier
    -- `key`; the web UI names this transport-only field `id`.
    local out = {}
    for key, value in pairs(view) do
        out[key] = value
    end
    out.id = view.key or view.id
    return out
end

-- These `qbinventory:ui:*` events are explicitly local presentation events.
-- kora_inventory's network transport retains `qbinventory:client:*`, preventing
-- a UI listener from ever accidentally re-entering a network event handler.
AddEventHandler('qbinventory:ui:sessionOpened', function(payload)
    if type(payload) ~= 'table' or type(payload.token) ~= 'string' then
        return
    end

    activeToken = payload.token
    activeSession = payload.sessionId or payload.token
    lastSessionChange = GetGameTimer()
    local wire = {
        sessionId = activeSession,
        token = payload.token,
        revision = payload.revision or (payload.player or payload.primary or {}).revision,
        secondaryRevision = payload.secondaryRevision or (payload.secondary or {}).revision,
        player = normalizeView(payload.player or payload.primary),
        secondary = normalizeView(payload.secondary),
        expires = payload.expires,
    }
    if not wire.player then
        return
    end
    activePlayerId = wire.player.id
    activeSecondaryId = wire.secondary and wire.secondary.id
    pushTheme()
    pushConfig()
    send('qbinventory:nui:layout', playerLayout)
    send('qbinventory:nui:sessionOpened', wire)
    SetNuiFocus(true, true)
    TriggerEvent('qbinventory:client:requestGiveAvailability')
end)

-- Distance from the screen bottom (px) for the on-screen hotbar, from
-- Config.Hotbar. Read per call so a live config edit applies on the next show.
local function hotbarBottom()
    local settings = Config.Hotbar or {}
    local key = Kora.cache.vehicle() and 'vehicleBottomOffset' or 'bottomOffset'
    local fallback = key == 'bottomOffset' and 90 or 130
    local value = tonumber(settings[key])
    return math.floor(math.max(0, math.min(600, value or fallback)))
end

-- The hotbar may be on screen while the player gets in or out; move it then.
Kora.cache.onChange('vehicle', function()
    send('qbinventory:nui:hotbarPosition', { bottom = hotbarBottom() })
end)

-- Local presentation relay for client/hotbar.lua's show-hotbar key. Works
-- without an open session, so theme and config are pushed first.
AddEventHandler('qbinventory:ui:hotbarShow', function(payload)
    if type(payload) ~= 'table' or activeSession then
        return
    end
    pushTheme()
    pushConfig()
    payload.bottom = hotbarBottom()
    send('qbinventory:nui:hotbar', payload)
end)

-- Patches must carry the session id so delayed traffic cannot change a later
-- session after close/reopen. kora_inventory remains authoritative on revisions.
AddEventHandler('qbinventory:ui:sessionPatched', function(payload, legacyPatch)
    local token, patch
    if type(payload) == 'string' then
        token, patch = payload, legacyPatch
    elseif type(payload) == 'table' and type(payload.patch) == 'table' then
        -- client.lua forwards the authoritative network patch as a wrapper so
        -- the presentation event keeps its token separate from its payload.
        -- Unwrap it before normalising, otherwise no inventory patch reaches
        -- the browser and a pending UI move can never settle.
        token, patch = payload.token, payload.patch
    else
        patch, token = payload, payload and payload.token
    end
    if type(patch) ~= 'table' or token ~= activeToken then
        return
    end

    -- Accept kora_inventory's compact `{ key, revision, inventory }` patch and
    -- the normalized `{ player?, secondary? }` form for future UI consumers.
    local wire = {
        sessionId = activeSession,
        revision = patch.revision,
        secondaryRevision = patch.secondaryRevision,
        player = patch.player and normalizeView(patch.player) or nil,
        secondary = patch.secondary and normalizeView(patch.secondary) or nil,
        snapshot = patch.snapshot,
    }
    if patch.inventory then
        local changed = normalizeView(patch.inventory)
        if not changed or not changed.id then
            return
        end
        if changed.id == activePlayerId then
            wire.player = changed
        elseif changed.id == activeSecondaryId then
            wire.secondary = changed
            wire.secondaryRevision = patch.revision or patch.secondaryRevision
            wire.revision = nil
        else
            return
        end
    end
    send('qbinventory:nui:sessionPatched', wire)
end)

AddEventHandler('qbinventory:ui:sessionClosed', function(payload, legacyReason)
    local token = type(payload) == 'table' and payload.token or payload
    if token ~= activeToken then
        return
    end
    closeSession(type(payload) == 'table' and payload.reason or legacyReason)
end)

-- Refusals about a session that has just been closed or reopened, and the same
-- refusal repeated for a burst of identical requests, are noise: the player
-- sees one notice per distinct problem.
local STALE_REASONS = { ['invalid session'] = true, ['stale session'] = true, ['no active session'] = true, ['session expired'] = true }
local STALE_WINDOW, REPEAT_WINDOW = 3000, 1500
local lastNotice = { reason = nil, at = 0 }

AddEventHandler('qbinventory:ui:rejected', function(payload)
    local reason = type(payload) == 'table' and payload.reason or payload
    local stamp = GetGameTimer()
    local text = tostring(reason or 'Action rejected')
    if STALE_REASONS[text] and stamp - lastSessionChange < STALE_WINDOW then
        return
    end
    if text == lastNotice.reason and stamp - lastNotice.at < REPEAT_WINDOW then
        return
    end
    lastNotice.reason, lastNotice.at = text, stamp
    Kora.notify.send({
        title = localeText('inventory.title', 'Inventory'),
        message = tostring(reason or 'Action rejected'),
        type = 'error',
    })
end)

-- A stock script reports its own item change with the legacy event, and the
-- server's receipt for the same change arrives too (the inventory owns receipts
-- for AddItem/RemoveItem). Whichever is seen second inside the window is the
-- duplicate and is dropped, so each change draws one box.
local RECEIPT_WINDOW = 5000
local seenReceipts = { native = {}, legacy = {} }

local function receiptKey(name, action)
    return ('%s:%s'):format(name, action)
end

local function takeSeen(pool, key)
    local list = pool[key]
    while list and #list > 0 do
        if GetGameTimer() - table.remove(list, 1) <= RECEIPT_WINDOW then
            return true
        end
    end
    return false
end

local function remember(pool, key)
    pool[key] = pool[key] or {}
    pool[key][#pool[key] + 1] = GetGameTimer()
end

-- This is a local presentation relay for the server-authoritative receipt
-- payload. It intentionally works without an open inventory session.
RegisterNetEvent('qbinventory:client:itemBox', function(payload)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    if type(payload) ~= 'table' or type(payload.name) ~= 'string' then
        return
    end
    local key = receiptKey(payload.name, payload.action)
    if takeSeen(seenReceipts.legacy, key) then
        return
    end
    remember(seenReceipts.native, key)
    send('qbinventory:nui:itemBox', payload)
end)

local legacyActions = { add = 'showAdditions', remove = 'showRemovals', use = 'showUses' }

-- Cosmetic only. A stock script triggers qb-inventory:client:ItemBox with an
-- item record; nothing in it is believed beyond the item NAME, and label and
-- artwork come from kora_core's registry. The server's itemBoxes policy applies.
AddEventHandler('qbinventory:ui:legacyItemBox', function(itemData, action, amount)
    local policy = Config.qbinventory.itemBoxes
    local policyField = legacyActions[action]
    if type(policy) ~= 'table' or policy.enabled ~= true or not policyField or policy[policyField] ~= true then
        return
    end
    local name = type(itemData) == 'table' and itemData.name or itemData
    if type(name) ~= 'string' then
        return
    end
    name = name:lower()
    local def = exports.kora_core:getShared('items', name) or exports.kora_core:getShared('weapons', name)
    if type(def) ~= 'table' then
        return
    end
    local key = receiptKey(name, action)
    if takeSeen(seenReceipts.native, key) then
        return
    end
    remember(seenReceipts.legacy, key)
    send('qbinventory:nui:itemBox', {
        name = def.name or name,
        label = def.label or name,
        image = def.image,
        imageUrl = def.imageUrl,
        amount = math.max(1, math.floor(tonumber(amount) or 1)),
        action = action,
        duration = math.max(750, math.floor(tonumber(policy.duration) or 2600)),
    })
end)

-- The target resolver reports presentation state only.  While an in-world
-- target selection is active, relinquish NUI focus so kora_target can receive
-- gameplay input; restore it immediately on resolve or cancellation.
AddEventHandler('qbinventory:ui:giveTargeting', function(payload)
    if not activeSession or type(payload) ~= 'table' then
        return
    end
    SetNuiFocus(payload.active ~= true, payload.active ~= true)
end)

-- Only a boolean crosses this presentation boundary.  Player identities and
-- recipient server ids stay in client/give_target.lua and client.lua.
AddEventHandler('qbinventory:ui:giveAvailability', function(payload)
    if not activeSession or type(payload) ~= 'table' then
        return
    end
    send('qbinventory:nui:giveAvailability', { available = payload.available == true })
end)

-- kora_lib computes the tokens in Lua, so this bridge does not duplicate the
-- design-system HSL math in TypeScript. kora_inventory can trigger this local
-- event after a live theme change without involving inventory authority.
AddEventHandler('qbinventory:client:theme', QBTheme.refresh)

RegisterNUICallback('qbinventory:nui:intent', function(data, cb)
    if
        type(data) ~= 'table'
        or data.sessionId ~= activeSession
        or type(data.token) ~= 'string'
        or type(data.intent) ~= 'string'
        or not allowedIntents[data.intent]
        or type(data.payload) ~= 'table'
    then
        cb({ ok = false, error = 'invalid intent' })
        return
    end

    -- Direct transport: acknowledge the fetch immediately and deliver the
    -- server's verdict as an NUI message tagged with the browser's request id.
    -- Nothing is left pending in the browser, so there is no busy cursor, and
    -- the browser decides when a slow answer is a failure. Browsers that send
    -- no request id (an older bundle, the dev harness) get the blocking reply.
    local requestId = tonumber(data.requestId)
    if requestId and directTransport() then
        cb({ ok = true, pending = true, requestId = requestId })
        local delivered = false
        local function deliver(ok, err)
            if delivered then
                return
            end
            delivered = true
            send('qbinventory:nui:intentResult', { requestId = requestId, ok = ok == true, error = ok and nil or err })
        end
        if data.intent ~= 'use' then
            SetTimeout(moveTimeoutMs(), function()
                deliver(false, 'timeout')
            end)
        end
        local called, ok, result = pcall(QbInventory.clientApi.submitIntent, {
            sessionId = data.sessionId,
            token = data.token,
            intent = data.intent,
            payload = data.payload,
            announce = false,
        })
        if data.sessionId ~= activeSession then
            -- Closed or reopened while this was in flight: the browser has
            -- already dropped its queue, so its old verdict is not reported.
            delivered = true
        elseif not called then
            print(('^3[qbinventory]^7 intent failed: %s'):format(tostring(ok)))
            deliver(false, 'inventory request failed')
        else
            deliver(ok == true, type(result) == 'string' and result or 'action rejected')
        end
        return
    end

    -- The browser's fetch stays pending (busy cursor, no dragging) until cb runs,
    -- so cb runs exactly once and never later than the move deadline: if the
    -- server round trip is still outstanding then, the browser is answered
    -- { ok = false, error = 'timeout' } and the late result is dropped (the UI
    -- rolls back and asks for a resync). `use` is exempt: it may wait on a
    -- progress bar.
    local answered = false
    local function reply(result)
        if answered then
            return
        end
        answered = true
        cb(result)
    end
    if data.intent ~= 'use' then
        SetTimeout(moveTimeoutMs(), function()
            reply({ ok = false, error = 'timeout' })
        end)
    end

    -- Wait for kora_inventory's authoritative callback result, rather than
    -- acknowledging a merely-local hand-off as success. pcall'd so that an error
    -- in the transport still answers the browser.
    local called, ok, result = pcall(QbInventory.clientApi.submitIntent, {
        sessionId = data.sessionId,
        token = data.token,
        intent = data.intent,
        payload = data.payload,
        announce = false,
    })
    if not called then
        print(('^3[qbinventory]^7 intent failed: %s'):format(tostring(ok)))
        reply({ ok = false, error = 'inventory request failed' })
        return
    end
    reply({ ok = ok == true, error = ok and nil or result })
end)

RegisterNUICallback('qbinventory:nui:close', function(data, cb)
    if type(data) == 'table' and data.sessionId == activeSession and type(data.token) == 'string' then
        TriggerEvent('qbinventory:client:submitIntent', {
            sessionId = data.sessionId,
            token = data.token,
            intent = 'close',
            payload = {},
        })
    end
    cb({ ok = true })
end)

local function editorWanted()
    return uiConfig().playerLayout ~= false
        and type(GetResourceState) == 'function' and GetResourceState('kora_hud') == 'started'
end

-- The editor box is the personal inventory window at its default size,
-- centred (~540x670 px of the shared 1920x1080 root). The transfer view is
-- larger, but it is centred on the same point and scales from it too.
local function registerWithEditor()
    if not editorWanted() then return end
    pcall(function()
        exports['kora_hud']:registerUiElement({
            id = UI_ID,
            label = 'Inventory',
            group = 'Inventory',
            rect = { x = 0.359, y = 0.19, w = 0.282, h = 0.62 },
            origin = 'center center',
            movable = true,
            scalable = true,
            hideable = false,
            scaleMin = 0.75,
            scaleMax = 1.25,
            settings = {
                { key = 'playerSide', label = 'Personal inventory side (stash/trunk view)', type = 'select',
                  default = 'left', options = { { value = 'left', label = 'Left' }, { value = 'right', label = 'Right' } } },
                { key = 'useForTransfer', label = 'Use my position for stashes and trunks', type = 'toggle',
                  default = uiConfig().playerLayoutTransfer == true,
                  description = 'Off: stashes, trunks and gloveboxes open centred in the default two-panel layout.' },
            },
        })
    end)
end

AddEventHandler('kora_hud:ui:apply', function(owner, id, layout)
    if owner ~= GetCurrentResourceName() or id ~= UI_ID then return end
    setPlayerLayout(layout)
end)

AddEventHandler('kora_hud:ui:ready', registerWithEditor)

-- The /ui editor takes NUI focus; an open inventory closes through the normal
-- close intent (the server ends the session) rather than sitting under it.
AddEventHandler('kora_hud:ui:editing', function(active)
    if active ~= true or not activeSession or type(activeToken) ~= 'string' then return end
    TriggerEvent('qbinventory:client:submitIntent', {
        sessionId = activeSession,
        token = activeToken,
        intent = 'close',
        payload = {},
    })
end)

AddEventHandler('onClientResourceStart', function(resource)
    if resource == 'kora_hud' and type(SetTimeout) == 'function' then SetTimeout(250, registerWithEditor) end
end)

AddEventHandler('onResourceStart', function(resource)
    if resource == GetCurrentResourceName() then
        pushTheme()
        pushConfig()
        registerWithEditor()
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        closeSession('resource_stop')
    end
end)
