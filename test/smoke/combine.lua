-- Drag-to-combine (server/combine.lua): recipe lookup, the `combine` intent
-- (amounts, capacity, progress bar, mid-use lock, slot re-validation, rollback)
-- and the registerCombination / removeCombination exports. An in-memory player
-- inventory stands in for server.lua's authority; nothing needs FXServer.
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
dofile('server/combine.lua')
local combine = KoraInventory.combine

local function intent(payload, extra)
    local request = { token = TOKEN, action = 'combine', payload = payload, primaryRevision = revision }
    for key, value in pairs(extra or {}) do request[key] = value end
    return combine.intent(7, request)
end
local function go(from, to, extra)
    return intent({ inventory = KEY, fromSlot = from, toSlot = to, revision = revision }, extra)
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
local function noBusy() for _ in pairs(busy) do return false end return true end

-- ---------------------------------------------------------------- defaults
H.equal(settings.enabled, true, 'combine is on by default')
H.equal(settings.progress, true, 'with the progress bar on')
H.equal(#settings.recipes, 1, 'one shipped recipe')
H.equal(settings.recipes[1].result, 'joint', 'rolling paper + weed make a joint')
H.equal(exported.registerCombination, combine.register, 'registerCombination is exported')
H.equal(exported.removeCombination, combine.remove, 'removeCombination is exported')

-- ---------------------------------------------------------------- lookup
local recipe = combine.find('rolling_paper', 'weed')
H.ok(recipe, 'the shipped pair is found')
H.equal(recipe.result, 'joint', 'with its result')
H.equal(recipe.consumeFrom, 1, 'and what the dragged item costs')
H.ok(combine.find('weed', 'rolling_paper'), 'a + b is the same recipe as b + a')
H.ok(combine.find('WEED', 'Rolling_Paper'), 'names are matched case-insensitively')
H.equal(combine.find('weed', 'water_bottle'), nil, 'an unknown pair has no recipe')
H.equal(combine.find('weed', 'weed'), nil, 'an item has no recipe with itself unless one is defined')
H.equal(combine.find(nil, 'weed'), nil, 'missing names never match')
H.equal(combine.find({}, 'weed'), nil, 'non-string names never match')

H.ok(combine.register({ id = 'asym', a = 'water_bottle', b = 'sandwich', result = 'brick', consumeA = 2, consumeB = 1, time = 0, label = 'Weigh down' }), 'a runtime recipe registers')
local forward, reverse = combine.find('water_bottle', 'sandwich'), combine.find('sandwich', 'water_bottle')
H.equal(forward.consumeFrom, 2, 'the dragged item pays its own side')
H.equal(forward.consumeTo, 1, 'the target pays the other')
H.equal(reverse.consumeFrom, 1, 'dragged the other way the costs follow the items')
H.equal(reverse.consumeTo, 2, 'not the drag order')
H.ok(combine.remove('asym'), 'it can be removed again')
H.equal(combine.find('water_bottle', 'sandwich'), nil, 'and is gone')

-- ---------------------------------------------------------------- success
reset(stock())
local ok, err = go(1, 2)
H.equal(ok, true, 'combining rolling paper onto weed succeeds: ' .. tostring(err))
H.equal(#progress.calls, 1, 'the client progress bar ran once')
H.equal(progress.calls[1].name, 'kora_inventory:client:combineProgress', 'through the combine progress callback')
H.equal(progress.calls[1].payload.time, 2500, 'for the recipe time')
H.equal(progress.calls[1].payload.label, 'Roll a joint', 'with the recipe label')
H.equal(inv.items[1].amount, 2, 'one paper was used')
H.equal(inv.items[2].amount, 1, 'one weed was used')
local joint
for _, item in pairs(inv.items) do if item.name == 'joint' then joint = item end end
H.ok(joint and joint.amount == 1, 'a joint was added')
H.equal(audit[#audit].action, 'combine', 'the combine is audited')
H.equal(audit[#audit].details.result, 'joint', 'with its result')
H.equal(#itemBoxes, 1, 'and the player gets a receipt')
H.ok(noBusy(), 'the slots are released afterwards')
H.equal(revision, 2, 'the inventory revision advanced once')

reset(stock())
ok = go(2, 1)
H.equal(ok, true, 'dragging the weed onto the paper works the same')
H.equal(inv.items[1].amount, 2, 'paper used')
H.equal(inv.items[2].amount, 1, 'weed used')

-- a whole stack consumed frees its slot for the result
reset({ [1] = { slot = 1, name = 'rolling_paper', amount = 1, info = {} }, [2] = { slot = 2, name = 'weed', amount = 1, info = {} } })
H.equal(go(1, 2), true, 'consuming both whole stacks works')
H.equal(inv.items[2], nil, 'the emptied slot is cleared')
H.equal(inv.items[1].name, 'joint', 'and the joint takes the first free slot')

-- ---------------------------------------------------------------- client claims are ignored
reset(stock())
ok = intent({ inventory = KEY, fromSlot = 1, toSlot = 2, revision = revision, recipe = { result = 'brick', amount = 99 }, result = 'brick', amount = 99, consume = 0, time = 0 })
H.equal(ok, true, 'extra client fields do not break the request')
local gotBrick
for _, item in pairs(inv.items) do if item.name == 'brick' then gotBrick = true end end
H.equal(gotBrick, nil, 'but a client-named result is never used')
H.equal(inv.items[1].amount, 2, 'the server recipe decided the cost')

-- ---------------------------------------------------------------- bad requests
reset(stock())
local before = snapshotOf()
H.equal(go(1, 1), false, 'a slot onto itself is refused')
H.equal(go(1, 3), false, 'an empty target slot is refused')
H.equal(go(3, 1), false, 'an empty source slot is refused')
H.equal(go(0, 2), false, 'slot 0 is refused')
H.equal(go(1, 99), false, 'a slot beyond the inventory is refused')
H.equal(go(1.5, 2), false, 'a fractional slot is refused')
H.equal(go('1', 2), true, 'a numeric string slot is read as a number')
reset(stock())
H.equal(go(1, 4), false, 'a pair with no recipe is refused')
H.equal(intent({ inventory = 'stash:other', fromSlot = 1, toSlot = 2, revision = revision }), false, 'another inventory is refused')
H.equal(intent({ fromSlot = 1, toSlot = 2 }, { primaryRevision = false }), false, 'a request with no revision is refused')
H.equal(intent({ inventory = KEY, fromSlot = 1, toSlot = 2, revision = revision - 1 }), false, 'a stale revision is refused')
H.equal(intent(nil), false, 'a missing payload is refused')
H.equal(combine.intent(7, { token = 'bad', action = 'combine', payload = { fromSlot = 1, toSlot = 2, revision = revision } }), false, 'a wrong session token is refused')
sessionOpen = false
H.equal(go(1, 2), false, 'no session is refused')
sessionOpen = true
H.ok(same(before, snapshotOf()), 'none of these changed the inventory')
H.equal(#progress.calls, 0, 'and none started a progress bar')

-- ---------------------------------------------------------------- amounts
reset(stock())
settings.recipes = { { a = 'rolling_paper', b = 'weed', result = 'joint', consumeA = 4, consumeB = 1, time = 0, label = 'Roll a joint' } }
before = snapshotOf()
local refused, why = go(1, 2)
H.equal(refused, false, 'needing more than the stack holds is refused')
H.equal(why, 'not enough items', 'with a clear reason')
H.ok(same(before, snapshotOf()), 'and nothing is consumed')
settings.recipes = { { a = 'rolling_paper', b = 'weed', result = 'joint', consumeA = 3, consumeB = 2, amount = 2, time = 0, label = 'Roll two' } }
H.equal(go(1, 2), true, 'using exactly the stacks is allowed')
local totalJoints, leftover = 0, 0
for _, item in pairs(inv.items) do
    if item.name == 'joint' then totalJoints = totalJoints + item.amount end
    if item.name == 'rolling_paper' or item.name == 'weed' then leftover = leftover + 1 end
end
H.equal(leftover, 0, 'both stacks are gone')
H.equal(totalJoints, 2, 'and the recipe amount is given')
H.equal(#progress.calls, 0, 'time 0 never shows a bar')

-- a tool that is kept
reset(stock())
settings.recipes = { { a = 'rolling_paper', b = 'weed', result = 'joint', consumeA = 0, consumeB = 1, time = 0, label = 'Roll' } }
H.equal(go(1, 2), true, 'consumeA = 0 keeps the first item')
H.equal(inv.items[1].amount, 3, 'the paper is untouched')
H.equal(inv.items[2].amount, 1, 'the weed is used')

-- ---------------------------------------------------------------- capacity
reset(stock())
settings.recipes = { { a = 'rolling_paper', b = 'weed', result = 'brick', consumeA = 1, consumeB = 1, time = 0, label = 'Too heavy' } }
before = snapshotOf()
refused, why = go(1, 2)
H.equal(refused, false, 'a result that does not fit is refused')
H.equal(why, 'over weight', 'because of its weight')
H.ok(same(before, snapshotOf()), 'and the inventory is left exactly as it was')
H.ok(inv.items[1].amount == 3 and inv.items[2].amount == 2, 'both stacks are restored in their own slots')
H.equal(#audit, 0, 'a failed combine is not audited as a success')
H.ok(noBusy(), 'the slots are released')

-- an injected failure on the final add rolls back both removals
reset(stock())
settings.recipes = { { a = 'rolling_paper', b = 'weed', result = 'joint', consumeA = 3, consumeB = 2, time = 0, label = 'Roll' } }
before = snapshotOf()
failAddOnce = true
H.equal(go(1, 2), false, 'a failing add is reported')
H.ok(same(before, snapshotOf()), 'and the whole stacks are put back')

-- no free slot
reset({
    [1] = { slot = 1, name = 'rolling_paper', amount = 3, info = {} },
    [2] = { slot = 2, name = 'weed', amount = 2, info = {} },
    [3] = { slot = 3, name = 'water_bottle', amount = 1, info = {} },
    [4] = { slot = 4, name = 'sandwich', amount = 1, info = {} },
    [5] = { slot = 5, name = 'joint', amount = 1, info = { quality = 1 } },
})
settings.recipes = { { a = 'rolling_paper', b = 'weed', result = 'joint', consumeA = 1, consumeB = 1, time = 0, label = 'Roll' } }
before = snapshotOf()
H.equal(go(1, 2), false, 'no free slot for the result is refused')
H.ok(same(before, snapshotOf()), 'and nothing changes')

-- the early capacity answer comes before the player waits through the bar
reset(stock())
settings.recipes = { { a = 'rolling_paper', b = 'weed', result = 'joint', time = 2500, label = 'Roll a joint' } }
KoraInventory.crafting = { canCraftItems = function() return false, 'over weight' end }
H.equal(go(1, 2), false, 'the crafting capacity check can refuse up front')
H.equal(#progress.calls, 0, 'before any progress bar starts')
local sawNeeded
KoraInventory.crafting = { canCraftItems = function(_, needed, outputs) sawNeeded = { needed, outputs } return true end }
H.equal(go(1, 2), true, 'and allows the combine when it fits')
H.equal(sawNeeded[1][1].name, 'rolling_paper', 'asking about the first ingredient')
H.equal(sawNeeded[1][2].amount, 1, 'and the second with its amount')
H.equal(sawNeeded[2][1].name, 'joint', 'and the result')
KoraInventory.crafting = nil

-- ---------------------------------------------------------------- progress bar
settings.recipes = { { a = 'rolling_paper', b = 'weed', result = 'joint', consumeA = 1, consumeB = 1, time = 2500, label = 'Roll a joint' } }
reset(stock())
before = snapshotOf()
progress.answer = false
H.equal(go(1, 2), false, 'a cancelled bar combines nothing')
H.ok(same(before, snapshotOf()), 'and consumes nothing')
H.ok(noBusy(), 'and releases the slots')
progress.answer = 'error'
H.equal(go(1, 2), false, 'a client that never answers combines nothing')
H.ok(same(before, snapshotOf()), 'and consumes nothing')
H.ok(noBusy(), 'and releases the slots')
progress.answer, progress.elapsed = true, 10
H.equal(go(1, 2), false, 'an instant answer (faster than the bar) is ignored')
H.ok(same(before, snapshotOf()), 'and consumes nothing')
progress.elapsed = nil

-- slots are locked while the bar runs
local midBusy
progress.onCall = function() midBusy = { busy[1], busy[2], busy[3] } end
H.equal(go(1, 2), true, 'a normal combine succeeds')
H.ok(midBusy[1] and midBusy[2] and not midBusy[3], 'both slots are locked during the bar and only those')
H.ok(noBusy(), 'and released after')

-- a second combine while one is running is refused
reset(stock())
local nested
progress.onCall = function() nested = { go(1, 2) } end
H.equal(go(1, 2), true, 'the first combine completes')
H.equal(nested[1], false, 'a second one started during the bar is refused')
H.equal(nested[2], 'item is currently being used', 'as busy')
H.equal(busyNotices, 1, 'with the busy notice')
progress.onCall = nil

-- slots busy from a use handler
reset(stock())
busy[1] = true
H.equal(go(1, 2), false, 'a slot locked by a use in progress is refused')
busy[1] = nil
busy[2] = true
H.equal(go(1, 2), false, 'on either side')
busy[2] = nil

-- the slots changed while the bar ran
local function changeDuring(mutate)
    reset(stock())
    local snap
    progress.onCall = function() mutate() end
    local result = go(1, 2)
    progress.onCall = nil
    return result
end
H.equal(changeDuring(function() inv.items[2] = { slot = 2, name = 'sandwich', amount = 1, info = {} } end), false, 'the target replaced during the bar is refused')
H.equal(inv.items[1].amount, 3, 'and the paper is untouched')
H.equal(changeDuring(function() inv.items[1] = nil end), false, 'the source dropped during the bar is refused')
H.equal(changeDuring(function() inv.items[2].amount = 0 end), false, 'a stack that fell below the cost is refused')
H.equal(changeDuring(function() inv.items[1].info = { quality = 5 } end), false, 'a changed item (metadata) is refused')
H.equal(changeDuring(function() revision = revision + 5 end), true, 'unrelated inventory changes (revision) do not cancel it')
sessionOpen = true
reset(stock())
progress.onCall = function() sessionOpen = false end
H.equal(go(1, 2), false, 'a session closed during the bar is refused')
progress.onCall = nil
sessionOpen = true
H.equal(inv.items[1].amount, 3, 'and nothing was used')

-- progress switched off: instant even with a time
reset(stock())
settings.progress = false
H.equal(go(1, 2), true, 'progress = false combines immediately')
H.equal(#progress.calls, 0, 'with no bar')
settings.progress = true

-- ---------------------------------------------------------------- disabled
reset(stock())
settings.enabled = false
before = snapshotOf()
refused, why = go(1, 2)
H.equal(refused, false, 'a disabled feature refuses the intent')
H.equal(why, 'combining is disabled', 'saying so')
H.equal(combine.find('rolling_paper', 'weed'), nil, 'and finds no recipes')
H.ok(same(before, snapshotOf()), 'and changes nothing')
H.equal(#progress.calls, 0, 'and shows no bar')
settings.enabled = true

-- ---------------------------------------------------------------- exports
settings.recipes = { { a = 'rolling_paper', b = 'weed', result = 'joint', time = 0 } }
invoking = 'res_a'
local function rejected(recipeValue, message)
    local registered, reason = combine.register(recipeValue)
    H.equal(registered, false, message)
    H.equal(type(reason), 'string', message .. ' (with a reason)')
end
rejected(nil, 'a nil recipe is rejected')
rejected('weed', 'a non-table is rejected')
rejected({}, 'an empty recipe is rejected')
rejected({ a = 'weed', b = 'sandwich' }, 'a missing result is rejected')
rejected({ a = 'weed', result = 'brick' }, 'a missing second item is rejected')
rejected({ a = 'weed', b = 'nope', result = 'brick' }, 'an unknown ingredient is rejected')
rejected({ a = 'weed', b = 'sandwich', result = 'nope' }, 'an unknown result is rejected')
rejected({ a = 'weed', b = 'sandwich', result = 'brick', amount = 0 }, 'amount 0 is rejected')
rejected({ a = 'weed', b = 'sandwich', result = 'brick', amount = 1.5 }, 'a fractional amount is rejected')
rejected({ a = 'weed', b = 'sandwich', result = 'brick', consumeA = -1 }, 'a negative cost is rejected')
rejected({ a = 'weed', b = 'sandwich', result = 'brick', consumeB = '1' }, 'a string cost is rejected')
rejected({ a = 'weed', b = 'sandwich', result = 'brick', time = -5 }, 'a negative time is rejected')
rejected({ a = 'weed', b = 'sandwich', result = 'brick', time = 20001 }, 'an absurd time is rejected')
rejected({ a = 'weed', b = 'sandwich', result = 'brick', label = 12 }, 'a non-string label is rejected')
rejected({ a = 'weed', b = 'sandwich', result = 'brick', job = 'police' }, 'an unsupported field (job) is rejected, not silently ignored')
rejected({ a = 'weed', b = 'sandwich', result = 'brick', id = 'bad id!' }, 'a malformed id is rejected')
rejected({ a = 'weed', b = 'sandwich', result = 'brick', id = 12 }, 'a non-string id is rejected')
rejected({ a = 'rolling_paper', b = 'weed', result = 'brick' }, 'a pair already defined in config is rejected')
rejected({ a = 'weed', b = 'rolling_paper', result = 'brick' }, 'in either order')
rejected({ a = 'weed', b = 'sandwich', result = 'brick', id = 'config:1' }, 'the config id namespace is reserved')

local registered, id = combine.register({ id = 'pair-one', a = 'weed', b = 'sandwich', result = 'brick', time = 0, label = 'Wrap' })
H.equal(registered, true, 'a valid recipe registers')
H.equal(id, 'pair-one', 'and returns its id')
rejected({ id = 'pair-one', a = 'water_bottle', b = 'brick', result = 'joint' }, 'a duplicate id is rejected')
rejected({ a = 'sandwich', b = 'weed', result = 'joint' }, 'a duplicate pair (reversed) is rejected')
local generated, generatedId = combine.register({ a = 'water_bottle', b = 'brick', result = 'joint' })
H.equal(generated, true, 'an id is optional')
H.equal(generatedId, 'brick+water_bottle', 'and defaults to the sorted pair')
H.equal(combine.find('brick', 'water_bottle').label, 'Combine', 'with the default label')
H.equal(combine.find('brick', 'water_bottle').time, 0, 'and instant time')

local list = combine.presentation()
H.equal(#list, 3, 'the presentation list holds config and registered pairs')
H.equal(list[1].a, 'rolling_paper', 'config pairs first')
for _, row in ipairs(list) do
    local fields = 0
    for _ in pairs(row) do fields = fields + 1 end
    H.equal(fields, 3, 'rows carry only a, b and label')
end
H.equal(#combine.presentation(true), 2, 'registeredOnly lists just runtime recipes')

invoking = 'res_b'
local denied, deniedWhy = combine.remove('pair-one')
H.equal(denied, false, 'another resource cannot remove it')
H.equal(deniedWhy, 'not combination owner', 'saying so')
H.equal(combine.remove('config:1'), false, 'config recipes cannot be removed through the export')
H.equal(combine.remove('missing'), false, 'unknown ids are refused')
H.equal(combine.remove(42), false, 'non-string ids are refused')
invoking = 'res_a'
H.equal(combine.remove('pair-one'), true, 'the owner removes it')
H.equal(combine.find('weed', 'sandwich'), nil, 'and it stops matching')
H.equal(combine.register({ id = 'pair-one', a = 'weed', b = 'sandwich', result = 'brick' }), true, 'its id and pair can be registered again')

-- stopping the owner removes its recipes
handlers.onResourceStop('res_a')
H.equal(combine.find('weed', 'sandwich'), nil, 'a stopped resource takes its recipes with it')
H.equal(combine.find('brick', 'water_bottle'), nil, 'all of them')
H.ok(combine.find('rolling_paper', 'weed'), 'config recipes stay')

-- a registered recipe works through the intent
invoking = 'res_c'
H.ok(combine.register({ a = 'water_bottle', b = 'sandwich', result = 'joint', consumeA = 1, consumeB = 1, time = 0, label = 'Mix' }), 'runtime recipe added')
reset(stock())
inv.items[5] = { slot = 5, name = 'sandwich', amount = 1, info = {} }
H.equal(go(5, 4), true, 'a registered recipe combines through the intent')
H.equal(audit[#audit].action, 'combine', 'and is audited')

-- an invalid config row is skipped without hiding the others
settings.recipes = { { a = 'weed' }, { a = 'rolling_paper', b = 'weed', result = 'joint', job = 'x' }, { a = 'weed', b = 'sandwich', result = 'joint', time = 0 } }
H.equal(combine.find('rolling_paper', 'weed'), nil, 'a config row with an unsupported field is ignored')
H.ok(combine.find('weed', 'sandwich'), 'a later valid row still works')
H.ok(#logs > 0, 'and the bad rows are reported')

-- ---------------------------------------------------------------- /config schema
do
    local seen = {}
    local function descriptor(kind)
        return function(value, options)
            local node = { kind = kind, value = value, options = options }
            seen[#seen + 1] = node
            return node
        end
    end
    local savedKora = Kora
    Config = { kora_inventory = { combine = { enabled = true, progress = true, recipes = {} } } }
    Kora = setmetatable({ config = {
        adopt = function() end,
        boolean = descriptor('boolean'),
        string = descriptor('string'),
        integer = descriptor('integer'),
        object = function(fields, options) return { kind = 'object', fields = fields, options = options } end,
        list = function(value, item, options) return { kind = 'list', value = value, item = item, options = options } end,
    } }, { __index = savedKora })
    dofile('config/schema/combine.lua')
    local schema = Config.kora_inventory.combine
    H.equal(schema.enabled.kind, 'boolean', 'the schema registers the master switch')
    H.equal(schema.enabled.options.live, true, 'which is live')
    H.equal(schema.progress.options.scope, 'server', 'progress is server-scoped')
    H.equal(schema.recipes.kind, 'list', 'recipes are an editable list')
    H.equal(schema.recipes.item.kind, 'object', 'of objects')
    for _, field in ipairs({ 'a', 'b', 'result', 'amount', 'consumeA', 'consumeB', 'time', 'label' }) do
        H.ok(schema.recipes.item.fields[field], 'with a ' .. field .. ' field')
        H.ok(schema.recipes.item.fields[field].options.label, field .. ' has a label')
        H.ok(schema.recipes.item.fields[field].options.description, field .. ' has a description')
    end
    Kora = savedKora
end

-- ---------------------------------------------------------------- client bridge
do
    local function read(path)
        local file = assert(io.open(path, 'r'))
        local text = file:read('*a')
        file:close()
        return text
    end
    local ui, client, manifest = read('client/ui.lua'), read('client.lua'), read('fxmanifest.lua')
    H.ok(ui:find("combine = true,", 1, true), 'the NUI bridge allows the combine intent')
    H.ok(ui:find("combine = KoraInventory.combinePresentation", 1, true), 'the recipe presentation list is pushed in the NUI config')
    H.ok(ui:find("'combine', 'combine_title', 'combine_items'", 1, true), 'the popover text keys are pushed to the page')
    H.ok(ui:find("data.intent ~= 'use' and data.intent ~= 'combine'", 1, true), 'a combine waiting on its progress bar is not timed out like a move')
    H.ok(client:find("action == 'combine'", 1, true), 'the client transport forwards combine to the server intent path')
    H.ok(manifest:find("'server/combine.lua'", 1, true) and manifest:find("'client/combine.lua'", 1, true), 'both halves are in the manifest')

    local netEvents, callbacks, started = {}, {}, {}
    Config = { kora_inventory = { combine = {
        enabled = true,
        recipes = {
            { a = 'rolling_paper', b = 'weed', result = 'joint', amount = 9, consumeA = 1, time = 100, label = 'Roll a joint' },
            { a = 'bad' },
        },
    } } }
    local savedKora = Kora
    local completes, ped = true, 1
    Kora = {
        callback = {
            register = function(name, fn) callbacks[name] = fn end,
            trigger = function() return {} end,
        },
        cache = { ped = function() return ped end },
        progressbar = { start = function(payload) started[#started + 1] = payload return completes end },
        lang = function(key) return key end,
    }
    RegisterNetEvent = function(name, fn) netEvents[name] = fn end
    CreateThread = function(fn) fn() end
    IsPedDeadOrDying = function() return false end
    KoraInventory = {}
    dofile('client/combine.lua')

    local list = KoraInventory.combinePresentation()
    H.equal(list.enabled, true, 'the page is told combining is on')
    H.equal(#list.recipes, 1, 'a malformed recipe row is not sent')
    local fields = 0
    for key in pairs(list.recipes[1]) do fields = fields + 1 end
    H.equal(fields, 3, 'rows carry names and a label only, never amounts or results')
    H.equal(list.recipes[1].label, 'Roll a joint', 'with the label')

    invoking = 'some_resource'
    netEvents['kora_inventory:client:combinations']({ { a = 'cheat', b = 'cheat2', label = 'Local trigger' } })
    H.equal(#KoraInventory.combinePresentation().recipes, 1, 'a local (non-network) trigger cannot add recipes')
    invoking = nil
    netEvents['kora_inventory:client:combinations']({ { a = 'repairkit', b = 'electronickit', label = 'Upgrade' }, 'junk', { a = 1 } })
    list = KoraInventory.combinePresentation()
    H.equal(#list.recipes, 2, 'recipes other resources registered are added')
    H.equal(list.recipes[2].a, 'repairkit', 'after the config ones')
    Config.kora_inventory.combine.enabled = false
    H.equal(KoraInventory.combinePresentation().enabled, false, 'a live config change is picked up on the next push')

    local bar = callbacks['kora_inventory:client:combineProgress']
    H.equal(bar({ time = 2500, label = 'Roll a joint' }), true, 'a finished bar reports true')
    H.equal(started[1].duration, 2500, 'for the duration the server asked')
    H.equal(started[1].label, 'Roll a joint', 'with the server label')
    completes = false
    H.equal(bar({ time = 2500, label = 'x' }), false, 'a cancelled bar reports false')
    H.equal(bar({ time = 0 }), true, 'no time means no bar')
    Kora = savedKora
end

H.finish()
