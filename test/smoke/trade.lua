-- Two-player trade. Part 1 drives server/trade_state.lua (pure, no natives)
-- against an in-memory world: request/accept/decline/timeout, offer
-- validation, un-ready on any change, the two-stage confirm gate, commit
-- re-validation and rollback, cancellation, one trade per player and the
-- request cooldown. Every failed commit must leave both inventories (and cash)
-- exactly as they were, and every commit must conserve each item
-- name+metadata and the cash total across the two players.
-- Part 2 loads server.lua + server/trade.lua with stubbed exports and runs a
-- real trade through the intent pipeline, the session lease and the actual
-- kora_core write path.
local H = dofile('test/harness.lua')

KoraInventory = {}
local TradeState = dofile('server/trade_state.lua')
local copy, same = TradeState.copy, TradeState.same

-- ---------------------------------------------------------------------------
-- Part 1: pure state machine
-- ---------------------------------------------------------------------------

local DEFS = {
    bread = { weight = 100 },
    water = { weight = 500 },
    pistol = { weight = 1000, unique = true },
    gold = { weight = 5000 },
    cash = { weight = 0 },
    rock = { weight = 10000 },
}

local clock = 0
local world
local settingsTable
local hooks

local function item(name, amount, slot, info)
    return { name = name, amount = amount, slot = slot, info = info or {}, unique = DEFS[name].unique or false }
end

local function resetWorld()
    clock = 100000
    settingsTable = { enabled = true, slots = 4, allowCash = true, distance = 3.0, requestTimeout = 20, confirmDelay = 3, maxDuration = 300, requestCooldown = 10 }
    hooks = {
        cashMode = 'ledger', lockBusy = false, failWriteAt = nil, writes = 0, transferFails = false,
        beforeCommitRefuse = false, published = 0, ended = {}, opened = 0, invited = 0, committed = 0, busy = {},
    }
    world = {}
    for src = 1, 3 do
        world[src] = { online = true, bucket = 0, pos = { x = src * 0.5, y = 0, z = 0 }, downed = false, cuffed = false, items = {}, rev = 0, cash = 1000 }
    end
end

local function bumpRev(src)
    world[src].rev = world[src].rev + 1
end

local function itemWeight(entry)
    return (DEFS[entry.name] and DEFS[entry.name].weight or 0) * entry.amount
end

local function draftAdd(draft, name, amount, info)
    local def = DEFS[name]
    if not def then return false, 'unknown item' end
    local total = 0
    for _, current in pairs(draft.items) do total = total + itemWeight(current) end
    if total + def.weight * amount > draft.maxWeight then return false, 'over weight' end
    if def.unique then
        for _ = 1, amount do
            local free
            for slot = 1, draft.slots do if not draft.items[slot] then free = slot break end end
            if not free then return false, 'no free slot' end
            draft.items[free] = item(name, 1, free, copy(info))
        end
        return true
    end
    for slot = 1, draft.slots do
        local current = draft.items[slot]
        if current and current.name == name and same(current.info, info) then
            current.amount = current.amount + amount
            return true, slot
        end
    end
    for slot = 1, draft.slots do
        if not draft.items[slot] then
            draft.items[slot] = item(name, amount, slot, copy(info))
            return true, slot
        end
    end
    return false, 'no free slot'
end

local function cashItemBalance(src)
    local total = 0
    for _, entry in pairs(world[src].items) do
        if entry.name == 'cash' then total = total + entry.amount end
    end
    return total
end

local deps = {
    now = function() return clock end,
    settings = function() return settingsTable end,
    playerSlots = function() return 5 end,
    capacity = function() return 5, 30000 end,
    online = function(src) return world[src] and world[src].online end,
    blocked = function(src)
        if world[src].downed then return 'player is downed' end
        if world[src].cuffed then return 'player is cuffed' end
    end,
    sameBucket = function(a, b) return world[a].bucket == world[b].bucket end,
    distance = function(a, b)
        local p, q = world[a].pos, world[b].pos
        return math.sqrt((p.x - q.x) ^ 2 + (p.y - q.y) ^ 2 + (p.z - q.z) ^ 2)
    end,
    items = function(src) return world[src].items end,
    revision = function(src) return world[src].rev end,
    slotBusy = function(src, slot) return hooks.busy[src .. ':' .. slot] == true end,
    offerable = function(_, entry)
        if hooks.cashMode == 'item' and entry.name == 'cash' then return false, 'use the cash field to trade cash' end
        return true
    end,
    cashMode = function() return hooks.cashMode end,
    cashItem = function() return 'cash' end,
    cashBalance = function(src)
        if hooks.cashMode == 'item' then return cashItemBalance(src) end
        return world[src].cash
    end,
    draftAdd = draftAdd,
    lock = function(_, _, fn)
        if hooks.lockBusy then return false, 'inventory busy' end
        return fn()
    end,
    writeSlot = function(src, slot, value)
        hooks.writes = hooks.writes + 1
        if hooks.failWriteAt and hooks.writes == hooks.failWriteAt then
            return false, 'write refused'
        end
        world[src].items[slot] = value
        return true
    end,
    transferCash = function(from, to, amount)
        if hooks.transferFails then return false, 'player data is busy' end
        if world[from].cash < amount then return false, 'insufficient funds' end
        world[from].cash = world[from].cash - amount
        world[to].cash = world[to].cash + amount
        return true
    end,
    beforeCommit = function()
        if hooks.beforeCommitRefuse then return false, 'hook refused' end
        return true, nil, 'handle'
    end,
    afterCommit = function() end,
    committed = function() hooks.committed = hooks.committed + 1 end,
    publish = function() hooks.published = hooks.published + 1 end,
    ended = function(trade, reason, committed) hooks.ended[#hooks.ended + 1] = { id = trade.id, reason = reason, committed = committed } end,
    invited = function() hooks.invited = hooks.invited + 1 end,
    opened = function() hooks.opened = hooks.opened + 1 return true end,
    random = function() return 4242 end,
}

local machine

local function lastEnded() return hooks.ended[#hooks.ended] end

-- name|metadata -> total, plus cash, across players 1 and 2.
local function totals()
    local out = {}
    for _, src in ipairs({ 1, 2 }) do
        for _, entry in pairs(world[src].items) do
            local keys = {}
            for k in pairs(entry.info or {}) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            local parts = {}
            for _, k in ipairs(keys) do parts[#parts + 1] = k .. '=' .. tostring(entry.info[k]) end
            local key = entry.name .. '|' .. table.concat(parts, ',')
            out[key] = (out[key] or 0) + entry.amount
        end
    end
    out['$ledger'] = world[1].cash + world[2].cash
    return out
end

local function sameTotals(before, after, label)
    H.ok(same(before, after), label .. ': item and cash totals are conserved')
end

local function snapshotWorld()
    return { copy(world[1].items), copy(world[2].items), world[1].cash, world[2].cash }
end
local function untouched(snap, label)
    H.ok(same(world[1].items, snap[1]), label .. ': player 1 items untouched')
    H.ok(same(world[2].items, snap[2]), label .. ': player 2 items untouched')
    H.equal(world[1].cash, snap[3], label .. ': player 1 cash untouched')
    H.equal(world[2].cash, snap[4], label .. ': player 2 cash untouched')
end

local function fresh()
    resetWorld()
    machine = TradeState.new(deps)
end

local function openTrade()
    local trade = assert(machine.request(1, 2))
    assert(machine.respond(2, trade.id, true))
    return trade
end

local function readyBoth(trade)
    H.ok(machine.ready(1, trade.id, trade.revision), 'player 1 ready')
    H.ok(machine.ready(2, trade.id, trade.revision), 'player 2 ready')
    H.equal(trade.phase, 'locked', 'both ready locks the trade')
end

local function confirmBoth(trade)
    clock = clock + 3000
    H.ok(machine.confirm(1, trade.id, trade.revision), 'player 1 confirms')
    return machine.confirm(2, trade.id, trade.revision)
end

-- Standard setup: 1 offers 3 bread (of 5) and a serialled pistol, 2 offers gold and 250 cash.
local function standard()
    fresh()
    world[1].items[1] = item('bread', 5, 1)
    world[1].items[2] = item('pistol', 1, 2, { serial = 'SER-1', durability = 87 })
    world[2].items[1] = item('gold', 2, 1, { purity = 24 })
    local trade = openTrade()
    H.ok(machine.offer(1, trade.id, 1, 3), 'offer 3 bread')
    H.ok(machine.offer(1, trade.id, 2, 1), 'offer pistol')
    H.ok(machine.offer(2, trade.id, 1, 2), 'offer gold')
    H.ok(machine.setCash(2, trade.id, 250), 'offer cash')
    return trade
end

-- ---- settings ----------------------------------------------------------
do
    local s = TradeState.settings(nil)
    H.equal(s.slots, 8, 'default offer slots')
    H.equal(s.requestCooldown, 10, 'default cooldown')
    s = TradeState.settings({ slots = 999, distance = -1, confirmDelay = 2.7, enabled = false })
    H.equal(s.slots, TradeState.MAX_SLOTS, 'slots clamped')
    H.equal(s.distance, 0.5, 'distance clamped')
    H.equal(s.confirmDelay, 2, 'confirm delay floored')
    H.equal(s.enabled, false, 'enabled honoured')
end

-- ---- requests ----------------------------------------------------------
fresh()
do
    local trade, err = machine.request(1, 1)
    H.equal(trade, nil, 'cannot trade with yourself') H.equal(err, 'invalid trade partner', 'self reason')
    H.equal(machine.request(1, 2.5), nil, 'fractional target refused')
    H.equal(machine.request(1, '2'), nil, 'string target refused')
    world[2].pos = { x = 50, y = 0, z = 0 }
    trade, err = machine.request(1, 2)
    H.equal(trade, nil, 'far target refused') H.equal(err, 'player is too far away', 'distance reason')
    world[2].pos = { x = 1, y = 0, z = 0 }
    world[2].bucket = 7
    H.equal(select(2, machine.request(1, 2)), 'different routing bucket', 'bucket refused')
    world[2].bucket = 0
    world[2].downed = true
    H.equal(select(2, machine.request(1, 2)), 'player is downed', 'downed target refused')
    world[2].downed = false
    world[2].online = false
    H.equal(select(2, machine.request(1, 2)), 'player unavailable', 'offline target refused')
    world[2].online = true

    trade = machine.request(1, 2)
    H.ok(trade, 'request created')
    H.equal(trade.phase, 'pending', 'pending until answered')
    H.equal(hooks.invited, 1, 'invite sent')
    -- One trade per player, both as requester and target.
    H.equal(select(2, machine.request(1, 3)), 'you are already trading', 'requester busy')
    H.equal(select(2, machine.request(3, 2)), 'that player is busy', 'target busy')
    H.equal(select(2, machine.request(3, 1)), 'that player is busy', 'requester counts as busy')
    -- Only the target may answer.
    H.equal(machine.respond(1, trade.id, true), false, 'requester cannot accept')
    H.equal(machine.respond(3, trade.id, true), false, 'outsider cannot accept')
    H.equal(machine.respond(2, 'nope', true), false, 'unknown id refused')
    H.equal(machine.respond(2, trade.id, 'yes'), true, 'a non-true answer is a decline')
    H.equal(lastEnded().reason, 'declined', 'declined reported')
    H.equal(machine.of(1), nil, 'requester released after decline')
    H.equal(machine.of(2), nil, 'target released after decline')
    -- Cooldown applies to the requester.
    H.equal(select(2, machine.request(1, 2)), 'wait before sending another trade request', 'cooldown enforced')
    clock = clock + 9999
    H.equal(machine.request(1, 2), nil, 'still cooling down')
    clock = clock + 2
    trade = machine.request(1, 2)
    H.ok(trade, 'request allowed after the cooldown')
    -- Timeout through the monitor.
    clock = clock + 20001
    machine.tick()
    H.equal(lastEnded().reason, 'timeout', 'unanswered request times out')
    H.equal(machine.respond(2, trade.id, true), false, 'cannot accept a timed-out request')
    -- Accept after expiry but before the monitor ran.
    clock = clock + 10001
    trade = machine.request(1, 2)
    clock = clock + 20001
    H.equal(machine.respond(2, trade.id, true), false, 'late accept refused')
    -- Accept re-validates presence.
    clock = clock + 10001
    trade = machine.request(1, 2)
    world[1].pos = { x = 40, y = 0, z = 0 }
    H.equal(machine.respond(2, trade.id, true), false, 'accept refused when the requester walked away')
    H.equal(lastEnded().reason, 'player is too far away', 'and the trade ends')
    world[1].pos = { x = 0.5, y = 0, z = 0 }
    -- Disabled.
    clock = clock + 10001
    settingsTable.enabled = false
    H.equal(select(2, machine.request(1, 2)), 'trading is disabled', 'disabled refuses requests')
    settingsTable.enabled = true
    -- A good accept.
    trade = machine.request(1, 2)
    H.ok(machine.respond(2, trade.id, true), 'accepted')
    H.equal(trade.phase, 'open', 'open after accept')
    H.equal(hooks.opened, 1, 'sessions opened once')
end

-- ---- offer validation --------------------------------------------------
fresh()
do
    world[1].items[1] = item('bread', 5, 1)
    world[1].items[2] = item('water', 2, 2)
    world[1].items[3] = item('gold', 1, 3)
    world[1].items[4] = item('rock', 1, 4)
    world[1].items[5] = item('pistol', 1, 5, { serial = 'X' })
    local trade = openTrade()
    for label, args in pairs({
        slotZero = { 0, 1 }, slotFraction = { 1.5, 1 }, slotHigh = { 6, 1 }, slotString = { '1', 1 },
        amountZero = { 1, 0 }, amountNegative = { 1, -1 }, amountFraction = { 1, 1.5 }, amountOver = { 1, 6 },
        amountString = { 1, '2' }, amountNaN = { 1, 0 / 0 }, amountHuge = { 1, math.huge },
    }) do
        H.equal(machine.offer(1, trade.id, args[1], args[2]), false, 'offer refused: ' .. label)
    end
    world[2].items[2] = nil
    H.equal(select(2, machine.offer(2, trade.id, 2, 1)), 'invalid item amount', 'empty slot refused')
    H.equal(machine.offer(3, trade.id, 1, 1), false, 'outsider cannot offer')
    hooks.busy['1:1'] = true
    H.equal(select(2, machine.offer(1, trade.id, 1, 1)), 'item is currently being used', 'busy slot refused')
    hooks.busy['1:1'] = nil
    H.ok(machine.offer(1, trade.id, 1, 2), 'offer 2 bread')
    H.ok(machine.offer(1, trade.id, 1, 4), 're-offer updates the amount')
    H.equal(#trade.sides[1].offers, 1, 'same slot is one offer')
    H.equal(trade.sides[1].offers[1].amount, 4, 'amount updated')
    H.ok(machine.offer(1, trade.id, 2), 'omitted amount offers the whole stack')
    H.equal(trade.sides[1].offers[2].amount, 2, 'whole stack')
    H.ok(machine.offer(1, trade.id, 3, 1), 'third offer')
    H.ok(machine.offer(1, trade.id, 4, 1), 'fourth offer')
    H.equal(select(2, machine.offer(1, trade.id, 5, 1)), 'no free offer slot', 'offer slots are capped (slots = 4)')
    H.ok(machine.unoffer(1, trade.id, 4), 'unoffer')
    H.equal(select(2, machine.unoffer(1, trade.id, 4)), 'item is not offered', 'unoffer twice refused')
    -- Cash.
    H.equal(select(2, machine.setCash(1, trade.id, 1001)), 'insufficient funds', 'cash above balance refused')
    H.equal(machine.setCash(1, trade.id, -5), false, 'negative cash refused')
    H.equal(machine.setCash(1, trade.id, 2.5), false, 'fractional cash refused')
    H.equal(machine.setCash(1, trade.id, '5'), false, 'string cash refused')
    settingsTable.allowCash = false
    H.equal(select(2, machine.setCash(1, trade.id, 5)), 'cash cannot be traded', 'allowCash = false refuses cash')
    settingsTable.allowCash = true
    H.ok(machine.setCash(1, trade.id, 1000), 'whole balance allowed')
end

-- ---- any change un-readies both; ready needs the seen revision ----------
fresh()
do
    world[1].items[1] = item('bread', 5, 1)
    world[2].items[1] = item('water', 3, 1)
    local trade = openTrade()
    H.equal(select(2, machine.ready(1, trade.id, trade.revision)), 'nothing has been offered', 'empty trade cannot be readied')
    H.ok(machine.offer(1, trade.id, 1, 2), 'offer')
    H.equal(select(2, machine.ready(1, trade.id, trade.revision - 1)), 'trade changed, review it again', 'stale revision refused')
    H.ok(machine.ready(1, trade.id, trade.revision), 'ready')
    H.ok(trade.sides[1].ready, 'player 1 is ready')
    H.ok(machine.offer(2, trade.id, 1, 1), 'partner changes their side')
    H.equal(trade.sides[1].ready, false, 'a change by the partner un-readies player 1')
    H.ok(machine.ready(1, trade.id, trade.revision), 'ready again')
    H.ok(machine.setCash(1, trade.id, 10), 'own cash change')
    H.equal(trade.sides[1].ready, false, 'own change un-readies too')
    -- Inventory change (revision) un-readies and unlocks.
    readyBoth(trade)
    H.equal(select(2, machine.offer(1, trade.id, 1, 1)), 'offers are locked', 'offers frozen while locked')
    H.equal(select(2, machine.setCash(1, trade.id, 5)), 'offers are locked', 'cash frozen while locked')
    local before = trade.revision
    world[2].items[2] = item('bread', 1, 2) bumpRev(2)
    machine.tick()
    H.equal(trade.phase, 'open', 'inventory change unlocks the trade')
    H.equal(trade.sides[1].ready or trade.sides[2].ready, false, 'and clears both Ready flags')
    H.ok(trade.revision > before, 'and bumps the trade revision')
    H.equal(#trade.sides[2].offers, 1, 'unchanged offers survive')
    -- An offered slot that changes underneath is dropped.
    world[1].items[1] = item('water', 5, 1) bumpRev(1)
    machine.tick()
    H.equal(#trade.sides[1].offers, 0, 'offer whose item changed is dropped')
    world[1].items[1] = item('bread', 5, 1) bumpRev(1)
    H.ok(machine.offer(1, trade.id, 1, 5), 'offer whole stack')
    world[1].items[1].amount = 4 bumpRev(1)
    machine.tick()
    H.equal(#trade.sides[1].offers, 0, 'offer dropped when the stack shrinks below the offer')
    -- Same name, different metadata: dropped.
    world[1].items[1] = item('bread', 5, 1, { quality = 100 }) bumpRev(1)
    machine.tick()
    H.ok(machine.offer(1, trade.id, 1, 1), 'offer quality bread')
    world[1].items[1] = item('bread', 5, 1, { quality = 10 }) bumpRev(1)
    machine.tick()
    H.equal(#trade.sides[1].offers, 0, 'metadata swap drops the offer')
    -- Ledger cash dropping below the offer resets it.
    H.ok(machine.setCash(1, trade.id, 500), 'cash offered')
    world[1].cash = 100
    machine.tick()
    H.equal(trade.sides[1].cash, 0, 'cash above the balance is withdrawn')
    -- Unready while locked unlocks for both.
    H.ok(machine.offer(1, trade.id, 1, 1), 'offer again')
    readyBoth(trade)
    H.ok(machine.unready(2, trade.id), 'unready')
    H.equal(trade.phase, 'open', 'unready unlocks')
    H.equal(trade.sides[1].ready, false, 'and clears the partner too')
end

-- ---- confirm gate ------------------------------------------------------
fresh()
do
    world[1].items[1] = item('bread', 5, 1)
    local trade = openTrade()
    H.ok(machine.offer(1, trade.id, 1, 1), 'offer')
    H.equal(select(2, machine.confirm(1, trade.id, trade.revision)), 'both players must be ready first', 'confirm before ready refused')
    H.equal(select(2, machine.confirm(1, trade.id, trade.revision + 5)), 'trade changed, review it again', 'confirm with an unseen revision refused')
    H.ok(machine.ready(1, trade.id, trade.revision), 'one ready')
    H.equal(select(2, machine.confirm(1, trade.id, trade.revision)), 'both players must be ready first', 'confirm with one ready refused')
    H.ok(machine.ready(2, trade.id, trade.revision), 'both ready')
    H.equal(select(2, machine.confirm(1, trade.id, trade.revision)), 'wait for the countdown to finish', 'confirm during the countdown refused')
    clock = clock + 2999
    H.equal(machine.confirm(1, trade.id, trade.revision), false, 'still counting down')
    clock = clock + 1
    H.equal(select(2, machine.confirm(1, trade.id, trade.revision - 1)), 'trade changed, review it again', 'confirm on a stale revision refused')
    H.ok(machine.confirm(1, trade.id, trade.revision), 'confirm after the countdown')
    H.equal(trade.phase, 'locked', 'one confirmation does not commit')
    H.equal(hooks.committed, 0, 'nothing committed yet')
    H.equal(machine.confirm(3, trade.id, trade.revision), false, 'outsider cannot confirm')
    H.equal(world[1].items[1].amount, 5, 'nothing moved before both confirmed')
end

-- ---- successful commit -------------------------------------------------
do
    local trade = standard()
    local before = totals()
    readyBoth(trade)
    local ok, result = confirmBoth(trade)
    H.ok(ok, 'commit succeeds') H.equal(result, 'completed', 'completed')
    H.equal(hooks.committed, 1, 'committed hook ran once')
    H.equal(lastEnded().committed, true, 'ended as committed')
    H.equal(world[1].items[1].amount, 2, 'giver keeps the rest of the stack')
    local pistol, bread, gold
    for _, entry in pairs(world[2].items) do
        if entry.name == 'pistol' then pistol = entry end
        if entry.name == 'bread' then bread = entry end
    end
    for _, entry in pairs(world[1].items) do
        if entry.name == 'gold' then gold = entry end
    end
    H.ok(pistol and pistol.info.serial == 'SER-1' and pistol.info.durability == 87, 'serialled weapon keeps its metadata')
    H.equal(bread and bread.amount, 3, 'receiver gets the offered amount')
    H.ok(gold and gold.amount == 2 and gold.info.purity == 24, 'gold arrives with metadata')
    H.equal(world[1].cash, 1250, 'cash received')
    H.equal(world[2].cash, 750, 'cash paid')
    sameTotals(before, totals(), 'successful trade')
    H.equal(machine.of(1), nil, 'player 1 free after commit')
    H.equal(machine.confirm(1, trade.id, trade.revision), false, 'a finished trade cannot be confirmed again')
end

-- Capacity counts outgoing items first: a full receiver can take an item
-- when it gives one away in the same trade.
fresh()
do
    for slot = 1, 5 do world[1].items[slot] = item('water', 1, slot, { n = slot }) end
    world[2].items[1] = item('bread', 1, 1)
    local trade = openTrade()
    H.ok(machine.offer(1, trade.id, 3, 1), 'full player offers one slot')
    H.ok(machine.offer(2, trade.id, 1, 1), 'partner offers bread')
    readyBoth(trade)
    H.ok(confirmBoth(trade), 'swap into a full inventory succeeds because a slot frees first')
    H.ok(world[1].items[3] and world[1].items[3].name == 'bread', 'bread takes the freed slot')
end

-- ---- commit re-validation failures leave everything untouched -----------
local function failingCase(label, arrange, expectFatal, expectReason)
    local trade = standard()
    readyBoth(trade)
    clock = clock + 3000
    H.ok(machine.confirm(1, trade.id, trade.revision), label .. ': first confirm')
    local snap = snapshotWorld()
    local before = totals()
    arrange(trade)
    snap = snapshotWorld()
    before = totals()
    local ok, err = machine.confirm(2, trade.id, trade.revision)
    H.equal(ok, false, label .. ': commit refused')
    if expectReason then H.equal(err, expectReason, label .. ': reason') end
    untouched(snap, label)
    sameTotals(before, totals(), label)
    if expectFatal then
        H.equal(machine.get(trade.id), nil, label .. ': trade ended')
        H.equal(lastEnded().committed, false, label .. ': not committed')
    else
        local current = machine.get(trade.id)
        H.ok(current and current.phase == 'open', label .. ': back to open for review')
        H.equal(current.sides[1].ready or current.sides[2].ready, false, label .. ': both must ready again')
        if expectReason ~= 'trade changed, review it again' then
            H.ok(current.lastError ~= nil, label .. ': error kept for the panel')
        end
    end
    return trade
end

failingCase('item metadata changed without a revision', function()
    world[1].items[2].info.serial = 'SER-SWAPPED'
end, false, 'offered item changed')
failingCase('item amount changed without a revision', function()
    world[1].items[1].amount = 4
end, false, 'offered item changed')
failingCase('item replaced without a revision', function()
    world[2].items[1] = item('rock', 2, 1, { purity = 24 })
end, false, 'offered item changed')
failingCase('slot became busy', function()
    hooks.busy['1:2'] = true
end, false, 'item is currently being used')
hooks.busy = {}
-- Ledger cash leaving between confirmations is caught by the refresh in front
-- of the commit: the offer is withdrawn and both must review again.
failingCase('ledger cash spent elsewhere', function()
    world[2].cash = 100
end, false, 'trade changed, review it again')
failingCase('receiver over weight', function()
    world[2].items[3] = item('rock', 2, 3)
    world[2].items[4] = item('rock', 1, 4)
end, false)
failingCase('receiver has no free slot', function()
    world[2].items[2] = item('water', 1, 2, { a = 1 })
    world[2].items[3] = item('water', 1, 3, { a = 2 })
    world[2].items[4] = item('water', 1, 4, { a = 3 })
    world[2].items[5] = item('water', 1, 5, { a = 4 })
end, false)
failingCase('too far apart', function()
    world[2].pos = { x = 30, y = 0, z = 0 }
end, true, 'player is too far away')
failingCase('different bucket', function()
    world[2].bucket = 3
end, true, 'different routing bucket')
failingCase('partner offline', function()
    world[1].online = false
end, true, 'player unavailable')
failingCase('partner cuffed', function()
    world[2].cuffed = true
end, true, 'player is cuffed')
failingCase('inventory busy (lock held)', function()
    hooks.lockBusy = true
end, false, 'inventory busy')
hooks.lockBusy = false
failingCase('hook refused', function()
    hooks.beforeCommitRefuse = true
end, false, 'hook refused')
hooks.beforeCommitRefuse = false
for at = 1, 4 do -- the standard trade writes four slots
    failingCase('write ' .. at .. ' fails, rollback', function()
        hooks.writes = 0
        hooks.failWriteAt = at
    end, false)
    hooks.failWriteAt = nil
end
failingCase('cash transfer fails after item writes, rollback', function()
    hooks.transferFails = true
end, false, 'player data is busy')
hooks.transferFails = false
failingCase('disabled at commit time', function()
    settingsTable.enabled = false
end, true, 'trading is disabled')

-- Snapshot taken at Ready: an item swapped for an identical-looking one
-- (same name/amount, different metadata) after locking blocks the commit
-- even if the revision was not bumped.
do
    local trade = standard()
    readyBoth(trade)
    world[1].items[2] = item('pistol', 1, 2, { serial = 'FAKE', durability = 87 })
    clock = clock + 3000
    machine.confirm(1, trade.id, trade.revision)
    local ok = machine.confirm(2, trade.id, trade.revision)
    H.equal(ok, false, 'swapped weapon refused at commit')
    local found
    for _, entry in pairs(world[2].items) do if entry.name == 'pistol' then found = true end end
    H.equal(found, nil, 'swapped weapon never reached the partner')
end

-- ---- physical cash (item mode) -------------------------------------------
fresh()
do
    hooks.cashMode = 'item'
    world[1].items[1] = item('cash', 300, 1)
    world[1].items[2] = item('cash', 200, 2)
    world[2].items[1] = item('bread', 2, 1)
    local trade = openTrade()
    H.equal(select(2, machine.offer(1, trade.id, 1, 100)), 'use the cash field to trade cash', 'cash item cannot be an item offer')
    H.equal(select(2, machine.setCash(1, trade.id, 501)), 'insufficient funds', 'cash above the item balance refused')
    H.ok(machine.setCash(1, trade.id, 400), 'offer 400 physical cash')
    H.ok(machine.offer(2, trade.id, 1, 2), 'offer bread')
    local before = totals()
    readyBoth(trade)
    H.ok(confirmBoth(trade), 'physical cash trade commits')
    H.equal(cashItemBalance(1), 100, 'payer keeps the rest')
    H.equal(cashItemBalance(2), 400, 'payee receives the cash stack')
    sameTotals(before, totals(), 'physical cash trade')

    -- Physical cash leaves via another path before commit.
    world[1].items = { [1] = item('cash', 500, 1) }
    world[2].items = { [1] = item('bread', 1, 1) }
    clock = clock + 20000
    trade = openTrade()
    H.ok(machine.setCash(1, trade.id, 500), 'offer all cash')
    H.ok(machine.offer(2, trade.id, 1, 1), 'offer bread')
    readyBoth(trade)
    clock = clock + 3000
    machine.confirm(1, trade.id, trade.revision)
    world[1].items[1].amount = 10 -- no revision bump: the snapshot/balance must still catch it
    local snap = snapshotWorld()
    H.equal(machine.confirm(2, trade.id, trade.revision), false, 'cash shortfall refused')
    untouched(snap, 'physical cash shortfall')
end

-- ---- cancellation ------------------------------------------------------
fresh()
do
    world[1].items[1] = item('bread', 5, 1)
    local trade = openTrade()
    machine.offer(1, trade.id, 1, 1)
    H.equal(machine.cancel(3, trade.id), false, 'outsider cannot cancel')
    H.ok(machine.cancel(2, trade.id, 'cancelled by a player'), 'member cancels')
    H.equal(lastEnded().committed, false, 'cancel is not a commit')
    H.equal(world[1].items[1].amount, 5, 'cancel moves nothing')
    H.equal(machine.of(1), nil, 'released')

    clock = clock + 20000
    trade = openTrade()
    H.ok(machine.cancelFor(2, 'player left'), 'disconnect cancels')
    H.equal(lastEnded().reason, 'player left', 'disconnect reason')
    H.equal(machine.cancelFor(2, 'again'), false, 'nothing left to cancel')

    for label, arrange in pairs({
        distance = function() world[2].pos = { x = 9, y = 0, z = 0 } end,
        downed = function() world[1].downed = true end,
        cuffed = function() world[2].cuffed = true end,
        offline = function() world[2].online = false end,
        bucket = function() world[1].bucket = 2 end,
    }) do
        resetWorld()
        machine = TradeState.new(deps)
        world[1].items[1] = item('bread', 5, 1)
        trade = openTrade()
        machine.offer(1, trade.id, 1, 2)
        readyBoth(trade)
        arrange()
        machine.tick()
        H.equal(machine.get(trade.id), nil, 'monitor cancels on ' .. label)
        H.equal(world[1].items[1].amount, 5, label .. ': nothing moved')
    end

    resetWorld()
    machine = TradeState.new(deps)
    trade = openTrade()
    clock = clock + 300001
    machine.tick()
    H.equal(lastEnded().reason, 'trade expired', 'maxDuration ends the trade')

    -- A pending request ends when a player leaves.
    clock = clock + 20000
    trade = machine.request(1, 2)
    world[2].online = false
    machine.tick()
    H.equal(machine.get(trade.id), nil, 'pending request ends when the target leaves')
    world[2].online = true
end

-- ---- view --------------------------------------------------------------
do
    local trade = standard()
    local view = machine.view(trade, 2)
    H.equal(view.id, trade.id, 'view id')
    H.equal(#view.them.offers, 2, 'partner offers visible')
    H.equal(view.you.cash, 250, 'own cash')
    H.equal(view.them.offers[1].info, nil, 'pure view carries no metadata')
    H.equal(machine.view(trade, 3), nil, 'outsider has no view')
    readyBoth(trade)
    view = machine.view(trade, 1)
    H.equal(view.confirmInMs, 3000, 'countdown reported')
    clock = clock + 1200
    H.equal(machine.view(trade, 1).confirmInMs, 1800, 'countdown decreases')
end

-- ---------------------------------------------------------------------------
-- Part 2: server.lua + server/trade.lua, real intents and writes
-- ---------------------------------------------------------------------------

Config = { kora_inventory = {} }
dofile('config.lua')
dofile('config/shops/ammunation.lua')
dofile('shared.lua')

local callbacks, netEvents, localEvents, clientEvents = {}, {}, {}, {}
local timer = 50000
Kora = {
    util = { deepClone = function(value)
        local function clone(v)
            if type(v) ~= 'table' then return v end
            local out = {}
            for k, vv in pairs(v) do out[k] = clone(vv) end
            return out
        end
        return clone(value)
    end, clamp = function(v, lo, hi) return math.max(lo, math.min(hi, v)) end },
    resources = { serverRegistry = function() return { track = function() end, untrack = function() end } end },
    callback = { register = function(name, fn) callbacks[name] = fn end },
    sql = {},
    notify = { send = function() end },
    lang = function(key) return key end,
    distance = { player = function() return true end },
    logging = { info = function() end, warn = function() end, error = function() end },
}
GetCurrentResourceName = function() return 'kora_inventory' end
GetInvokingResource = function() return nil end
CreateThread = function() end
Wait = function() end
RegisterCommand = function() end
AddEventHandler = function(name, fn)
    localEvents[name] = localEvents[name] or {}
    table.insert(localEvents[name], fn)
end
RegisterNetEvent = function(name, fn) if fn then netEvents[name] = fn end end
TriggerClientEvent = function(name, target, ...)
    clientEvents[#clientEvents + 1] = { name = name, target = target, args = { ... } }
end
TriggerEvent = function(name, ...)
    for _, fn in ipairs(localEvents[name] or {}) do fn(...) end
end
GetGameTimer = function() return timer end
GetPlayerRoutingBucket = function() return 0 end
GetPlayerPed = function(src) return 1000 + src end
local positions = { [7] = { x = 0.0, y = 0.0, z = 0.0 }, [9] = { x = 1.0, y = 0.0, z = 0.0 } }
GetEntityCoords = function(ped) return positions[ped - 1000] end

local ITEMS = {
    bread = { name = 'bread', label = 'Bread', weight = 100, type = 'item', unique = false },
    gem = { name = 'gem', label = 'Gem', weight = 10, type = 'item', unique = true },
}
local playersData = { [7] = { citizenid = 'CID-7' }, [9] = { citizenid = 'CID-9' } }
local playersItems = { [7] = {}, [9] = {} }
local money = { [7] = 500, [9] = 50 }

local registered = {}
exports = setmetatable({}, {
    __call = function(_, name, fn) registered[name] = fn end,
    __index = function(_, resource)
        return setmetatable({}, {
            __index = function(_, exportName)
                return function(_, ...)
                    if resource == 'kora_core' then
                        if exportName == 'allShared' then return {} end
                        if exportName == 'getShared' then
                            local registry, itemName = ...
                            return registry == 'items' and ITEMS[itemName] or nil
                        end
                        if exportName == 'getPlayerData' then
                            local src, fields = ...
                            if fields and fields[1] == 'items' then return playersItems[src] end
                            if fields and fields[1] == 'metadata' then return {} end
                            return playersData[src]
                        end
                        if exportName == 'setPath' then
                            local src, path, value = ...
                            if path[1] ~= 'items' then return false, 'unsupported path' end
                            if path[2] then playersItems[src][path[2]] = value else playersItems[src] = value end
                            return true
                        end
                        if exportName == 'isPhysicalCash' then return false end
                        if exportName == 'getMoney' then return money[(...)] end
                        if exportName == 'transferMoney' then
                            local from, to, account, amount, _, ignoreTax = ...
                            if account ~= 'cash' or ignoreTax ~= true then return false, 'unexpected transfer' end
                            if money[from] < amount then return false, 'insufficient funds' end
                            money[from], money[to] = money[from] - amount, money[to] + amount
                            return true
                        end
                    end
                    local fn = registered[exportName]
                    if fn then return fn(...) end
                    return nil
                end
            end,
        })
    end,
})

dofile('server/persistence.lua')
dofile('server.lua')
dofile('server/trade_state.lua')
dofile('server/trade.lua')

local internal = KoraInventory.internal
local intent = callbacks['kora_inventory:server:intent']

local function lastClient(name, target)
    for index = #clientEvents, 1, -1 do
        local event = clientEvents[index]
        if event.name == name and (target == nil or event.target == target) then return event end
    end
end
local function invoke(name, src, ...)
    source = src
    netEvents[name](...)
end

playersItems[7] = { [1] = internal.buildItem('bread', 10, 1, {}), [2] = internal.buildItem('gem', 1, 2, { serial = 'GEM-77' }) }
playersItems[9] = { [1] = internal.buildItem('bread', 1, 1, { baked = 'today' }) }

-- Garbage through the net events is ignored.
invoke('kora_inventory:server:tradeRequest', 7, { 9 })
invoke('kora_inventory:server:tradeRequest', 7, 9.5)
H.equal(KoraInventory.trade.machine.count(), 0, 'malformed request targets are ignored')

invoke('kora_inventory:server:tradeRequest', 7, 9)
local invite = lastClient('kora_inventory:client:tradeInvite', 9)
H.ok(invite, 'invite reaches the target')
local tradeId = invite.args[1]
H.equal(type(tradeId), 'string', 'server-generated trade id')
invoke('kora_inventory:server:tradeRespond', 7, tradeId, true)
H.equal(KoraInventory.trade.machine.get(tradeId).phase, 'pending', 'requester cannot accept their own request')
invoke('kora_inventory:server:tradeRespond', 9, tradeId, 'true')
H.equal(KoraInventory.trade.machine.get(tradeId).phase, 'pending', 'non-boolean answer ignored')
invoke('kora_inventory:server:tradeRespond', 9, tradeId, true)
local current = KoraInventory.trade.machine.get(tradeId)
H.equal(current.phase, 'open', 'accepted through the net event')
local s7, s9 = internal.sessionOf(7), internal.sessionOf(9)
H.ok(s7 and s9, 'both players got an inventory session')
H.equal(current.tokens[7], s7.token, 'trade bound to player 7 session')
local state = lastClient('kora_inventory:client:tradeState', 9)
H.ok(state and state.args[1].id == tradeId, 'trade view published')

local function tradeIntent(src, payload, revision)
    local session = internal.sessionOf(src)
    return intent(src, { token = session.token, action = 'trade', payload = payload, primaryRevision = revision })
end
local function rev(src) return internal.getRevision(internal.playerKey(src)) end

H.equal(select(2, tradeIntent(7, { op = 'offer', id = tradeId, slot = 1, amount = 4 })), 'stale inventory', 'offer without the inventory revision refused')
H.equal(select(2, tradeIntent(7, { op = 'offer', id = tradeId, slot = 1, amount = 4 }, rev(7) + 1)), 'stale source inventory', 'offer on a stale revision refused')
H.equal(select(2, tradeIntent(7, { op = 'steal', id = tradeId })), 'invalid trade action', 'unknown op refused')
-- A smuggled item record is ignored: only slot and amount are read, so this
-- offers 4 of the bread really in slot 1, not a gem.
H.ok(tradeIntent(7, { op = 'offer', id = tradeId, slot = 1, amount = 4, item = { name = 'gem', amount = 99 } }, rev(7)), 'offer with a smuggled item record')
H.equal(current.sides[7].offers[1].name, 'bread', 'the offer names the real item in the slot')
H.equal(select(2, intent(7, { token = 'forged', action = 'trade', payload = { op = 'cancel', id = tradeId } })), 'invalid session', 'forged token refused')
H.equal(select(2, tradeIntent(7, { op = 'cancel', id = 'trade-999-1' })), 'trade not found', 'unknown trade refused')
H.ok(tradeIntent(7, { op = 'offer', id = tradeId, slot = 2, amount = 1 }, rev(7)), 'offer gem')
H.ok(tradeIntent(9, { op = 'offer', id = tradeId, slot = 1, amount = 1 }, rev(9)), 'offer bread')
H.ok(tradeIntent(9, { op = 'cash', id = tradeId, cash = 40 }), 'offer ledger cash')
state = lastClient('kora_inventory:client:tradeState', 7).args[1]
H.equal(state.them.offers[1].label, 'Bread', 'partner offer is decorated with the server label')
H.equal(state.them.offers[1].info, nil, 'partner never receives raw item metadata')
H.equal(state.them.cash, 40, 'partner cash visible')
H.ok(tradeIntent(7, { op = 'ready', id = current.id, revision = current.revision }), 'ready 7')
H.ok(tradeIntent(9, { op = 'ready', id = current.id, revision = current.revision }), 'ready 9')
H.equal(current.phase, 'locked', 'locked')
H.equal(select(2, tradeIntent(7, { op = 'confirm', id = current.id, revision = current.revision })), 'wait for the countdown to finish', 'countdown enforced')
timer = timer + 3000
H.ok(tradeIntent(7, { op = 'confirm', id = current.id, revision = current.revision }), 'confirm 7')
local revisions = { rev(7), rev(9) }
H.ok(tradeIntent(9, { op = 'confirm', id = current.id, revision = current.revision }), 'confirm 9 commits')
H.equal(KoraInventory.trade.machine.get(tradeId), nil, 'trade finished')
local gem
for _, entry in pairs(playersItems[9]) do if entry.name == 'gem' then gem = entry end end
H.ok(gem and gem.info.serial == 'GEM-77', 'unique item crossed with its serial')
local bakedBread
for _, entry in pairs(playersItems[7]) do
    if entry.name == 'bread' and entry.info.baked == 'today' then bakedBread = entry end
end
H.ok(bakedBread and bakedBread.amount == 1, 'partner bread arrived with its metadata (not merged into plain bread)')
local received, baked = 0, 0
for _, entry in pairs(playersItems[9]) do
    if entry.name == 'bread' then
        if entry.info.baked then baked = baked + entry.amount else received = received + entry.amount end
    end
end
H.equal(baked, 0, 'giver no longer holds the traded bread')
H.equal(received, 4, 'player 9 received the 4 plain bread player 7 offered')
local plain = 0
for _, entry in pairs(playersItems[7]) do
    if entry.name == 'bread' and not entry.info.baked then plain = plain + entry.amount end
end
H.equal(plain, 6, 'player 7 kept the other 6 bread')
H.equal(money[7], 540, 'ledger cash received')
H.equal(money[9], 10, 'ledger cash paid')
H.ok(rev(7) > revisions[1] and rev(9) > revisions[2], 'both revisions bumped after commit')
H.ok(lastClient('kora_inventory:client:tradeEnded', 7).args[3] == true, 'completion reported')

-- A second trade, cancelled by closing the trade session.
timer = timer + 20000
invoke('kora_inventory:server:tradeRequest', 7, 9)
tradeId = lastClient('kora_inventory:client:tradeInvite', 9).args[1]
invoke('kora_inventory:server:tradeRespond', 9, tradeId, true)
local token9 = internal.sessionOf(9).token
source = 7
netEvents['kora_inventory:server:close'](token9)
H.ok(KoraInventory.trade.machine.get(tradeId), 'another player cannot close the trade session')
source = 9
netEvents['kora_inventory:server:close'](token9)
H.equal(KoraInventory.trade.machine.get(tradeId), nil, 'closing the trade session cancels the trade')

-- Cooldown through the net event, then disconnect cancels.
invoke('kora_inventory:server:tradeRequest', 7, 9)
H.equal(KoraInventory.trade.machine.count(), 0, 'request cooldown applies to the net event')
timer = timer + 10001
invoke('kora_inventory:server:tradeRequest', 7, 9)
tradeId = lastClient('kora_inventory:client:tradeInvite', 9).args[1]
invoke('kora_inventory:server:tradeRespond', 9, tradeId, true)
source = 7
TriggerEvent('playerDropped')
H.equal(KoraInventory.trade.machine.get(tradeId), nil, 'disconnect cancels the trade')

-- Disabled from config: requests are refused.
timer = timer + 10001
Config.kora_inventory.trade.enabled = false
invoke('kora_inventory:server:tradeRequest', 9, 7)
H.equal(KoraInventory.trade.machine.count(), 0, 'disabled trade refuses requests')
Config.kora_inventory.trade.enabled = true

H.finish()
