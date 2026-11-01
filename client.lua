-- Client transport for kora_inventory's built-in NUI. The NUI bridge lives in
-- client/ui.lua and subscribes to the local session events below.

local session
local pendingGive
local nextGiveRequestId = 0

-- Shared by submitIntent's 'use' branch below and client/hotbar.lua's
-- keybinds: gates a use behind kora_lib's progress bar when the item defines
-- `useTime`. There is no server-side "was the bar actually shown/completed"
-- flag to trust, so the only safe design is not sending the use request at
-- all until the bar itself reports completion -- a cancelled/never-started
-- bar returns here without ever reaching the server.
---@param item table|nil
---@return boolean completed
function QbInventory.useGate(item)
    local useTime = item and tonumber(item.useTime) or 0
    if useTime <= 0 then
        return true
    end
    -- This bar belongs to the use being submitted from the open panel, so the
    -- busy gate must not close that panel underneath it.
    QbInventory.useGateActive = true
    local ok, completed = pcall(function()
        return Kora.progressbar.start({ label = item.label or item.name, duration = useTime, canCancel = true })
    end)
    QbInventory.useGateActive = false
    return ok and completed == true
end

-- Close an open panel the moment a progress bar starts. Only polls while a
-- session exists.
CreateThread(function()
    while true do
        Wait(session and 250 or 1000)
        if session and QbInventory.isBusy() then
            QbInventory.notifyBusyBlocked()
            TriggerServerEvent('qbinventory:server:close', session.token)
        end
    end
end)

RegisterNetEvent('qbinventory:client:sessionOpened', function(payload)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    if type(payload) ~= 'table' or type(payload.token) ~= 'string' then
        return
    end
    session = payload
    -- Presentation events deliberately use a separate namespace. Triggering the
    -- network handler's own event name would recursively invoke this handler.
    TriggerEvent('qbinventory:ui:sessionOpened', {
        token = payload.token,
        primary = payload.primary,
        secondary = payload.secondary,
        expires = payload.expires,
    })
end)

RegisterNetEvent('qbinventory:client:sessionPatched', function(token, patch)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    if not session or token ~= session.token or type(patch) ~= 'table' then
        return
    end
    -- Authoritative server snapshots replace the corresponding local panel.
    if patch.inventory and patch.key == session.primary.key then
        session.primary = patch.inventory
    end
    if patch.inventory and session.secondary and patch.key == session.secondary.key then
        session.secondary = patch.inventory
    end
    TriggerEvent('qbinventory:ui:sessionPatched', { token = token, patch = patch })
end)

RegisterNetEvent('qbinventory:client:sessionClosed', function(token, reason)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    if not session or token ~= session.token then
        return
    end
    local closed = session
    session = nil
    pendingGive = nil
    TriggerEvent('qbinventory:ui:sessionClosed', { token = token, reason = reason })
end)

RegisterNetEvent('qbinventory:client:rejected', function(reason)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    TriggerEvent('qbinventory:ui:rejected', { reason = reason })
end)

---True while kora_ambulance has the local player downed or dead. UX gate only;
---server.lua enforces the same rule authoritatively.
---@return boolean
function QbInventory.isDowned()
    if Config.qbinventory.blockWhenDowned == false then
        return false
    end
    local data = exports.kora_core:getPlayerData()
    local metadata = data and data.metadata
    return type(metadata) == 'table' and (metadata.isdead == true or metadata.inlaststand == true)
end

local lastDownedNotify = 0
---Notify that an action was blocked while downed, rate limited.
function QbInventory.notifyDownedBlocked()
    local now = GetGameTimer()
    if now - lastDownedNotify < (tonumber(Config.qbinventory.downedNotifyCooldown) or 3000) then
        return
    end
    lastDownedNotify = now
    Kora.notify.send({ title = Kora.lang('inventory.title'), message = Kora.lang('inventory.blocked_downed'), type = 'error' })
end

---True while a kora_lib progress bar is running (other than the use gate's
---own bar) and Config.qbinventory.blockWhileBusy is on. UX gate only; the
---server refuses to drop/give/move a slot being used regardless.
---@return boolean
function QbInventory.isBusy()
    if Config.qbinventory.blockWhileBusy == false or QbInventory.useGateActive then
        return false
    end
    return Kora.progressbar.isActive() == true
end

local lastBusyNotify = 0
---Notify that an action was blocked while busy, rate limited.
function QbInventory.notifyBusyBlocked()
    local now = GetGameTimer()
    if now - lastBusyNotify < (tonumber(Config.qbinventory.downedNotifyCooldown) or 3000) then
        return
    end
    lastBusyNotify = now
    Kora.notify.send({ title = Kora.lang('inventory.title'), message = Kora.lang('inventory.blocked_busy'), type = 'error' })
end

---Open an inventory through the server. `data` is intent only; the server
---resolves/access-checks the inventory before it emits a session snapshot.
---@param invType string
---@param data any
local function openInventory(invType, data)
    if QbInventory.isBusy() then
        QbInventory.notifyBusyBlocked()
        return
    end
    TriggerServerEvent('qbinventory:server:open', invType, data)
end

---@return nil
local function closeInventory()
    if session then
        TriggerServerEvent('qbinventory:server:close', session.token)
    end
end

---Submit a slot transfer from the active session. The server supplies and
---checks both revisions, so stale UI state cannot overwrite another viewer.
---@param intent table
---@return boolean accepted
---@return any result
local function submitIntent(intent)
    if not session or type(intent) ~= 'table' then
        return false, 'no active session'
    end
    -- The built-in UI sends an envelope; keep the direct action shape accepted
    -- for third-party client renderers too.
    if intent.sessionId and intent.sessionId ~= session.token then
        return false, 'stale session'
    end
    if intent.token and intent.token ~= session.token then
        return false, 'stale session'
    end
    local action, payload = intent.intent or intent.action or 'transfer', intent.payload or intent
    if action == 'close' then
        closeInventory()
        return true
    end
    if action == 'give' then
        if payload.inventory and payload.inventory ~= session.primary.key then
            TriggerEvent('qbinventory:ui:rejected', { reason = 'items can only be given from your inventory' })
            return false, 'invalid give inventory'
        end
        local slot = math.floor(tonumber(payload.slot) or 0)
        local item = session.primary.items and session.primary.items[slot]
        local amount = QbInventory.amount(payload.amount, 1)
        if not item or not amount or amount > item.amount then
            TriggerEvent('qbinventory:ui:rejected', { reason = 'invalid item amount' })
            return false, 'invalid item amount'
        end
        nextGiveRequestId = nextGiveRequestId + 1
        pendingGive = {
            id = nextGiveRequestId,
            slot = slot,
            amount = amount,
            primaryRevision = session.primary.revision,
            secondaryRevision = session.secondary and session.secondary.revision,
        }
        TriggerEvent('qbinventory:client:requestGiveTarget', pendingGive.id)
        return true
    end
    if action == 'use' or action == 'drop' or action == 'buy' or action == 'sync' then
        local slot = action == 'use' and math.floor(tonumber(payload.slot) or 0)
        local item = slot and session.primary.items and session.primary.items[slot]
        local clearedBusy = item and item.preventClose ~= true
        if action == 'use' then
            if not QbInventory.useGate(item) then
                -- Cancelled (or never started) progress bar: treat exactly
                -- like a rejected use attempt, without ever contacting the
                -- server, so the effect can never apply for a bar the player
                -- did not actually complete.
                return false, 'cancelled'
            end
            if clearedBusy then
                TriggerEvent('qbinventory:client:useStarted')
            end
        end
        local ok, result = Kora.callback.trigger('qbinventory:server:intent', {
            token = session.token,
            action = action,
            payload = payload,
            primaryRevision = session.primary and session.primary.revision,
            secondaryRevision = session.secondary and session.secondary.revision,
        })
        if not ok then
            -- A callback that errored or timed out has no reason; never hand the
            -- browser a blank one.
            TriggerEvent('qbinventory:ui:rejected', { reason = result or 'inventory request failed' })
            if clearedBusy then
                TriggerEvent('qbinventory:client:useRejected')
            end
        elseif action == 'use' and (type(result) ~= 'table' or result.preventClose ~= true) then
            -- Default behaviour: close the panel after a completed use
            -- (mirrors real qb-inventory's shouldClose). An item opts out of
            -- this with preventClose = true.
            closeInventory()
        end
        return ok == true, result
    end
    if action ~= 'move' and action ~= 'split' and action ~= 'transfer' and action ~= 'swapItems' then
        TriggerEvent('qbinventory:ui:rejected', { reason = 'unsupported intent' })
        return false, 'unsupported intent'
    end
    local secondaryKey = session.secondary and session.secondary.key
    local from = payload.fromInventory or (payload.fromSecondary and secondaryKey or session.primary.key)
    local to = payload.toInventory or (payload.toSecondary and secondaryKey or session.primary.key)
    local fromView = from == session.primary.key and session.primary or session.secondary
    local toView = to == session.primary.key and session.primary or session.secondary
    local ok, result = Kora.callback.trigger('qbinventory:server:transfer', {
        token = session.token,
        fromInventory = from,
        toInventory = to,
        fromSlot = payload.fromSlot,
        toSlot = payload.toSlot,
        amount = payload.amount,
        fromRevision = fromView and fromView.revision,
        toRevision = toView and toView.revision,
    })
    if not ok then
        TriggerEvent('qbinventory:ui:rejected', { reason = result or 'inventory request failed' })
    end
    return ok == true, result
end

-- Recipient ids are deliberately resolved only between local client modules.
-- The browser never receives a nearby-player list, a name, a ped, or a server
-- id; it can only request the give action for a selected own-inventory slot.
AddEventHandler('qbinventory:client:giveTargetResolved', function(result)
    if type(result) ~= 'table' or not pendingGive or result.requestId ~= pendingGive.id then
        return
    end
    local request = pendingGive
    pendingGive = nil
    if result.cancelled or type(result.target) ~= 'number' then
        if result.reason and result.reason ~= 'cancelled' then
            TriggerEvent('qbinventory:ui:rejected', { reason = result.reason })
        end
        return
    end
    if not session then
        return
    end
    TriggerServerEvent('qbinventory:server:intent', {
        token = session.token,
        action = 'give',
        payload = { slot = request.slot, amount = request.amount, target = result.target },
        primaryRevision = request.primaryRevision,
        secondaryRevision = request.secondaryRevision,
    })
end)

-- Local public API for renderer resources. It is intentionally an in-VM event,
-- not a server mutation endpoint: submitIntent still routes to the validated
-- server transport above.
AddEventHandler('qbinventory:client:submitIntent', function(intent)
    submitIntent(intent)
end)

---@return table|nil session
local function getCurrentSession()
    return session and QbInventory.copy(session) or nil
end

---@param names string|string[]
---@param amount number|nil
---@return boolean hasItems
local function hasItem(names, amount)
    local data = exports.kora_core:getPlayerData() or {}
    local items = data.items or {}
    local function count(name)
        local count = 0
        for _, item in pairs(items) do
            if item.name == name then
                count = count + (item.amount or 0)
            end
        end
        return count
    end
    if type(names) == 'table' then
        for _, name in ipairs(names) do
            if count(name) < (amount or 1) then
                return false
            end
        end
        return true
    end
    return count(names) >= (amount or 1)
end

QbInventory.clientApi = {
    openInventory = openInventory,
    closeInventory = closeInventory,
    submitIntent = submitIntent,
    getCurrentSession = getCurrentSession,
    hasItem = hasItem,
}

exports('openInventory', openInventory)
exports('closeInventory', closeInventory)
exports('submitIntent', submitIntent)
exports('getCurrentSession', getCurrentSession)
exports('HasItem', hasItem)

-- ONE module owns ONE identity. client/compat/ox.lua owns `ox_inventory`
-- wholesale, including its own openInventory/closeInventory wrappers; this file
-- owns `qb-inventory`. Registering the same name on the same identity from two
-- files "works" only because the later AddEventHandler wins, so the behaviour
-- would silently change if client_scripts were reordered -- and ox's wrapper
-- carries state (the setStashTarget substitution) that the plain function does
-- not. HasItem is a qb-inventory export only; ox has no client HasItem.
for _, exportName in ipairs({ 'HasItem', 'openInventory', 'closeInventory' }) do
    local fn = exportName == 'HasItem' and hasItem or exportName == 'openInventory' and openInventory or closeInventory
    Kora.compat.provideExport('qb-inventory', exportName, fn)
end

AddEventHandler('onClientResourceStop', function(name)
    if name == GetCurrentResourceName() then
        pendingGive = nil
        closeInventory()
    end
end)

-- Close an open inventory the moment the player goes down (kora_ambulance sets
-- these metadata keys; kora_core replicates them).
for _, key in ipairs({ 'isdead', 'inlaststand' }) do
    exports.kora_core:onPlayerDataChange({ 'metadata', key }, function(_, value)
        if value == true and session and QbInventory.isDowned() then
            closeInventory()
            QbInventory.notifyDownedBlocked()
        end
    end)
end
