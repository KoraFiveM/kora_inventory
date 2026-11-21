-- Player trade, client side. Presentation and intent only:
--   * starts a request (inventory Trade button, /trade, the unbound keybind)
--     by resolving the nearby player locally through client/give_target.lua
--     and sending ONLY that server id; the server re-checks range, bucket and
--     state before anything exists;
--   * shows the accept/decline prompt and sends the answer (trade id + bool);
--   * relays the server's trade view to the NUI through client/ui.lua.
-- Offers, Ready, Confirm and Cancel inside the window are ordinary 'trade'
-- intents sent by the page through client/ui.lua -> client.lua's submitIntent.
-- The browser never learns who the partner is; it sees offers, not identities.

local function localeText(key, fallback, vars)
    local text = KoraInventory and KoraInventory.text
    return text and text(key, fallback, vars) or fallback
end

local function settings()
    local raw = (Config.kora_inventory or {}).trade
    return type(raw) == 'table' and raw or {}
end

local function enabled()
    return settings().enabled ~= false
end

local function notify(message, kind)
    Kora.notify.send({ title = localeText('inventory.trade_title', 'Trade'), message = message, type = kind or 'info' })
end

local function send(action, data)
    local ui = KoraInventory and KoraInventory.ui
    if ui and ui.send then
        ui.send(action, data)
    end
end

local tradeClient = {}
KoraInventory = KoraInventory or {}
KoraInventory.tradeClient = tradeClient

local nextRequest = 0
local pendingTarget
local activeId
local prompt

---Start a trade request with the nearest player (or the one picked with
---kora_target when several are close). Returns false with a reason when it
---cannot start.
function tradeClient.request()
    if not enabled() then
        notify(localeText('inventory.trade_disabled', 'Trading is disabled.'), 'error')
        return false, 'trading is disabled'
    end
    if activeId then
        notify(localeText('inventory.trade_already', 'You are already trading.'), 'error')
        return false, 'already trading'
    end
    if KoraInventory.isDowned and KoraInventory.isDowned() then
        KoraInventory.notifyDownedBlocked()
        return false, 'downed'
    end
    if KoraInventory.isCuffed and KoraInventory.isCuffed() then
        KoraInventory.notifyCuffedBlocked()
        return false, 'cuffed'
    end
    local resolver = KoraInventory.giveTarget
    if not resolver or not resolver.request then
        return false, 'targeting unavailable'
    end
    nextRequest = nextRequest + 1
    pendingTarget = ('trade:%d'):format(nextRequest)
    resolver.request(pendingTarget, localeText('inventory.trade_with_player', 'Trade with this player'))
    return true
end

-- give_target answers every resolution on one local event; only ours (a
-- 'trade:N' id) is handled here. The server id goes to the server and nowhere
-- else.
AddEventHandler('kora_inventory:client:giveTargetResolved', function(result)
    if type(result) ~= 'table' or not pendingTarget or result.requestId ~= pendingTarget then
        return
    end
    pendingTarget = nil
    if result.cancelled or type(result.target) ~= 'number' then
        if result.reason == 'no nearby player' then
            notify(localeText('inventory.trade_no_player', 'Nobody is close enough to trade with.'), 'error')
        elseif result.reason and result.reason ~= 'cancelled' and result.reason ~= 'replaced' then
            notify(tostring(result.reason), 'error')
        end
        return
    end
    TriggerServerEvent('kora_inventory:server:tradeRequest', result.target)
end)

-- The invite. kora_lib's alert takes focus while it is open; an answer given
-- after the request was withdrawn is refused by the server, never applied.
RegisterNetEvent('kora_inventory:client:tradeInvite', function(id, timeoutMs)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    if type(id) ~= 'string' or prompt then
        return
    end
    prompt = { id = id }
    local seconds = math.max(1, math.floor((tonumber(timeoutMs) or 20000) / 1000))
    CreateThread(function()
        local current = prompt
        local ok, result = pcall(Kora.nui.openAlert, {
            title = localeText('inventory.trade_invite_title', 'Trade request'),
            message = localeText('inventory.trade_invite_message', 'A nearby player wants to trade with you. You have %{seconds} seconds to answer.', { seconds = seconds }),
            confirmLabel = localeText('inventory.trade_accept', 'Trade'),
            cancelLabel = localeText('inventory.trade_decline', 'Decline'),
        })
        if prompt ~= current then
            return
        end
        prompt = nil
        if current.withdrawn then
            return
        end
        local accepted = ok and type(result) == 'table' and result.confirmed == true
        TriggerServerEvent('kora_inventory:server:tradeRespond', current.id, accepted)
    end)
end)

-- Authoritative trade view from the server, for the open trade window.
RegisterNetEvent('kora_inventory:client:tradeState', function(view)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    if type(view) ~= 'table' or type(view.id) ~= 'string' then
        return
    end
    activeId = view.id
    send('kora_inventory:nui:trade', view)
end)

RegisterNetEvent('kora_inventory:client:tradeEnded', function(id, reason, completed)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    if type(id) ~= 'string' then
        return
    end
    if prompt and prompt.id == id then
        -- The alert cannot be dismissed from here; mark it so its answer is
        -- not sent. The server would refuse it anyway.
        prompt.withdrawn = true
    end
    if activeId == id then
        activeId = nil
    end
    send('kora_inventory:nui:tradeEnded', { id = id, reason = tostring(reason or 'cancelled'), completed = completed == true })
end)

-- Cancel without an open window (e.g. a pending request the requester no
-- longer wants). Carries the trade id only.
function tradeClient.cancel()
    if activeId then
        TriggerServerEvent('kora_inventory:server:tradeCancel', activeId)
    end
end

-- The page's Trade button (client.lua forwards the 'tradeRequest' intent here).
AddEventHandler('kora_inventory:client:startTrade', function()
    tradeClient.request()
end)

do
    local command = settings().command
    if type(command) == 'string' and command:match('^[%w_%-]+$') then
        RegisterCommand(command, function()
            tradeClient.request()
        end, false)
    end
    Kora.keybind.add({
        name = 'kora_inventory:trade',
        description = localeText('inventory.keybind_trade', 'Request a trade with the nearest player'),
        defaultKey = '',
        onPressed = function()
            tradeClient.request()
        end,
    })
end

AddEventHandler('onClientResourceStop', function(name)
    if name == GetCurrentResourceName() then
        pendingTarget, activeId = nil, nil
    end
end)

exports('requestTrade', tradeClient.request)
