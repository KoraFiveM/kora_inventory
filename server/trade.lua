-- Two-sided confirmed player trade: the server wiring.
--
-- server/trade_state.lua holds the rules (state machine, re-validation,
-- planning, rollback). This file connects it to the real authority:
-- kora_core-owned PlayerData.items, server.lua's locks and its single item
-- write (playerSetPath -> kora_core setPath), the session lease and the hooks.
--
-- Transport (see docs/security.md, "Player trades"):
--   * kora_inventory:server:tradeRequest (target)        net event
--   * kora_inventory:server:tradeRespond (tradeId, bool) net event
--   * kora_inventory:server:tradeCancel  (tradeId)       net event
--   * intent action 'trade' { op, id, slot?, amount?, cash?, revision? }
--     through the ordinary session/intent pipeline (validSession: token,
--     lease, cuffed/downed). Offer changes also check the primary revision.
-- None of them carries an item record, name, label, metadata or price; the
-- trade id is server generated and membership/phase are checked against
-- server state on every message.

local inventory = KoraInventory
local internal = inventory.internal
local TradeState = inventory.TradeState
local config = Config.kora_inventory

local trade = {}
inventory.trade = trade

local OPS = {
    offer = true,
    unoffer = true,
    cash = true,
    ready = true,
    unready = true,
    confirm = true,
    cancel = true,
}

local function settingsRaw()
    return Config.kora_inventory.trade
end

local function settings()
    return TradeState.settings(settingsRaw())
end

local function text(key, fallback, vars)
    local value = inventory.text(key, fallback, vars)
    if vars then
        value = tostring(value):gsub('%%{(%w+)}', function(name)
            return tostring(vars[name] or '')
        end)
    end
    return value
end

local function notify(src, key, fallback, kind, vars)
    if not Kora.notify then
        return
    end
    Kora.notify.send(src, {
        title = text('inventory.trade_title', 'Trade'),
        message = text(key, fallback, vars),
        type = kind or 'info',
    })
end

local function playerKey(src)
    return internal.playerKey(src)
end

local function coordsOf(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then
        return nil
    end
    return GetEntityCoords(ped)
end

local function cashAccount()
    local policy = internal.cashPolicy and internal.cashPolicy() or nil
    if policy then
        return policy.account
    end
    local cash = type(config.cash) == 'table' and config.cash or {}
    return type(cash.account) == 'string' and cash.account ~= '' and cash.account:lower() or 'cash'
end

---'item' when the cash account is a physical item stack, else 'ledger'.
local function cashMode()
    local policy = internal.cashPolicy and internal.cashPolicy() or nil
    if policy then
        local ok, physical = pcall(function()
            return exports.kora_core:isPhysicalCash(policy.account)
        end)
        if ok and physical == true then
            return 'item', policy
        end
    end
    return 'ledger'
end

local function playerItems(src)
    local inv = internal.getInventory(playerKey(src))
    return inv and inv.items or {}
end

local function cashBalance(src)
    local mode, policy = cashMode()
    if mode == 'item' then
        local total = 0
        for _, item in pairs(playerItems(src)) do
            if type(item) == 'table' and type(item.name) == 'string' and item.name:lower() == policy.item then
                total = total + (tonumber(item.amount) or 0)
            end
        end
        return total
    end
    local ok, balance = pcall(function()
        return exports.kora_core:getMoney(src, cashAccount())
    end)
    return ok and tonumber(balance) or nil
end

-- Display fields copied from the inventory view for an offered slot. The
-- partner never receives raw `info`; only the curated displayMeta rows the
-- inventory already shows for that item.
local DISPLAY_FIELDS = { 'name', 'label', 'image', 'imageUrl', 'imageOverride', 'weight', 'description', 'displayMeta', 'unique', 'type' }

local function decorate(src, offers)
    local view = internal.view(playerKey(src))
    local items = view and view.items or {}
    local out = {}
    for index, offer in ipairs(offers) do
        local item = items[offer.slot]
        local entry = { slot = offer.slot, amount = offer.amount, name = offer.name }
        if type(item) == 'table' and item.name == offer.name then
            for _, field in ipairs(DISPLAY_FIELDS) do
                entry[field] = internal.copy(item[field])
            end
            entry.amount = offer.amount
        end
        out[index] = entry
    end
    return out
end

local machine

local function viewFor(current, src)
    local view = machine.view(current, src)
    if not view then
        return nil
    end
    local partner = machine.other(current, src)
    view.you.offers = decorate(src, view.you.offers)
    view.them.offers = decorate(partner, view.them.offers)
    if view.allowCash then
        view.you.balance = cashBalance(src)
    end
    return view
end

local function publish(current)
    for _, src in ipairs({ current.a, current.b }) do
        local view = viewFor(current, src)
        if view then
            TriggerClientEvent('kora_inventory:client:tradeState', src, view)
        end
    end
end

local REASON_KEYS = {
    declined = { 'inventory.trade_declined', 'The trade request was declined.' },
    timeout = { 'inventory.trade_timeout', 'The trade request was not answered.' },
    completed = { 'inventory.trade_completed', 'Trade completed.' },
}

local function ended(current, reason, committed)
    for _, src in ipairs({ current.a, current.b }) do
        TriggerClientEvent('kora_inventory:client:tradeEnded', src, current.id, tostring(reason or 'cancelled'), committed)
        local known = REASON_KEYS[reason]
        if committed then
            notify(src, 'inventory.trade_completed', 'Trade completed.', 'success')
        elseif known then
            notify(src, known[1], known[2], reason == 'declined' and 'warning' or 'info')
        else
            notify(src, 'inventory.trade_cancelled', 'Trade cancelled: %{reason}.', 'warning', { reason = tostring(reason or 'cancelled') })
        end
    end
end

local function invited(current, cfg)
    TriggerClientEvent('kora_inventory:client:tradeInvite', current.b, current.id, cfg.requestTimeout * 1000)
    notify(current.a, 'inventory.trade_request_sent', 'Trade request sent.', 'info')
end

-- Both players get a one-panel session of their own inventory; the trade panel
-- is rendered beside it. Closing (or replacing) that session cancels the trade.
local function opened(current)
    current.tokens = {}
    for _, src in ipairs({ current.a, current.b }) do
        local ok, payload = internal.openSelf(src)
        if not ok or type(payload) ~= 'table' then
            for _, other in ipairs({ current.a, current.b }) do
                local token = current.tokens[other]
                local session = internal.sessionOf(other)
                if token and session and session.token == token then
                    internal.close(other, 'trade cancelled')
                end
            end
            return false, 'inventory could not be opened'
        end
        current.tokens[src] = payload.token
    end
    return true
end

local function hookLegs(current, legs)
    local handles = {}
    for _, src in ipairs({ current.a, current.b }) do
        local target = machine.other(current, src)
        for _, leg in ipairs(legs[src]) do
            local ok, err, handle = internal.runHooks('swapItems', src, {
                action = 'give',
                fromInventory = src,
                fromType = 'player',
                fromSlot = leg.slot,
                toInventory = target,
                toType = 'player',
                count = leg.amount,
                itemName = leg.name,
                fromKey = playerKey(src),
                toKey = playerKey(target),
                trade = current.id,
            })
            if not ok then
                for _, earlier in ipairs(handles) do
                    internal.finishHooks(earlier, false)
                end
                return false, err or 'trade was refused'
            end
            handles[#handles + 1] = handle
        end
    end
    return true, nil, handles
end

local function finishLegs(handles, success)
    for _, handle in ipairs(handles or {}) do
        internal.finishHooks(handle, success)
    end
end

local function legSummary(legs)
    local out = {}
    for index, leg in ipairs(legs or {}) do
        out[index] = { name = leg.name, amount = leg.amount, slot = leg.slot, metadata = internal.copy(leg.info) }
    end
    return out
end

local function committed(current, receipts)
    local a, b = current.a, current.b
    for _, src in ipairs({ a, b }) do
        internal.bump(playerKey(src))
    end
    for _, src in ipairs({ a, b }) do
        internal.broadcast(playerKey(src))
    end
    local legs, cash = receipts.legs, receipts.cash
    for _, src in ipairs({ a, b }) do
        local partner = machine.other(current, src)
        internal.recordAudit('trade', src, {
            trade = current.id,
            with = partner,
            gave = legSummary(legs[src]),
            received = legSummary(legs[partner]),
            cashGiven = cash[src] or 0,
            cashReceived = cash[partner] or 0,
            cashMode = (cashMode()),
        })
        for _, leg in ipairs(legs[src]) do
            internal.showItemBox(src, leg.name, leg.amount, 'remove', { name = leg.name, amount = leg.amount, info = leg.info })
            internal.showItemBox(partner, leg.name, leg.amount, 'add', { name = leg.name, amount = leg.amount, info = leg.info })
            TriggerEvent('kora_inventory:server:itemsMoved', src, {
                action = 'trade',
                trade = current.id,
                fromInventory = playerKey(src),
                toInventory = playerKey(partner),
                fromType = 'player',
                toType = 'player',
                fromSlot = leg.slot,
                itemName = leg.name,
                count = leg.amount,
                metadata = internal.copy(leg.info),
            })
        end
    end
    TriggerEvent('kora_inventory:server:tradeCompleted', current.id, a, b, {
        [a] = { gave = legSummary(legs[a]), cash = cash[a] or 0 },
        [b] = { gave = legSummary(legs[b]), cash = cash[b] or 0 },
    })
end

machine = TradeState.new({
    now = GetGameTimer,
    random = function()
        return math.random(100000, 999999)
    end,
    settings = settingsRaw,
    playerSlots = function()
        return config.playerSlots
    end,
    capacity = function()
        return config.playerSlots, config.playerMaxWeight
    end,
    online = function(src)
        return exports.kora_core:getPlayerData(src) ~= nil and coordsOf(src) ~= nil
    end,
    blocked = function(src)
        -- The same guards every inventory action uses (blockWhenDowned /
        -- blockWhenCuffed decide whether they apply).
        if internal.isDowned(src) then
            return 'player is downed'
        end
        if internal.isCuffed(src) then
            return 'player is cuffed'
        end
        return nil
    end,
    sameBucket = function(a, b)
        return GetPlayerRoutingBucket(a) == GetPlayerRoutingBucket(b)
    end,
    distance = function(a, b)
        local from, to = coordsOf(a), coordsOf(b)
        if not from or not to then
            return nil
        end
        local dx, dy, dz = from.x - to.x, from.y - to.y, from.z - to.z
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end,
    items = playerItems,
    revision = function(src)
        return internal.getRevision(playerKey(src))
    end,
    slotBusy = function(src, slot)
        return internal.isSlotBusy(src, slot)
    end,
    offerable = function(_, item)
        if not internal.itemDef(item.name) then
            return false, 'unknown item'
        end
        local mode, policy = cashMode()
        if mode == 'item' and type(item.name) == 'string' and item.name:lower() == policy.item then
            return false, 'use the cash field to trade cash'
        end
        return true
    end,
    cashMode = function()
        return (cashMode())
    end,
    cashItem = function()
        local _, policy = cashMode()
        return policy and policy.item or nil
    end,
    cashBalance = cashBalance,
    draftAdd = function(draft, name, amount, info)
        return internal.addSecondary(draft, name, amount, nil, info)
    end,
    lock = function(a, b, fn)
        return internal.lock({ playerKey(a), playerKey(b) }, fn)
    end,
    writeSlot = function(src, slot, value)
        return internal.playerSetPath(src, { 'items', slot }, value)
    end,
    transferCash = function(from, to, amount)
        -- Exactly what both players confirmed moves: the trade is a consented
        -- swap, so the transaction tax is not applied (physical cash, which
        -- moves as items, is never taxed either).
        return exports.kora_core:transferMoney(from, to, cashAccount(), amount, 'kora_inventory-trade', true)
    end,
    beforeCommit = hookLegs,
    afterCommit = finishLegs,
    committed = committed,
    publish = publish,
    ended = ended,
    invited = invited,
    opened = opened,
    log = function(level, message, data)
        local fn = Kora.logging and Kora.logging[level] or nil
        if fn then
            fn('inventory.trade', message, data)
        end
    end,
})
trade.machine = machine

-- ----------------------------------------------------------------------
-- Intents (inside the inventory session)
-- ----------------------------------------------------------------------

local function wholeOrNil(value)
    if value == nil then
        return true
    end
    return TradeState.wholeNumber(value, 0, TradeState.MAX_CASH)
end

---The 'trade' intent. Called by server.lua's handleIntent with the raw
---envelope; returns (ok, result) like every other intent.
function trade.intent(src, request)
    local payload = request.payload
    if type(payload) ~= 'table' or type(payload.op) ~= 'string' or not OPS[payload.op] then
        return false, 'invalid trade action'
    end
    if type(payload.id) ~= 'string' or #payload.id > 64 then
        return false, 'trade not found'
    end
    for _, field in ipairs({ 'slot', 'amount', 'cash', 'revision' }) do
        if not wholeOrNil(payload[field]) then
            return false, 'invalid trade action'
        end
    end
    local current = machine.get(payload.id)
    if not current or (current.a ~= src and current.b ~= src) then
        return false, 'trade not found'
    end
    local session = internal.sessionOf(src)
    if not session or not current.tokens or current.tokens[src] ~= request.token or session.token ~= request.token then
        return false, 'invalid session'
    end
    -- The lease, cuffed/downed and expiry checks every intent runs. Offer
    -- changes reference slots, so they also require the inventory revision the
    -- browser rendered; Ready/Confirm carry the trade revision instead.
    local referencesSlots = payload.op == 'offer' or payload.op == 'unoffer'
    local expected = referencesSlots and request.primaryRevision or nil
    if referencesSlots and expected == nil then
        return false, 'stale inventory'
    end
    local valid, _, reason = internal.validSession(src, request.token, session.primary, session.primary, expected, expected)
    if not valid then
        return false, reason or 'stale inventory'
    end
    local op = payload.op
    if op == 'offer' then
        return machine.offer(src, current.id, payload.slot, payload.amount)
    elseif op == 'unoffer' then
        return machine.unoffer(src, current.id, payload.slot)
    elseif op == 'cash' then
        return machine.setCash(src, current.id, payload.cash)
    elseif op == 'ready' then
        return machine.ready(src, current.id, payload.revision)
    elseif op == 'unready' then
        return machine.unready(src, current.id)
    elseif op == 'confirm' then
        return machine.confirm(src, current.id, payload.revision)
    elseif op == 'cancel' then
        return machine.cancel(src, current.id, 'cancelled by a player')
    end
    return false, 'invalid trade action'
end

-- ----------------------------------------------------------------------
-- Net events (outside any session: request, answer, cancel)
-- ----------------------------------------------------------------------

local lastNotice = {}
local function refuse(src, reason)
    local now = GetGameTimer()
    if lastNotice[src] and now - lastNotice[src] < 1000 then
        return
    end
    lastNotice[src] = now
    notify(src, 'inventory.trade_failed', 'Trade: %{reason}.', 'error', { reason = tostring(reason) })
end

RegisterNetEvent('kora_inventory:server:tradeRequest', function(target)
    if GetInvokingResource() then
        return
    end
    local src = source
    if not settings().enabled then
        return refuse(src, 'trading is disabled')
    end
    if not TradeState.wholeNumber(target, 1, 65535) then
        return refuse(src, 'invalid trade partner')
    end
    local created, err = machine.request(src, target)
    if not created then
        refuse(src, err)
    end
end)

RegisterNetEvent('kora_inventory:server:tradeRespond', function(id, accept)
    if GetInvokingResource() then
        return
    end
    local src = source
    if type(id) ~= 'string' or #id > 64 or type(accept) ~= 'boolean' then
        return
    end
    local ok, err = machine.respond(src, id, accept)
    if not ok then
        refuse(src, err)
    end
end)

RegisterNetEvent('kora_inventory:server:tradeCancel', function(id)
    if GetInvokingResource() then
        return
    end
    if type(id) ~= 'string' or #id > 64 then
        return
    end
    machine.cancel(source, id, 'cancelled by a player')
end)

-- Closing or replacing the trade's own inventory session ends the trade. A
-- session that is not the one opened for the trade is ignored.
AddEventHandler('kora_inventory:server:sessionClosed', function(src, session, reason)
    local current = machine.of(src)
    if not current or not current.tokens or type(session) ~= 'table' then
        return
    end
    if current.tokens[src] == session.token then
        machine.cancelFor(src, reason == 'cuffed' and 'player is cuffed' or reason == 'downed' and 'player is downed' or 'inventory closed')
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    machine.cancelFor(src, 'player left')
    machine.forget(src)
    lastNotice[src] = nil
end)

-- The monitor: request timeouts, the maximum duration, distance/bucket/
-- presence and inventory changes. Idle when no trade exists.
CreateThread(function()
    while true do
        Wait(machine.count() > 0 and 500 or 1500)
        local ok, err = pcall(machine.tick)
        if not ok then
            Kora.logging.error('inventory.trade_monitor_failed', 'Trade monitor failed', { error = tostring(err) })
        end
    end
end)

function trade.cancelFor(src, reason)
    return machine.cancelFor(src, reason)
end

function trade.of(src)
    local current = machine.of(src)
    return current and viewFor(current, src) or nil
end
