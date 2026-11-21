-- Two-player confirmed trade: the pure state machine and the atomic commit.
--
-- This file has NO FX natives and no exports. Everything it needs from the
-- world (time, players, items, locks, writes) comes in through `deps`, which
-- server/trade.lua wires to the real inventory authority and test/smoke/trade.lua
-- wires to an in-memory fake. Keeping the rules here means the dupe-relevant
-- logic (offer validation, un-ready on change, the confirm gate, commit
-- re-validation, planning and rollback) is exercised without a server.
--
-- Security model, in one place:
--   * An offer is a REFERENCE { slot, amount } to the offerer's own inventory,
--     remembered with the item's name and metadata. Nothing moves until commit.
--   * Every change to either side, and every change to either player's
--     inventory (its revision), clears both players' Ready and Confirm.
--   * Ready needs the trade revision the player last saw; once both are ready
--     the offers freeze ("locked") and a snapshot of every offered stack is
--     taken. Confirm is refused until `confirmDelay` seconds have passed and
--     also needs the revision the player last saw.
--   * Commit runs under both players' inventory locks, re-validates everything
--     (presence, bucket, distance, guards, revisions, the snapshot, busy slots,
--     cash, capacity after outgoing items leave), plans both final inventories
--     as drafts, writes only the changed slots, and restores every written slot
--     exactly if any later write (or the cash leg) fails.

KoraInventory = KoraInventory or {}

local TradeState = {}
KoraInventory.TradeState = TradeState

TradeState.MAX_SLOTS = 32
TradeState.MAX_CASH = 1000000000

TradeState.DEFAULTS = {
    enabled = true,
    slots = 8,
    allowCash = true,
    distance = 3.0,
    requestTimeout = 20,
    confirmDelay = 3,
    maxDuration = 300,
    requestCooldown = 10,
    command = 'trade',
}

local function copy(value, depth)
    depth = depth or 0
    if type(value) ~= 'table' or depth > 16 then
        return value
    end
    local out = {}
    for key, inner in pairs(value) do
        out[key] = copy(inner, depth + 1)
    end
    return out
end
TradeState.copy = copy

local function same(left, right, depth)
    if left == right then
        return true
    end
    if type(left) ~= 'table' or type(right) ~= 'table' or depth > 16 then
        return false
    end
    for key, value in pairs(left) do
        if not same(value, right[key], depth + 1) then
            return false
        end
    end
    for key in pairs(right) do
        if left[key] == nil then
            return false
        end
    end
    return true
end
TradeState.same = function(left, right)
    return same(left, right, 0)
end

local function metadataOf(item)
    if type(item) ~= 'table' then
        return {}
    end
    if type(item.info) == 'table' then
        return item.info
    end
    return type(item.metadata) == 'table' and item.metadata or {}
end
TradeState.metadataOf = metadataOf

local function wholeNumber(value, min, max)
    return type(value) == 'number' and value == value and value % 1 == 0 and value >= min and value <= max
end
TradeState.wholeNumber = wholeNumber

---Trade settings merged onto the defaults and clamped. Read on every call so a
---/config change applies to the next action without a restart.
---@param raw table|nil
---@return table
function TradeState.settings(raw)
    raw = type(raw) == 'table' and raw or {}
    local out = {}
    for key, value in pairs(TradeState.DEFAULTS) do
        out[key] = value
    end
    local function num(key, min, max, integer)
        local value = tonumber(raw[key])
        if value and value == value then
            if integer then
                value = math.floor(value)
            end
            out[key] = math.max(min, math.min(max, value))
        end
    end
    out.enabled = raw.enabled ~= false
    out.allowCash = raw.allowCash ~= false
    num('slots', 1, TradeState.MAX_SLOTS, true)
    num('distance', 0.5, 50.0)
    num('requestTimeout', 5, 120, true)
    num('confirmDelay', 0, 30, true)
    num('maxDuration', 30, 3600, true)
    num('requestCooldown', 0, 600, true)
    if type(raw.command) == 'string' then
        out.command = raw.command
    end
    return out
end

---Create a state machine bound to `deps`. See server/trade.lua for the real
---wiring and test/smoke/trade.lua for the in-memory one.
---@param deps table
---@return table machine
function TradeState.new(deps)
    local machine = {}
    local trades = {}
    local byPlayer = {}
    local lastRequest = {}
    local nextId = 0

    local function settings()
        return TradeState.settings(deps.settings and deps.settings() or nil)
    end
    local function log(level, message, data)
        if deps.log then
            pcall(deps.log, level, message, data)
        end
    end
    local function publish(trade)
        if deps.publish then
            pcall(deps.publish, trade)
        end
    end

    local function other(trade, src)
        if trade.a == src then
            return trade.b
        end
        if trade.b == src then
            return trade.a
        end
    end

    local function member(src, id)
        local trade = type(id) == 'string' and trades[id] or nil
        if not trade or (trade.a ~= src and trade.b ~= src) then
            return nil, 'trade not found'
        end
        return trade
    end

    local function newSide()
        return { offers = {}, cash = 0, ready = false, confirmed = false }
    end

    local function sideEmpty(side)
        return #side.offers == 0 and (side.cash or 0) == 0
    end

    local function clearFlags(trade)
        local changed = false
        for _, src in ipairs({ trade.a, trade.b }) do
            local side = trade.sides[src]
            if side.ready or side.confirmed then
                changed = true
            end
            side.ready, side.confirmed = false, false
        end
        if trade.phase == 'locked' then
            trade.phase = 'open'
            trade.lockedAt, trade.snapshot = nil, nil
            changed = true
        end
        return changed
    end

    local function touch(trade)
        clearFlags(trade)
        trade.revision = trade.revision + 1
        trade.lastError = nil
    end

    ---Removes a trade and releases both players. `reason` is reported to both.
    local function finish(trade, reason, committed)
        if trades[trade.id] ~= trade then
            return false
        end
        trades[trade.id] = nil
        if byPlayer[trade.a] == trade.id then
            byPlayer[trade.a] = nil
        end
        if byPlayer[trade.b] == trade.id then
            byPlayer[trade.b] = nil
        end
        trade.phase = committed and 'completed' or 'cancelled'
        trade.endReason = reason
        if deps.ended then
            pcall(deps.ended, trade, reason, committed == true)
        end
        return true
    end

    ---The checks shared by request, accept, the monitor and commit: both
    ---players online, neither downed/cuffed, same routing bucket and in range.
    ---Returns nil when fine, else the reason.
    local function presenceProblem(a, b, maxDistance)
        if not deps.online(a) or not deps.online(b) then
            return 'player unavailable'
        end
        local blocked = deps.blocked(a) or deps.blocked(b)
        if blocked then
            return blocked
        end
        if not deps.sameBucket(a, b) then
            return 'different routing bucket'
        end
        local distance = deps.distance(a, b)
        if type(distance) ~= 'number' or distance ~= distance or distance > maxDistance then
            return 'player is too far away'
        end
        return nil
    end
    machine.presenceProblem = presenceProblem

    local function cashBalance(src)
        local balance = deps.cashBalance and deps.cashBalance(src) or nil
        balance = tonumber(balance)
        if not balance or balance ~= balance then
            return nil
        end
        return math.floor(balance)
    end

    ---Is this offer still backed by the offerer's real item?
    local function offerProblem(src, items, offer)
        local item = items[offer.slot]
        if type(item) ~= 'table' or item.name ~= offer.name then
            return 'offered item changed'
        end
        if not TradeState.same(metadataOf(item), offer.info) then
            return 'offered item changed'
        end
        local amount = tonumber(item.amount) or 0
        if amount < offer.amount then
            return 'offered item changed'
        end
        if deps.slotBusy and deps.slotBusy(src, offer.slot) then
            return 'item is currently being used'
        end
        return nil
    end

    ---Brings a trade up to date with both inventories. Any inventory revision
    ---change clears Ready/Confirm (and unlocks); offers whose slot no longer
    ---backs them are dropped; ledger cash above the balance is reset to 0.
    ---Returns true when anything the players can see changed.
    local function refresh(trade)
        if trade.phase ~= 'open' and trade.phase ~= 'locked' then
            return false
        end
        local changed = false
        local inventoryMoved = false
        for _, src in ipairs({ trade.a, trade.b }) do
            local side = trade.sides[src]
            local current = deps.revision(src)
            if current ~= trade.revisions[src] then
                trade.revisions[src] = current
                inventoryMoved = true
                local items = deps.items(src) or {}
                for index = #side.offers, 1, -1 do
                    if offerProblem(src, items, side.offers[index]) then
                        table.remove(side.offers, index)
                        changed = true
                    end
                end
            end
            if (side.cash or 0) > 0 then
                local balance = cashBalance(src)
                if not balance or balance < side.cash then
                    side.cash = 0
                    changed = true
                end
            end
        end
        if inventoryMoved or changed then
            if clearFlags(trade) then
                changed = true
            end
        end
        if changed then
            trade.revision = trade.revision + 1
        end
        return changed
    end
    machine.refresh = refresh

    ---refresh() and, when it changed anything, tell both players at once so the
    ---refusal that may follow is about the state they can now see.
    local function sync(trade)
        if refresh(trade) then
            publish(trade)
        end
    end

    -- ------------------------------------------------------------------
    -- Requests
    -- ------------------------------------------------------------------

    ---Player `a` asks nearby player `b` to trade.
    function machine.request(a, b)
        local cfg = settings()
        if not cfg.enabled then
            return nil, 'trading is disabled'
        end
        if not wholeNumber(a, 1, 65535) or not wholeNumber(b, 1, 65535) or a == b then
            return nil, 'invalid trade partner'
        end
        if byPlayer[a] then
            return nil, 'you are already trading'
        end
        if byPlayer[b] then
            return nil, 'that player is busy'
        end
        local now = deps.now()
        local last = lastRequest[a]
        if last and now - last < cfg.requestCooldown * 1000 then
            return nil, 'wait before sending another trade request'
        end
        local problem = presenceProblem(a, b, cfg.distance)
        if problem then
            return nil, problem
        end
        lastRequest[a] = now
        nextId = nextId + 1
        local suffix = deps.random and deps.random() or nextId
        local trade = {
            id = ('trade-%d-%s'):format(nextId, tostring(suffix)),
            a = a,
            b = b,
            phase = 'pending',
            createdAt = now,
            expiresAt = now + cfg.requestTimeout * 1000,
            revision = 1,
            sides = { [a] = newSide(), [b] = newSide() },
            revisions = {},
        }
        trades[trade.id] = trade
        byPlayer[a], byPlayer[b] = trade.id, trade.id
        if deps.invited then
            pcall(deps.invited, trade, cfg)
        end
        return trade
    end

    ---The invited player answers. Only `b` may answer, only while pending.
    function machine.respond(src, id, accept)
        local trade, err = member(src, id)
        if not trade then
            return false, err
        end
        if trade.phase ~= 'pending' or trade.b ~= src then
            return false, 'trade request is no longer pending'
        end
        if accept ~= true then
            finish(trade, 'declined')
            return true
        end
        local cfg = settings()
        local now = deps.now()
        if now > trade.expiresAt then
            finish(trade, 'timeout')
            return false, 'trade request expired'
        end
        if not cfg.enabled then
            finish(trade, 'disabled')
            return false, 'trading is disabled'
        end
        local problem = presenceProblem(trade.a, trade.b, cfg.distance)
        if problem then
            finish(trade, problem)
            return false, problem
        end
        trade.phase = 'open'
        trade.startedAt = now
        trade.revisions[trade.a] = deps.revision(trade.a)
        trade.revisions[trade.b] = deps.revision(trade.b)
        trade.revision = trade.revision + 1
        if deps.opened then
            local ok, opened, openErr = pcall(deps.opened, trade)
            if not ok or opened == false then
                finish(trade, ok and openErr or 'trade could not be opened')
                return false, ok and openErr or 'trade could not be opened'
            end
        end
        publish(trade)
        return true
    end

    -- ------------------------------------------------------------------
    -- Offers (open phase only)
    -- ------------------------------------------------------------------

    local function editable(src, id)
        local trade, err = member(src, id)
        if not trade then
            return nil, err
        end
        sync(trade)
        if trade.phase == 'locked' then
            return nil, 'offers are locked'
        end
        if trade.phase ~= 'open' then
            return nil, 'trade is not open'
        end
        return trade
    end

    function machine.offer(src, id, slot, amount)
        local trade, err = editable(src, id)
        if not trade then
            return false, err
        end
        local cfg = settings()
        local maxSlot = deps.playerSlots()
        if not wholeNumber(slot, 1, maxSlot) then
            return false, 'invalid slot'
        end
        local items = deps.items(src) or {}
        local item = items[slot]
        if type(item) ~= 'table' or type(item.name) ~= 'string' then
            return false, 'invalid item amount'
        end
        local stack = tonumber(item.amount) or 0
        if amount == nil then
            amount = stack
        end
        if not wholeNumber(amount, 1, TradeState.MAX_CASH) or amount > stack then
            return false, 'invalid item amount'
        end
        if deps.slotBusy and deps.slotBusy(src, slot) then
            return false, 'item is currently being used'
        end
        if deps.offerable then
            local allowed, reason = deps.offerable(src, item)
            if not allowed then
                return false, reason or 'this item cannot be traded'
            end
        end
        local side = trade.sides[src]
        local existing
        for _, offer in ipairs(side.offers) do
            if offer.slot == slot then
                existing = offer
                break
            end
        end
        if not existing and #side.offers >= cfg.slots then
            return false, 'no free offer slot'
        end
        local entry = existing or {}
        entry.slot, entry.amount, entry.name, entry.info = slot, amount, item.name, copy(metadataOf(item))
        if not existing then
            side.offers[#side.offers + 1] = entry
        end
        touch(trade)
        publish(trade)
        return true
    end

    function machine.unoffer(src, id, slot)
        local trade, err = editable(src, id)
        if not trade then
            return false, err
        end
        local side = trade.sides[src]
        for index, offer in ipairs(side.offers) do
            if offer.slot == slot then
                table.remove(side.offers, index)
                touch(trade)
                publish(trade)
                return true
            end
        end
        return false, 'item is not offered'
    end

    function machine.setCash(src, id, amount)
        local trade, err = editable(src, id)
        if not trade then
            return false, err
        end
        local cfg = settings()
        if not cfg.allowCash or not deps.cashBalance then
            return false, 'cash cannot be traded'
        end
        if not wholeNumber(amount, 0, TradeState.MAX_CASH) then
            return false, 'invalid cash amount'
        end
        if amount > 0 then
            local balance = cashBalance(src)
            if not balance or balance < amount then
                return false, 'insufficient funds'
            end
        end
        local side = trade.sides[src]
        if side.cash == amount then
            return true
        end
        side.cash = amount
        touch(trade)
        publish(trade)
        return true
    end

    -- ------------------------------------------------------------------
    -- Two-stage confirm
    -- ------------------------------------------------------------------

    local function snapshotOf(src, side)
        local items = deps.items(src) or {}
        local snap = { revision = deps.revision(src), cash = side.cash, slots = {} }
        for _, offer in ipairs(side.offers) do
            local item = items[offer.slot]
            snap.slots[offer.slot] = { name = item.name, amount = item.amount, info = copy(metadataOf(item)) }
        end
        return snap
    end

    function machine.ready(src, id, seenRevision)
        local trade, err = member(src, id)
        if not trade then
            return false, err
        end
        sync(trade)
        if trade.phase ~= 'open' then
            return false, trade.phase == 'locked' and 'already ready' or 'trade is not open'
        end
        if seenRevision ~= trade.revision then
            return false, 'trade changed, review it again'
        end
        local a, b = trade.sides[trade.a], trade.sides[trade.b]
        if sideEmpty(a) and sideEmpty(b) then
            return false, 'nothing has been offered'
        end
        -- Re-validate this player's own offers now; the partner's are checked
        -- again when both are ready and again at commit.
        local items = deps.items(src) or {}
        for _, offer in ipairs(trade.sides[src].offers) do
            local problem = offerProblem(src, items, offer)
            if problem then
                return false, problem
            end
        end
        if trade.sides[src].cash > 0 then
            local balance = cashBalance(src)
            if not balance or balance < trade.sides[src].cash then
                return false, 'insufficient funds'
            end
        end
        trade.sides[src].ready = true
        trade.lastError = nil
        if a.ready and b.ready then
            for _, player in ipairs({ trade.a, trade.b }) do
                local playerItems = deps.items(player) or {}
                for _, offer in ipairs(trade.sides[player].offers) do
                    local problem = offerProblem(player, playerItems, offer)
                    if problem then
                        touch(trade)
                        publish(trade)
                        return false, problem
                    end
                end
            end
            trade.phase = 'locked'
            trade.lockedAt = deps.now()
            trade.snapshot = { [trade.a] = snapshotOf(trade.a, a), [trade.b] = snapshotOf(trade.b, b) }
        end
        trade.revision = trade.revision + 1
        publish(trade)
        return true
    end

    function machine.unready(src, id)
        local trade, err = member(src, id)
        if not trade then
            return false, err
        end
        if trade.phase ~= 'open' and trade.phase ~= 'locked' then
            return false, 'trade is not open'
        end
        if trade.phase == 'locked' then
            clearFlags(trade)
        else
            trade.sides[src].ready = false
        end
        trade.revision = trade.revision + 1
        publish(trade)
        return true
    end

    ---Milliseconds until Confirm is accepted (0 = now), or nil when not locked.
    function machine.confirmWait(trade)
        if trade.phase ~= 'locked' or not trade.lockedAt then
            return nil
        end
        local delay = settings().confirmDelay * 1000
        return math.max(0, trade.lockedAt + delay - deps.now())
    end

    local commit

    function machine.confirm(src, id, seenRevision)
        local trade, err = member(src, id)
        if not trade then
            return false, err
        end
        sync(trade)
        if seenRevision ~= trade.revision then
            return false, 'trade changed, review it again'
        end
        if trade.phase ~= 'locked' then
            return false, 'both players must be ready first'
        end
        if machine.confirmWait(trade) > 0 then
            return false, 'wait for the countdown to finish'
        end
        trade.sides[src].confirmed = true
        if not (trade.sides[trade.a].confirmed and trade.sides[trade.b].confirmed) then
            trade.revision = trade.revision + 1
            publish(trade)
            return true
        end
        return commit(trade)
    end

    -- ------------------------------------------------------------------
    -- Commit
    -- ------------------------------------------------------------------

    local function snapshotProblem(trade, src)
        local snap = trade.snapshot and trade.snapshot[src]
        if not snap then
            return 'trade is not locked'
        end
        if deps.revision(src) ~= snap.revision then
            return 'offered item changed'
        end
        local items = deps.items(src) or {}
        local side = trade.sides[src]
        if (side.cash or 0) ~= (snap.cash or 0) then
            return 'trade changed'
        end
        for _, offer in ipairs(side.offers) do
            local expected = snap.slots[offer.slot]
            local item = items[offer.slot]
            if not expected or type(item) ~= 'table' or item.name ~= expected.name
                or tonumber(item.amount) ~= tonumber(expected.amount)
                or not TradeState.same(metadataOf(item), expected.info) then
                return 'offered item changed'
            end
            local problem = offerProblem(src, items, offer)
            if problem then
                return problem
            end
        end
        return nil
    end

    ---Builds both final inventories as drafts. Outgoing items leave first, so
    ---capacity is judged on what each receiver will actually hold.
    local function plan(trade, originals)
        local cashItem = deps.cashMode and deps.cashMode() == 'item' and deps.cashItem and deps.cashItem() or nil
        local drafts, legs = {}, { [trade.a] = {}, [trade.b] = {} }
        for _, src in ipairs({ trade.a, trade.b }) do
            local slots, maxWeight = deps.capacity(src)
            drafts[src] = { items = copy(originals[src]), slots = slots, maxWeight = maxWeight }
        end
        for _, src in ipairs({ trade.a, trade.b }) do
            local draft, side = drafts[src], trade.sides[src]
            for _, offer in ipairs(side.offers) do
                local item = draft.items[offer.slot]
                if not item or item.amount < offer.amount then
                    return nil, 'offered item changed'
                end
                legs[src][#legs[src] + 1] = { slot = offer.slot, name = item.name, amount = offer.amount, info = copy(metadataOf(item)) }
                if item.amount == offer.amount then
                    draft.items[offer.slot] = nil
                else
                    item.amount = item.amount - offer.amount
                end
            end
            if cashItem and (side.cash or 0) > 0 then
                local remaining = side.cash
                for slot = 1, draft.slots do
                    local item = draft.items[slot]
                    if item and item.name == cashItem then
                        local take = math.min(remaining, item.amount)
                        item.amount = item.amount - take
                        remaining = remaining - take
                        if item.amount == 0 then
                            draft.items[slot] = nil
                        end
                        if remaining == 0 then
                            break
                        end
                    end
                end
                if remaining > 0 then
                    return nil, 'insufficient funds'
                end
            end
        end
        for _, src in ipairs({ trade.a, trade.b }) do
            local receiver = other(trade, src)
            local draft = drafts[receiver]
            for _, leg in ipairs(legs[src]) do
                local added, addErr = deps.draftAdd(draft, leg.name, leg.amount, copy(leg.info))
                if not added then
                    return nil, (addErr == 'over weight' or addErr == 'no free slot')
                        and ('partner cannot carry that: ' .. addErr) or (addErr or 'cannot receive item'),
                        receiver
                end
            end
            local cash = trade.sides[src].cash or 0
            if cashItem and cash > 0 then
                local added, addErr = deps.draftAdd(draft, cashItem, cash, {})
                if not added then
                    return nil, 'partner cannot carry the cash: ' .. tostring(addErr), receiver
                end
            end
        end
        return drafts, legs
    end
    machine.plan = plan

    local function changedSlots(original, draft, maxSlot)
        local out = {}
        local highest = maxSlot
        for slot in pairs(original) do
            if type(slot) == 'number' and slot > highest then highest = slot end
        end
        for slot in pairs(draft) do
            if type(slot) == 'number' and slot > highest then highest = slot end
        end
        for slot = 1, highest do
            if not TradeState.same(original[slot], draft[slot]) then
                out[#out + 1] = slot
            end
        end
        return out
    end

    ---Restores every slot written so far to its original record. Returns false
    ---if any restore write failed (logged loudly; never silently).
    local function safeWrite(src, slot, value)
        local called, ok, err = pcall(deps.writeSlot, src, slot, value)
        if not called then
            return false, tostring(ok)
        end
        return ok == true, err
    end

    local function restore(written, originals)
        local ok = true
        for index = #written, 1, -1 do
            local entry = written[index]
            local restored, err = safeWrite(entry.src, entry.slot, copy(originals[entry.src][entry.slot]))
            if not restored then
                ok = false
                log('error', 'trade rollback write failed', { source = entry.src, slot = entry.slot, error = tostring(err) })
            end
        end
        return ok
    end

    ---Back to the open phase after a failed commit that is not the end of the
    ---trade (item changed, capacity, cash): both must review and ready again.
    local function reopen(trade, reason)
        if trades[trade.id] ~= trade then
            return
        end
        trade.phase = 'open'
        trade.lockedAt, trade.snapshot = nil, nil
        for _, src in ipairs({ trade.a, trade.b }) do
            trade.sides[src].ready, trade.sides[src].confirmed = false, false
            trade.revisions[src] = deps.revision(src)
        end
        trade.revision = trade.revision + 1
        trade.lastError = reason
        publish(trade)
    end

    ---The locked body of a commit. Returns ok, err, fatal, receipts.
    local function commitLocked(trade)
        local cfg = settings()
        if not cfg.enabled then
            return false, 'trading is disabled', true
        end
        if trade.phase ~= 'committing' then
            return false, 'trade is not ready', false
        end
        local problem = presenceProblem(trade.a, trade.b, cfg.distance)
        if problem then
            return false, problem, true
        end
        for _, src in ipairs({ trade.a, trade.b }) do
            local snapErr = snapshotProblem(trade, src)
            if snapErr then
                return false, snapErr, false
            end
            local cash = trade.sides[src].cash or 0
            if cash > 0 then
                if not cfg.allowCash then
                    return false, 'cash cannot be traded', false
                end
                local balance = cashBalance(src)
                if not balance or balance < cash then
                    return false, 'insufficient funds', false
                end
            end
        end
        local originals = { [trade.a] = copy(deps.items(trade.a) or {}), [trade.b] = copy(deps.items(trade.b) or {}) }
        local drafts, legs = plan(trade, originals)
        if not drafts then
            return false, legs, false
        end
        local handle
        if deps.beforeCommit then
            local called, allowed, hookErr, hookHandle = pcall(deps.beforeCommit, trade, legs)
            if not called then
                allowed, hookErr = false, 'trade was refused'
            end
            if not allowed then
                return false, hookErr or 'trade was refused', false
            end
            handle = hookHandle
        end
        local function fail(message, fatal)
            if deps.afterCommit then
                pcall(deps.afterCommit, handle, false)
            end
            return false, message, fatal == true
        end
        -- A hook may yield. Our locks keep kora_inventory's own writers out,
        -- but re-check presence and that neither inventory moved underneath
        -- the plan before writing anything.
        local late = presenceProblem(trade.a, trade.b, settings().distance)
        if late then
            return fail(late, true)
        end
        for _, src in ipairs({ trade.a, trade.b }) do
            if not TradeState.same(deps.items(src) or {}, originals[src]) then
                return fail('offered item changed')
            end
        end
        local written = {}
        for _, src in ipairs({ trade.a, trade.b }) do
            for _, slot in ipairs(changedSlots(originals[src], drafts[src].items, drafts[src].slots)) do
                local ok, writeErr = safeWrite(src, slot, copy(drafts[src].items[slot]))
                if not ok then
                    if not restore(written, originals) then
                        log('error', 'trade rollback incomplete', { trade = trade.id })
                    end
                    return fail(writeErr or 'inventory write failed')
                end
                written[#written + 1] = { src = src, slot = slot }
            end
        end
        local cashMode = deps.cashMode and deps.cashMode() or nil
        local net = (trade.sides[trade.a].cash or 0) - (trade.sides[trade.b].cash or 0)
        if cashMode == 'ledger' and net ~= 0 then
            local payer, payee = trade.a, trade.b
            if net < 0 then
                payer, payee, net = trade.b, trade.a, -net
            end
            local called, paid, payErr = pcall(deps.transferCash, payer, payee, net)
            if not called then
                paid, payErr = false, tostring(paid)
            end
            if not paid then
                if not restore(written, originals) then
                    log('error', 'trade rollback incomplete', { trade = trade.id })
                end
                return fail(payErr or 'cash transfer failed')
            end
        elseif cashMode ~= 'item' and net ~= 0 then
            if not restore(written, originals) then
                log('error', 'trade rollback incomplete', { trade = trade.id })
            end
            return fail('cash cannot be traded')
        end
        if deps.afterCommit then
            pcall(deps.afterCommit, handle, true)
        end
        return true, nil, false, { legs = legs, cash = { [trade.a] = trade.sides[trade.a].cash, [trade.b] = trade.sides[trade.b].cash } }
    end

    function commit(trade)
        trade.phase = 'committing'
        local ok, err, fatal, receipts
        local results = table.pack(deps.lock(trade.a, trade.b, function()
            return commitLocked(trade)
        end))
        ok, err, fatal, receipts = results[1], results[2], results[3], results[4]
        if ok == true then
            finish(trade, 'completed', true)
            if deps.committed then
                pcall(deps.committed, trade, receipts)
            end
            return true, 'completed'
        end
        err = err or 'trade failed'
        log('warn', 'trade commit refused', { trade = trade.id, reason = tostring(err) })
        if fatal then
            finish(trade, err)
        else
            reopen(trade, err)
        end
        return false, err
    end

    -- ------------------------------------------------------------------
    -- Cancellation and the monitor
    -- ------------------------------------------------------------------

    function machine.cancel(src, id, reason)
        local trade, err = member(src, id)
        if not trade then
            return false, err
        end
        if trade.phase == 'committing' then
            return false, 'trade is being completed'
        end
        finish(trade, reason or 'cancelled')
        return true
    end

    ---Ends whatever trade `src` is in (disconnect, death, cuffs, closed session).
    function machine.cancelFor(src, reason)
        local id = byPlayer[src]
        local trade = id and trades[id]
        if not trade or trade.phase == 'committing' then
            return false
        end
        return finish(trade, reason or 'cancelled')
    end

    ---Periodic checks: request timeout, maximum duration, presence, inventory
    ---changes. Call every few hundred milliseconds.
    function machine.tick()
        local cfg = settings()
        local now = deps.now()
        local list = {}
        for _, trade in pairs(trades) do
            list[#list + 1] = trade
        end
        for _, trade in ipairs(list) do
            if trade.phase == 'pending' then
                if now > trade.expiresAt then
                    finish(trade, 'timeout')
                elseif not cfg.enabled then
                    finish(trade, 'disabled')
                elseif not deps.online(trade.a) or not deps.online(trade.b) then
                    finish(trade, 'player unavailable')
                end
            elseif trade.phase == 'open' or trade.phase == 'locked' then
                local problem = not cfg.enabled and 'trading is disabled'
                    or (now - trade.startedAt > cfg.maxDuration * 1000) and 'trade expired'
                    or presenceProblem(trade.a, trade.b, cfg.distance)
                if problem then
                    finish(trade, problem)
                elseif refresh(trade) then
                    publish(trade)
                end
            end
        end
    end

    function machine.get(id)
        return trades[id]
    end

    function machine.of(src)
        local id = byPlayer[src]
        return id and trades[id] or nil
    end

    function machine.other(trade, src)
        return other(trade, src)
    end

    function machine.count()
        local n = 0
        for _ in pairs(trades) do
            n = n + 1
        end
        return n
    end

    function machine.forget(src)
        lastRequest[src] = nil
    end

    ---What one player is shown: their side and the partner's side (offers as
    ---slot/amount/name only; server/trade.lua adds display fields), flags,
    ---the revision to echo back on Ready/Confirm, and the timers.
    function machine.view(trade, src)
        local partner = other(trade, src)
        if not partner then
            return nil
        end
        local cfg = settings()
        local function side(player)
            local data = trade.sides[player]
            local offers = {}
            for index, offer in ipairs(data.offers) do
                offers[index] = { slot = offer.slot, amount = offer.amount, name = offer.name }
            end
            return { offers = offers, cash = data.cash or 0, ready = data.ready, confirmed = data.confirmed }
        end
        local now = deps.now()
        return {
            id = trade.id,
            phase = trade.phase,
            revision = trade.revision,
            slots = cfg.slots,
            allowCash = cfg.allowCash and deps.cashBalance ~= nil,
            you = side(src),
            them = side(partner),
            confirmInMs = machine.confirmWait(trade),
            confirmDelayMs = cfg.confirmDelay * 1000,
            endsInMs = trade.startedAt and math.max(0, trade.startedAt + cfg.maxDuration * 1000 - now) or nil,
            lastError = trade.lastError,
        }
    end

    return machine
end

return TradeState
