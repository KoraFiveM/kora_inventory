-- Client transport for qbinventory's built-in NUI. The NUI bridge lives in
-- client/ui.lua and subscribes to the local session events below.

local session
local pendingGive
local nextGiveRequestId = 0

RegisterNetEvent('qbinventory:client:sessionOpened', function(payload)
    if type(payload) ~= 'table' or type(payload.token) ~= 'string' then return end
    session = payload
    -- Presentation events deliberately use a separate namespace. Triggering the
    -- network handler's own event name would recursively invoke this handler.
    TriggerEvent('qbinventory:ui:sessionOpened', {
        token = payload.token, primary = payload.primary, secondary = payload.secondary, expires = payload.expires,
    })
end)

RegisterNetEvent('qbinventory:client:sessionPatched', function(token, patch)
    if not session or token ~= session.token or type(patch) ~= 'table' then return end
    -- Authoritative server snapshots replace the corresponding local panel.
    if patch.inventory and patch.key == session.primary.key then session.primary = patch.inventory end
    if patch.inventory and session.secondary and patch.key == session.secondary.key then session.secondary = patch.inventory end
    TriggerEvent('qbinventory:ui:sessionPatched', { token = token, patch = patch })
end)

RegisterNetEvent('qbinventory:client:sessionClosed', function(token, reason)
    if not session or token ~= session.token then return end
    local closed = session
    session = nil
    pendingGive = nil
    TriggerEvent('qbinventory:ui:sessionClosed', { token = token, reason = reason })
end)

RegisterNetEvent('qbinventory:client:rejected', function(reason)
    TriggerEvent('qbinventory:ui:rejected', { reason = reason })
end)

---Open an inventory through the server. `data` is intent only; the server
---resolves/access-checks the inventory before it emits a session snapshot.
function openInventory(invType, data)
    TriggerServerEvent('qbinventory:server:open', invType, data)
end

function closeInventory()
    if session then TriggerServerEvent('qbinventory:server:close', session.token) end
end

---Submit a slot transfer from the active session. The server supplies and
---checks both revisions, so stale UI state cannot overwrite another viewer.
function submitIntent(intent)
    if not session or type(intent) ~= 'table' then return false, 'no active session' end
    -- The built-in UI sends an envelope; keep the direct action shape accepted
    -- for third-party client renderers too.
    if intent.sessionId and intent.sessionId ~= session.token then return false, 'stale session' end
    if intent.token and intent.token ~= session.token then return false, 'stale session' end
    local action, payload = intent.intent or intent.action or 'transfer', intent.payload or intent
    if action == 'close' then closeInventory(); return true end
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
            id = nextGiveRequestId, slot = slot, amount = amount,
            primaryRevision = session.primary.revision,
            secondaryRevision = session.secondary and session.secondary.revision,
        }
        TriggerEvent('qbinventory:client:requestGiveTarget', pendingGive.id)
        return true
    end
    if action == 'use' or action == 'drop' or action == 'buy' then
        TriggerServerEvent('qbinventory:server:intent', {
            token = session.token,
            action = action,
            payload = payload,
            primaryRevision = session.primary and session.primary.revision,
            secondaryRevision = session.secondary and session.secondary.revision,
        })
        return true
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
    TriggerServerEvent('qbinventory:server:transfer', {
        token = session.token, fromInventory = from, toInventory = to,
        fromSlot = payload.fromSlot, toSlot = payload.toSlot, amount = payload.amount,
        fromRevision = fromView and fromView.revision, toRevision = toView and toView.revision,
    })
    return true
end

-- Recipient ids are deliberately resolved only between local client modules.
-- The browser never receives a nearby-player list, a name, a ped, or a server
-- id; it can only request the give action for a selected own-inventory slot.
AddEventHandler('qbinventory:client:giveTargetResolved', function(result)
    if type(result) ~= 'table' or not pendingGive or result.requestId ~= pendingGive.id then return end
    local request = pendingGive
    pendingGive = nil
    if result.cancelled or type(result.target) ~= 'number' then
        if result.reason and result.reason ~= 'cancelled' then TriggerEvent('qbinventory:ui:rejected', { reason = result.reason }) end
        return
    end
    if not session then return end
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

function getCurrentSession()
    return session and QbInventory.copy(session) or nil
end

function hasItem(names, amount)
    local data = exports.qbcore:getPlayerData() or {}
    local items = data.items or {}
    local function count(name)
        local n = 0
        for _, item in pairs(items) do if item.name == name then n = n + (item.amount or 0) end end
        return n
    end
    if type(names) == 'table' then
        for _, name in ipairs(names) do if count(name) < (amount or 1) then return false end end
        return true
    end
    return count(names) >= (amount or 1)
end

exports('openInventory', openInventory)
exports('closeInventory', closeInventory)
exports('submitIntent', submitIntent)
exports('getCurrentSession', getCurrentSession)
exports('HasItem', hasItem)

for _, identity in ipairs({ 'qb-inventory', 'ox_inventory' }) do
    AddEventHandler(('__cfx_export_%s_HasItem'):format(identity), function(setCB) setCB(hasItem) end)
    AddEventHandler(('__cfx_export_%s_openInventory'):format(identity), function(setCB) setCB(openInventory) end)
    AddEventHandler(('__cfx_export_%s_closeInventory'):format(identity), function(setCB) setCB(closeInventory) end)
end

AddEventHandler('onClientResourceStop', function(name)
    if name == GetCurrentResourceName() then
        pendingGive = nil
        closeInventory()
    end
end)
