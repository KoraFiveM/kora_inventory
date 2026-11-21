-- /invaudit overlay bridge. Presentation only.
--
-- This is NOT an inventory session: it has no token, lease or inventory. The
-- server opens it with `kora_inventory:client:auditOpen` (after its own ACE
-- check) and every page of data is fetched through the server callback
-- `kora_inventory:server:auditQuery`, which re-checks the ACE on each request.
-- The overlay can only READ; there is no callback here that changes anything.
-- NUI focus handling is shared with client/ui.lua (KoraInventory.ui.focus).

KoraInventory = KoraInventory or {}

local open = false

local function ui()
    return KoraInventory.ui
end

local function closeOverlay()
    if not open then
        return
    end
    open = false
    local bridge = ui()
    if bridge then
        bridge.send('kora_inventory:nui:auditClose', {})
        bridge.focus(false)
    end
end

-- Only the server can send this; the overlay it opens is empty until the
-- server's callback answers, so a spoofed local trigger gains nothing.
RegisterNetEvent('kora_inventory:client:auditOpen', function(initial)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    local bridge = ui()
    if not bridge or open then
        return
    end
    if not bridge.focus(true) then
        -- An inventory session holds the focus; ask the admin to close it first.
        Kora.notify.send({
            title = KoraInventory.text('inventory.title', 'Inventory'),
            message = KoraInventory.text('inventory.audit_close_first', 'Close your inventory first.'),
            type = 'error',
        })
        return
    end
    open = true
    -- Theme tokens are pushed by client/ui.lua on resource start and session
    -- open; refresh so the overlay never renders with stale ones.
    pcall(KoraTheme.refresh)
    local filter = {}
    if type(initial) == 'table' then
        for _, field in ipairs({ 'player', 'item', 'resource', 'range' }) do
            if type(initial[field]) == 'string' then
                filter[field] = initial[field]:sub(1, 96)
            end
        end
    end
    bridge.send('kora_inventory:nui:auditOpen', { filter = filter })
end)

RegisterNUICallback('kora_inventory:audit:query', function(data, cb)
    if not open then
        cb({ error = 'closed' })
        return
    end
    local filter = {}
    if type(data) == 'table' then
        for _, field in ipairs({ 'player', 'item', 'resource', 'range' }) do
            if type(data[field]) == 'string' then
                filter[field] = data[field]:sub(1, 96)
            end
        end
        filter.page = math.floor(tonumber(data.page) or 0)
    end
    local called, result = pcall(Kora.callback.trigger, 'kora_inventory:server:auditQuery', filter)
    if not called or type(result) ~= 'table' then
        cb({ error = 'request failed' })
        return
    end
    cb(result)
end)

RegisterNUICallback('kora_inventory:audit:close', function(_, cb)
    closeOverlay()
    cb({ ok = true })
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        closeOverlay()
    end
end)
