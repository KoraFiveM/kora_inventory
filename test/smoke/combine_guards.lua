-- Regression (L1/L2/L3) for server/combine.lua: spoiled and water damaged
-- ingredients are refused, a recipe must consume at least one item, and the
-- created result is recorded in the item-creation audit. Same in-memory
-- authority stand-in as combine.lua.
local H = dofile('test/harness.lua')

Config = { kora_inventory = {} }
dofile('config.lua')
local settings = Config.kora_inventory.combine

local NOW, invoking = 1000, 'other_resource'
GetGameTimer = function() return NOW end
GetInvokingResource = function() return invoking end
GetCurrentResourceName = function() return 'kora_inventory' end
TriggerEvent = function(name, ...) end
local handlers = {}
AddEventHandler = function(name, fn) handlers[name] = fn end
local exported = {}
exports = setmetatable({}, { __call = function(_, name, fn) exported[name] = fn end })

local logs = {}
local progress = { calls = {}, answer = true, elapsed = nil, onCall = nil }
Kora = {
    logging = {
        warn = function(code) logs[#logs + 1] = code end,
        error = function(code) logs[#logs + 1] = code end,
    },
    callback = {
        register = function() end,
        trigger = function(src, name, payload)
            progress.calls[#progress.calls + 1] = { src = src, name = name, payload = payload }
            NOW = NOW + (progress.elapsed or payload.time)
            if progress.onCall then progress.onCall() end
            if progress.answer == 'error' then error('timeout') end
            return progress.answer
        end,
    },
}

local function copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for key, nested in pairs(value) do out[key] = copy(nested) end
    return out
end
local function sameInfo(a, b)
    a, b = a or {}, b or {}
    for key, value in pairs(a) do if b[key] ~= value then return false end end
    for key, value in pairs(b) do if a[key] ~= value then return false end end
    return true
end

local defs = {
    rolling_paper = { name = 'rolling_paper', weight = 1 },
    weed = { name = 'weed', weight = 1 },
    joint = { name = 'joint', weight = 1 },
    water_bottle = { name = 'water_bottle', weight = 5 },
    sandwich = { name = 'sandwich', weight = 2 },
    brick = { name = 'brick', weight = 50 },
}

local KEY, TOKEN = 'player:7', 'tok'
local inv, revision, audit, busy, sessionOpen, itemBoxes
local busyNotices

local function weightOf(items)
    local total = 0
    for _, item in pairs(items) do total = total + defs[item.name].weight * item.amount end
    return total
end

local function reset(items)
    inv = { key = KEY, type = 'player', slots = 5, maxWeight = 20, items = items }
    revision, audit, busy, sessionOpen, itemBoxes, busyNotices = 1, {}, {}, true, {}, 0
    progress.calls, progress.answer, progress.elapsed, progress.onCall = {}, true, nil, nil
    NOW = 1000
end
local function stock()
    return {
        [1] = { slot = 1, name = 'rolling_paper', amount = 3, info = {} },
        [2] = { slot = 2, name = 'weed', amount = 2, info = {} },
        [4] = { slot = 4, name = 'water_bottle', amount = 1, info = {} },
    }
end

local failAddOnce
KoraInventory = {
    internal = {
        copy = copy,
        sameInfo = sameInfo,
        itemDef = function(name) return defs[name] end,
        playerKey = function() return KEY end,
        getInventory = function(key) if key == KEY then return inv end end,
        lock = function(_, transaction) return transaction() end,
        bump = function() revision = revision + 1 end,
        broadcast = function() end,
        sessionOf = function()
            if sessionOpen then return { token = TOKEN, primary = KEY, expires = NOW + 60000 } end
        end,
        validSession = function(src, token, fromKey, toKey, expectedFrom, expectedTo)
            if not sessionOpen or token ~= TOKEN then return nil, nil, 'invalid session' end
            if fromKey ~= KEY or toKey ~= KEY then return nil, nil, 'inventory not in session' end
            if expectedFrom ~= nil and expectedFrom ~= revision then return nil, nil, 'stale source inventory' end
            return {}, inv, inv
        end,
        isSlotBusy = function(_, slot) return busy[slot] == true end,
        setSlotBusy = function(_, slot, value) busy[slot] = value or nil end,
        notifyBusyBlocked = function() busyNotices = busyNotices + 1 end,
        busyError = 'item is currently being used',
        recordAudit = function(action, src, details) audit[#audit + 1] = { action = action, src = src, details = details } end,
        showItemBox = function(src, name, amount, action) itemBoxes[#itemBoxes + 1] = { name = name, amount = amount, action = action } end,
        removeFrom = function(_, slot, amount)
            local item = inv.items[slot]
            if not item then return false, 'empty slot' end
            if amount > item.amount then return false, 'not enough of item' end
            local removed = copy(item)
            removed.amount = amount
            if amount == item.amount then inv.items[slot] = nil else item.amount = item.amount - amount end
            return true, nil, removed
        end,
        addTo = function(_, name, amount, slot, info, reason, exact)
            if failAddOnce and reason == 'combine' then failAddOnce = nil return false, 'simulated failure' end
            if not defs[name] then return false, 'invalid item' end
            if weightOf(inv.items) + defs[name].weight * amount > inv.maxWeight then return false, 'over weight' end
            local stack = slot and inv.items[slot] and inv.items[slot].name == name and sameInfo(inv.items[slot].info, info) and slot
            if not stack and not exact then
                for index, item in pairs(inv.items) do
                    if item.name == name and sameInfo(item.info, info) then stack = index break end
                end
            end
            if stack then inv.items[stack].amount = inv.items[stack].amount + amount return true, stack end
            slot = slot or (function() for i = 1, inv.slots do if not inv.items[i] then return i end end end)()
            if not slot or inv.items[slot] then return false, 'no free slot' end
            inv.items[slot] = { slot = slot, name = name, amount = amount, info = copy(info or {}) }
            return true, slot
        end,
    },
}

local spoiled, wet, creations = {}, {}, {}
KoraInventory.decayRuntime = {
    guard = function(_, slot) return spoiled[slot] == true end,
}
KoraInventory.waterDamage = {
    blocksUse = function(_, item) return type(item.info) == 'table' and item.info.waterDamaged == true end,
}
KoraInventory.internal.auditAdd = function(action, src, key, name, amount, reason)
    creations[#creations + 1] = { action = action, src = src, key = key, name = name, amount = amount, reason = reason }
end
dofile('server/combine.lua')
local combine = KoraInventory.combine

local function intent(payload)
    return combine.intent(7, { token = TOKEN, action = 'combine', payload = payload, primaryRevision = revision })
end
local function go(from, to)
    return intent({ inventory = KEY, fromSlot = from, toSlot = to, revision = revision })
end
local function snapshotOf() return copy(inv.items) end
local function same(a, b)
    for key, item in pairs(a) do
        local other = b[key]
        if not other or other.name ~= item.name or other.amount ~= item.amount then return false end
    end
    for key in pairs(b) do if not a[key] then return false end end
    return true
end
local function stock()
    return {
        [1] = { slot = 1, name = 'rolling_paper', amount = 3, info = {} },
        [2] = { slot = 2, name = 'weed', amount = 2, info = {} },
    }
end
settings.recipes = { { a = 'rolling_paper', b = 'weed', result = 'joint', consumeA = 1, consumeB = 1, time = 0, label = 'Roll' } }

-- L2: a recipe must consume something ----------------------------------------
local function rejected(raw, message)
    local ok = combine.register(raw)
    H.equal(ok, false, message)
end
rejected({ id = 'free', a = 'weed', b = 'sandwich', result = 'brick', consumeA = 0, consumeB = 0 }, 'a recipe consuming nothing is rejected (explicit zeros)')
H.equal(combine.find('weed', 'sandwich'), nil, 'and it is not registered')
settings.recipes = { { a = 'rolling_paper', b = 'weed', result = 'joint', consumeA = 0, consumeB = 0, time = 0, label = 'Free' } }
reset(stock())
H.equal(combine.find('rolling_paper', 'weed'), nil, 'a configured free recipe is dropped too')
local before = snapshotOf()
H.equal(go(1, 2), false, 'so a free item printer cannot be used')
H.ok(same(inv.items, before), 'and nothing changed')
H.ok(combine.register({ id = 'keepA', a = 'weed', b = 'sandwich', result = 'brick', consumeA = 1, consumeB = 0 }), 'consuming only the first item is fine')
H.ok(combine.register({ id = 'keepB', a = 'water_bottle', b = 'brick', result = 'joint', consumeA = 0, consumeB = 1 }), 'consuming only the second item is fine')
combine.remove('keepA'); combine.remove('keepB')
settings.recipes = { { a = 'rolling_paper', b = 'weed', result = 'joint', consumeA = 1, consumeB = 1, time = 0, label = 'Roll' } }

-- L1: spoiled / water damaged ingredients ---------------------------------------
reset(stock())
spoiled = { [2] = true }
before = snapshotOf()
local ok, err = go(1, 2)
H.equal(ok, false, 'a spoiled ingredient is refused')
H.equal(err, 'this item has spoiled', 'with the spoiled reason')
H.ok(same(inv.items, before), 'nothing is consumed or created')
H.equal(#progress.calls, 0, 'no progress bar was run')
H.equal(#creations, 0, 'and nothing was audited')
spoiled = { [1] = true }
H.equal(go(2, 1), false, 'the dragged slot is checked as well')
spoiled = {}

reset(stock())
inv.items[2].info = { waterDamaged = true }
before = snapshotOf()
ok, err = go(1, 2)
H.equal(ok, false, 'a water damaged ingredient is refused')
H.equal(err, 'this item is water damaged', 'with the water damage reason')
H.ok(same(inv.items, before), 'nothing is consumed or created')
reset(stock())
inv.items[1].info = { waterDamaged = true }
H.equal(go(1, 2), false, 'the first slot water damaged is refused too')

-- Spoiling while the bar runs is caught after the wait.
reset(stock())
settings.recipes = { { a = 'rolling_paper', b = 'weed', result = 'joint', consumeA = 1, consumeB = 1, time = 2500, label = 'Roll' } }
progress.onCall = function() spoiled = { [1] = true } end
before = snapshotOf()
ok, err = go(1, 2)
H.equal(ok, false, 'an ingredient that spoils during the bar is refused')
H.ok(same(inv.items, before), 'and nothing changed')
progress.onCall = nil
spoiled = {}
settings.recipes = { { a = 'rolling_paper', b = 'weed', result = 'joint', consumeA = 1, consumeB = 1, time = 0, label = 'Roll' } }

-- Normal path still works and is audited as an item creation (L3). -------------
reset(stock())
creations = {}
ok, err = go(1, 2)
H.equal(ok, true, 'fresh, dry ingredients still combine: ' .. tostring(err))
H.equal(#creations, 1, 'the combine result is recorded in the creation audit')
H.equal(creations[1].action, 'combine', 'with the combine action')
H.equal(creations[1].name, 'joint', 'for the created item')
H.equal(creations[1].amount, 1, 'and amount')
H.equal(creations[1].src, 7, 'for the player')
H.equal(creations[1].key, KEY, 'in their inventory')

-- A failed combine records nothing.
reset(stock())
creations = {}
failAddOnce = true
H.equal(go(1, 2), false, 'a combine whose result cannot be added fails')
H.equal(#creations, 0, 'and is not audited as a creation')

H.finish()
