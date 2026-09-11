-- The bundled UI is intentionally presentation-only. qbinventory owns session
-- creation, all inventory state and every server request; this bridge just
-- translates its local client events into this resource's NUI wire contract.
local activeSession
local activeToken

local allowedIntents = {
    close = true,
    move = true,
    use = true,
    drop = true,
    give = true,
    buy = true,
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
local function pushConfig()
    local ui = Config.qbinventory.ui or {}

    send('qbinventory:nui:config', {
        hotbarSlots = Config.qbinventory.hotbarSlots,
        centreWhenSolo = ui.centreWhenSolo ~= false,
        showHotbar = ui.showHotbar ~= false,
        images = ui.images,
    })
end

local function closeSession(reason)
    if not activeSession then return end

    send('qbinventory:nui:sessionClosed', {
        sessionId = activeSession,
        reason = reason or 'closed',
    })
    activeSession = nil
    activeToken = nil
    SetNuiFocus(false, false)
end

-- Payload is produced by qbinventory only. Expected minimum wire shape is
-- { sessionId, token, player, secondary?, revision, secondaryRevision? }.
local function normalizeView(view)
    if type(view) ~= 'table' then return nil end
    -- qbinventory's public view calls the server-side inventory identifier
    -- `key`; the web UI names this transport-only field `id`.
    local out = {}
    for key, value in pairs(view) do out[key] = value end
    out.id = view.key or view.id
    return out
end

-- These `qbinventory:ui:*` events are explicitly local presentation events.
-- qbinventory's network transport retains `qbinventory:client:*`, preventing
-- a UI listener from ever accidentally re-entering a network event handler.
AddEventHandler('qbinventory:ui:sessionOpened', function(payload)
    if type(payload) ~= 'table' or type(payload.token) ~= 'string' then
        return
    end

    activeToken = payload.token
    activeSession = payload.sessionId or payload.token
    local wire = {
        sessionId = activeSession,
        token = payload.token,
        revision = payload.revision or (payload.player or payload.primary or {}).revision,
        secondaryRevision = payload.secondaryRevision or (payload.secondary or {}).revision,
        player = normalizeView(payload.player or payload.primary),
        secondary = normalizeView(payload.secondary),
        expires = payload.expires,
    }
    if not wire.player then return end
    pushTheme()
    pushConfig()
    send('qbinventory:nui:sessionOpened', wire)
    SetNuiFocus(true, true)
    TriggerEvent('qbinventory:client:requestGiveAvailability')
end)

-- Patches must carry the session id so delayed traffic cannot change a later
-- session after close/reopen. qbinventory remains authoritative on revisions.
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
    if type(patch) ~= 'table' or token ~= activeToken then return end

    -- Accept qbinventory's compact `{ key, revision, inventory }` patch and
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
        if changed and changed.id and changed.id:find('player:', 1, true) == 1 then wire.player = changed else wire.secondary = changed end
    end
    send('qbinventory:nui:sessionPatched', wire)
end)

AddEventHandler('qbinventory:ui:sessionClosed', function(payload, legacyReason)
    local token = type(payload) == 'table' and payload.token or payload
    if token ~= activeToken then return end
    closeSession(type(payload) == 'table' and payload.reason or legacyReason)
end)

AddEventHandler('qbinventory:ui:rejected', function(payload)
    local reason = type(payload) == 'table' and payload.reason or payload
    send('qbinventory:nui:rejected', { reason = tostring(reason or 'Action rejected') })
end)

-- This is a local presentation relay for the server-authoritative receipt
-- payload. It intentionally works without an open inventory session.
RegisterNetEvent('qbinventory:client:itemBox', function(payload)
    if type(payload) ~= 'table' or type(payload.name) ~= 'string' then return end
    send('qbinventory:nui:itemBox', payload)
end)

-- The target resolver reports presentation state only.  While an in-world
-- target selection is active, relinquish NUI focus so qbtarget can receive
-- gameplay input; restore it immediately on resolve or cancellation.
AddEventHandler('qbinventory:ui:giveTargeting', function(payload)
    if not activeSession or type(payload) ~= 'table' then return end
    SetNuiFocus(payload.active ~= true, payload.active ~= true)
end)

-- Only a boolean crosses this presentation boundary.  Player identities and
-- recipient server ids stay in client/give_target.lua and client.lua.
AddEventHandler('qbinventory:ui:giveAvailability', function(payload)
    if not activeSession or type(payload) ~= 'table' then return end
    send('qbinventory:nui:giveAvailability', { available = payload.available == true })
end)

-- qblib computes the tokens in Lua, so this bridge does not duplicate the
-- design-system HSL math in TypeScript. qbinventory can trigger this local
-- event after a live theme change without involving inventory authority.
AddEventHandler('qbinventory:client:theme', QBTheme.refresh)

RegisterNUICallback('qbinventory:nui:intent', function(data, cb)
    if type(data) ~= 'table'
        or data.sessionId ~= activeSession
        or type(data.token) ~= 'string'
        or type(data.intent) ~= 'string'
        or not allowedIntents[data.intent]
        or type(data.payload) ~= 'table' then
        cb({ ok = false, error = 'invalid intent' })
        return
    end

    -- Wait for qbinventory's authoritative callback result. This keeps the
    -- browser locked until validation and any yielding useable handler finish,
    -- rather than acknowledging a merely-local hand-off as success.
    local ok, result = submitIntent({
        sessionId = data.sessionId,
        token = data.token,
        intent = data.intent,
        payload = data.payload,
    })
    cb({ ok = ok == true, error = ok and nil or result })
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

AddEventHandler('onResourceStart', function(resource)
    if resource == GetCurrentResourceName() then
        pushTheme()
        pushConfig()
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        closeSession('resource_stop')
    end
end)
