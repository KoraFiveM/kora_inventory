-- Sort / Stack all planning (shared/organize.lua) is pure, so every promise the
-- feature makes is proved here without FXServer: no item is created or
-- destroyed, unique items and different metadata never merge, the hotbar stays
-- put, ordering is stable, and edge inventories behave.
local H = dofile('test/harness.lua')

local function read(path)
    local file = assert(io.open(path, 'r'))
    local text = file:read('*a')
    file:close()
    return text
end

KoraInventory = nil
dofile('shared/organize.lua')
local organize = KoraInventory.organize
H.ok(type(organize) == 'table' and type(organize.plan) == 'function', 'planner is exposed on KoraInventory.organize')

local function item(name, amount, info, extra)
    local value = { name = name, label = name, amount = amount, info = info or {}, unique = false, type = 'item' }
    for key, field in pairs(extra or {}) do value[key] = field end
    return value
end
local function put(items, slot, value)
    value.slot = slot
    items[slot] = value
    return value
end

-- A stable, readable key for "name + metadata" so totals can be compared.
local infoKey
function infoKey(info)
    local keys = {}
    for key in pairs(info or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        local value = info[key]
        parts[#parts + 1] = key .. '=' .. (type(value) == 'table' and ('{' .. infoKey(value) .. '}') or tostring(value))
    end
    return table.concat(parts, ',')
end
local function totals(items)
    local out = {}
    for _, value in pairs(items) do
        local key = value.name .. '|' .. infoKey(value.info) .. '|' .. (value.unique and ('u' .. tostring(value.info and value.info.serial or value.label)) or '')
        out[key] = (out[key] or 0) + value.amount
    end
    return out
end
local function sameTotals(left, right, message)
    for key, amount in pairs(left) do H.equal(right[key], amount, (message or 'total') .. ' kept: ' .. key) end
    for key, amount in pairs(right) do H.equal(left[key], amount, (message or 'total') .. ' not invented: ' .. key) end
end
local function count(items)
    local n = 0
    for _ in pairs(items) do n = n + 1 end
    return n
end
local function plan(items, slots, mode, opts)
    local result, err = organize.plan(items, slots, mode, opts)
    H.ok(result, 'plan succeeds: ' .. tostring(err))
    return result
end

local ORDER = { 'weapon', 'ammo', 'useable', 'other' }
local function snapshot(items)
    return KoraInventory.copy and KoraInventory.copy(items) or items
end

-- 1. stack: partial stacks of one item merge into the lowest slot.
do
    local items = {}
    put(items, 3, item('bandage', 2))
    put(items, 7, item('bandage', 3))
    put(items, 9, item('bandage', 5))
    local before = totals(items)
    local result = plan(items, 20, 'stack')
    sameTotals(before, totals(result.items), 'stack')
    H.equal(count(result.items), 1, 'three partial stacks become one')
    H.equal(result.items[3].amount, 10, 'merged into the lowest slot')
    H.equal(result.items[3].slot, 3, 'merged item reports its slot')
    H.ok(result.changed, 'a merge is a change')
    H.equal(items[7].amount, 3, 'the input table is never modified')
    H.ok(items[9] ~= nil and items[3].amount == 2, 'inputs untouched')
end

-- 2. unique items are never merged, even with identical metadata.
do
    local items = {}
    put(items, 1, item('weapon_pistol', 1, { serial = 'A' }, { unique = true, type = 'weapon' }))
    put(items, 2, item('weapon_pistol', 1, { serial = 'A' }, { unique = true, type = 'weapon' }))
    put(items, 4, item('weapon_pistol', 1, {}, { unique = true, type = 'weapon' }))
    put(items, 5, item('weapon_pistol', 1, {}, { unique = true, type = 'weapon' }))
    local result = plan(items, 10, 'stack')
    H.equal(count(result.items), 4, 'unique items stay separate')
    for slot = 1, 5 do
        if items[slot] then H.equal(result.items[slot].amount, 1, 'unique item keeps amount 1 at slot ' .. slot) end
    end
    H.ok(not result.changed, 'nothing to stack means no change')
    local sorted = plan(items, 10, 'sort', { keepSlots = 0, order = ORDER })
    H.equal(count(sorted.items), 4, 'sort keeps every unique item')
end

-- 3. different metadata never merges; nested metadata compares by content.
do
    local items = {}
    put(items, 1, item('water', 2, { quality = 100 }))
    put(items, 2, item('water', 2, { quality = 50 }))
    put(items, 3, item('water', 2, { quality = 100 }))
    put(items, 4, item('sandwich', 1, { nested = { a = 1 } }))
    put(items, 5, item('sandwich', 1, { nested = { a = 1 } }))
    put(items, 6, item('sandwich', 1, { nested = { a = 2 } }))
    put(items, 7, item('water', 1, nil))
    local before = totals(items)
    local result = plan(items, 12, 'stack')
    sameTotals(before, totals(result.items), 'metadata')
    H.equal(result.items[1].amount, 4, 'matching metadata merged into slot 1')
    H.equal(result.items[2].amount, 2, 'different metadata stays in its own stack')
    H.equal(result.items[4].amount, 2, 'equal nested metadata merges')
    H.equal(result.items[6].amount, 1, 'different nested metadata does not merge')
    H.equal(result.items[7].amount, 1, 'no-metadata stack is its own group')
    H.equal(result.items[3], nil, 'emptied slot is cleared')
    H.equal(result.items[5], nil, 'emptied slot is cleared (nested)')
end

-- 4. max stack sizes are respected and totals survive the split.
do
    local items = {}
    put(items, 2, item('ammo_9', 60))
    put(items, 4, item('ammo_9', 70))
    put(items, 5, item('ammo_9', 90))
    local before = totals(items)
    local result = plan(items, 10, 'stack', { maxStack = function() return 100 end })
    sameTotals(before, totals(result.items), 'maxStack')
    H.equal(result.items[2].amount, 100, 'first stack filled to the cap')
    H.equal(result.items[4].amount, 100, 'second stack filled to the cap')
    H.equal(result.items[5].amount, 20, 'remainder stays in the last stack')
    for _, value in pairs(result.items) do H.ok(value.amount <= 100, 'no stack above the cap') end
    -- Stacks already above a (later lowered) cap are left alone, never trimmed.
    local capped = plan(items, 10, 'stack', { maxStack = function() return 2 end })
    sameTotals(before, totals(capped.items), 'tiny cap')
    H.ok(not capped.changed, 'a group that cannot fit under the cap is left as it is')
    -- Under the cap, small stacks still merge as far as the cap allows.
    local small = {}
    put(small, 1, item('pill', 1))
    put(small, 2, item('pill', 1))
    put(small, 3, item('pill', 1))
    local limited = plan(small, 6, 'stack', { maxStack = function() return 2 end })
    H.equal(limited.items[1].amount, 2, 'filled to a cap of 2')
    H.equal(limited.items[2].amount, 1, 'remainder in the next slot')
    H.equal(limited.items[3], nil, 'third slot emptied')
end

-- 5. sort: category order, then label (case-insensitive), then name, then slot.
do
    local items = {}
    put(items, 1, item('zzz', 1, {}, { label = 'Zebra', useable = true }))
    put(items, 2, item('weapon_bat', 1, {}, { label = 'bat', unique = true, type = 'weapon' }))
    put(items, 3, item('rock', 1, {}, { label = 'Apple' }))
    put(items, 4, item('ammo_9', 5, {}, { label = 'Pistol ammo', type = 'ammo' }))
    put(items, 5, item('aaa', 1, {}, { label = 'apple' }))
    put(items, 6, item('weapon_knife', 1, {}, { label = 'Knife', unique = true, type = 'weapon' }))
    put(items, 7, item('bandage', 1, {}, { label = 'Bandage', useable = true }))
    local result = plan(items, 10, 'sort', { keepSlots = 0, order = ORDER })
    local expected = { 'weapon_bat', 'weapon_knife', 'ammo_9', 'bandage', 'zzz', 'aaa', 'rock' }
    for slot, name in ipairs(expected) do
        H.equal(result.items[slot] and result.items[slot].name, name, 'sorted slot ' .. slot)
        H.equal(result.items[slot].slot, slot, 'sorted item reports slot ' .. slot)
    end
    H.equal(count(result.items), 7, 'sort keeps every item')
    H.equal(result.items[8], nil, 'sort closes gaps at the end')
    -- 'aaa' (slot 5) and 'rock' (slot 3) share the label "apple": name breaks the tie.
    -- A custom order is honoured, and an unlisted category sorts last.
    local reversed = plan(items, 10, 'sort', { order = { 'other', 'useable' } })
    H.equal(reversed.items[1].name, 'aaa', 'custom order puts other first')
    H.equal(reversed.items[#expected].type == 'ammo' or reversed.items[#expected].type == 'weapon', true, 'unlisted categories sort last')
end

-- 6. sort is stable: same category, label and name keep their original order.
do
    local items = {}
    put(items, 2, item('coin', 1, { id = 'second' }, { unique = true }))
    put(items, 5, item('coin', 1, { id = 'fifth' }, { unique = true }))
    put(items, 3, item('coin', 1, { id = 'third' }, { unique = true }))
    local result = plan(items, 8, 'sort', { order = ORDER })
    H.equal(result.items[1].info.id, 'second', 'stable order 1')
    H.equal(result.items[2].info.id, 'third', 'stable order 2')
    H.equal(result.items[3].info.id, 'fifth', 'stable order 3')
    local again = plan(result.items, 8, 'sort', { order = ORDER })
    H.ok(not again.changed, 'sorting a sorted inventory is a no-op')
    -- metadata label wins over the definition label
    local labelled = {}
    put(labelled, 1, item('x', 1, { label = 'Beta' }, { label = 'Zzz', unique = true }))
    put(labelled, 2, item('y', 1, { label = 'Alpha' }, { label = 'Zzz', unique = true }))
    local sortedLabels = plan(labelled, 4, 'sort', { order = ORDER })
    H.equal(sortedLabels.items[1].name, 'y', 'metadata label is what sorts')
end

-- 7. hotbar: slots 1..keepSlots are never moved or emptied.
do
    local items = {}
    put(items, 1, item('weapon_pistol', 1, { serial = 'S1' }, { unique = true, type = 'weapon' }))
    put(items, 3, item('radio', 1, {}, { useable = true, unique = true }))
    put(items, 4, item('water', 2))
    put(items, 8, item('apple', 1))
    put(items, 6, item('weapon_bat', 1, {}, { unique = true, type = 'weapon', label = 'Bat' }))
    put(items, 12, item('water', 3))
    local before = totals(items)
    local result = plan(items, 20, 'sort', { keepSlots = 5, order = ORDER })
    sameTotals(before, totals(result.items), 'hotbar sort')
    H.equal(result.items[1].name, 'weapon_pistol', 'hotbar slot 1 untouched')
    H.equal(result.items[1].info.serial, 'S1', 'hotbar weapon serial untouched')
    H.equal(result.items[3].name, 'radio', 'hotbar slot 3 untouched')
    H.equal(result.items[2], nil, 'empty hotbar slot stays empty')
    H.equal(result.items[5], nil, 'empty hotbar slot 5 stays empty')
    H.equal(result.items[4].name, 'water', 'hotbar stack stays in slot 4')
    H.equal(result.items[4].amount, 5, 'matching loose stack merged INTO the hotbar stack')
    H.equal(result.items[6].name, 'weapon_bat', 'items after the hotbar are sorted (weapon first)')
    H.equal(result.items[7].name, 'apple', 'then the rest')
    H.equal(result.items[8], nil, 'closed up')
    for slot = 1, 5 do
        if items[slot] then
            H.equal(result.items[slot].name, items[slot].name, 'hotbar identity kept at ' .. slot)
        end
    end
    -- stack mode with a hotbar leaves every position alone
    local stacked = plan(items, 20, 'stack', { keepSlots = 5 })
    H.equal(stacked.items[8].name, 'apple', 'stack mode never repositions')
    H.equal(stacked.items[6].name, 'weapon_bat', 'stack mode keeps slot 6')
    H.equal(stacked.items[4].amount, 5, 'stack mode merges into the hotbar stack')
    -- keepSlots larger than the inventory is clamped
    local clamped = plan(items, 20, 'sort', { keepSlots = 99 })
    H.equal(count(clamped.items), 6, 'a fully protected inventory is left exactly as it is')
    H.ok(not clamped.changed, 'and reports no change')
    H.equal(clamped.items[8].name, 'apple', 'fully protected inventory keeps positions')
end

-- 7b. two stacks of one item inside the hotbar are both left alone.
do
    local items = {}
    put(items, 1, item('water', 2))
    put(items, 2, item('water', 3))
    put(items, 9, item('water', 4))
    local result = plan(items, 12, 'stack', { keepSlots = 5 })
    H.equal(result.items[1].amount, 6, 'lowest hotbar stack receives the loose stack')
    H.equal(result.items[2].amount, 3, 'second hotbar stack is not emptied or changed')
    H.equal(result.items[9], nil, 'loose stack merged away')
end

-- 8. empty and full inventories.
do
    local empty = plan({}, 10, 'sort', { order = ORDER })
    H.equal(count(empty.items), 0, 'empty inventory stays empty')
    H.ok(not empty.changed, 'empty inventory is a no-op')
    H.ok(not plan({}, 10, 'stack').changed, 'empty stack is a no-op')

    local items = {}
    for slot = 1, 10 do
        put(items, slot, item('n' .. (11 - slot), 1, {}, { unique = true, label = 'Item ' .. string.format('%02d', 11 - slot) }))
    end
    local before = totals(items)
    local full = plan(items, 10, 'sort', { order = ORDER })
    sameTotals(before, totals(full.items), 'full inventory')
    H.equal(count(full.items), 10, 'a full inventory never exceeds its slots')
    for slot = 1, 10 do
        H.equal(full.items[slot].label, 'Item ' .. string.format('%02d', slot), 'full inventory sorted at ' .. slot)
    end
    -- a full inventory of partial stacks shrinks, never grows
    local partial = {}
    for slot = 1, 10 do put(partial, slot, item('bread', 1)) end
    local merged = plan(partial, 10, 'sort', { order = ORDER })
    H.equal(count(merged.items), 1, 'ten singles merge into one')
    H.equal(merged.items[1].amount, 10, 'with the right total')
end

-- 9. refusals: odd inventories are left alone rather than guessed at.
do
    local bad, err = organize.plan({ [11] = item('x', 1) }, 10, 'sort')
    H.equal(bad, nil, 'a slot beyond the inventory is refused')
    H.equal(err, 'invalid inventory', 'with a reason')
    H.equal((organize.plan({ [1] = item('x', 0) }, 10, 'sort')), nil, 'zero amount refused')
    H.equal((organize.plan({ [1] = item('x', 1.5) }, 10, 'sort')), nil, 'fractional amount refused')
    H.equal((organize.plan({ [1.5] = item('x', 1) }, 10, 'sort')), nil, 'fractional slot refused')
    H.equal((organize.plan({ [1] = { amount = 1 } }, 10, 'sort')), nil, 'nameless item refused')
    H.equal((organize.plan({}, 10, 'shuffle')), nil, 'unknown mode refused')
    H.equal((organize.plan({}, 0, 'sort')), nil, 'zero slots refused')
    H.equal((organize.plan(nil, 10, 'sort')), nil, 'nil items refused')
end

-- 10. fuzz: random inventories always keep every total and never exceed slots.
do
    local seed = 12345
    local function rand(n)
        seed = (seed * 1103515245 + 12345) % 2147483648
        return (seed % n) + 1
    end
    local names = { 'water', 'bread', 'ammo_9', 'radio', 'weapon_pistol', 'bandage' }
    for round = 1, 200 do
        local slots = 5 + rand(40)
        local items = {}
        for _ = 1, rand(slots) do
            local slot = rand(slots)
            if not items[slot] then
                local name = names[rand(#names)]
                local unique = name == 'weapon_pistol' or name == 'radio'
                put(items, slot, item(name, unique and 1 or rand(9), { quality = (rand(3) == 1) and 50 or nil, serial = unique and ('S' .. slot) or nil }, {
                    unique = unique, type = name:find('weapon') and 'weapon' or (name:find('ammo') and 'ammo' or 'item'),
                    useable = name == 'radio' or name == 'bandage',
                }))
            end
        end
        local before = totals(items)
        local keep = rand(6) - 1
        for _, mode in ipairs({ 'stack', 'sort' }) do
            local result = organize.plan(items, slots, mode, { keepSlots = keep, order = ORDER, maxStack = (round % 3 == 0) and function() return 7 end or nil })
            H.ok(result, 'fuzz plan ' .. round .. ' ' .. mode)
            local after = totals(result.items)
            -- Totals per name+metadata+serial are preserved (the cap only moves amounts between stacks).
            sameTotals(before, after, 'fuzz ' .. round .. ' ' .. mode)
            H.ok(count(result.items) <= count(items), 'never more slots used')
            for slot, value in pairs(result.items) do
                H.ok(slot >= 1 and slot <= slots, 'inside the inventory')
                H.equal(value.slot, slot, 'slot field matches')
                if value.unique then H.equal(value.amount, 1, 'unique stays single') end
            end
            for slot = 1, math.min(keep, slots) do
                if items[slot] then
                    H.equal(result.items[slot] and result.items[slot].name, items[slot].name, 'hotbar kept in fuzz')
                else
                    H.equal(result.items[slot], nil, 'empty hotbar slot kept empty in fuzz')
                end
            end
            -- planning twice is a fixed point
            local again = organize.plan(result.items, slots, mode, { keepSlots = keep, order = ORDER, maxStack = (round % 3 == 0) and function() return 7 end or nil })
            H.ok(not again.changed, 'plan is idempotent in fuzz ' .. round .. ' ' .. mode)
        end
    end
end

-- 11. wiring: the server intent, bridge and config are in place.
do
    local server = read('server.lua')
    local ui = read('client/ui.lua')
    local client = read('client.lua')
    H.ok(server:find("request.action == 'organize'", 1, true), 'handleIntent routes organize')
    H.ok(server:find('inventory.organize.plan', 1, true), 'server uses the pure planner')
    H.ok(server:find('validSession(src, request.token, targetKey, targetKey, expected, expected)', 1, true), 'organize validates through validSession')
    H.ok(server:find("lock({ targetKey }", 1, true), 'organize runs under the inventory lock')
    H.ok(server:find("shop inventories cannot be organized", 1, true), 'shops are refused')
    H.ok(server:find('isAnyUseBusy(target.type == '"'"'player'"'"' and target.source or src)', 1, true), 'refused while an item use is in progress')
    H.ok(server:find('settings.cooldownMs', 1, true), 'rate limited by organize.cooldownMs')
    H.ok(server:find("playerSetPath(current.source, { 'items' }, plan.items)", 1, true), 'player writes go through the kora_core funnel')
    H.ok(ui:find('organize = true', 1, true), 'the NUI bridge allows the organize intent')
    H.ok(ui:find('organize = organizeConfig()', 1, true), 'organize flags are pushed to the NUI')
    H.ok(ui:find('tips = tipsConfig()', 1, true), 'tips flags are pushed to the NUI')
    H.ok(client:find("action == 'organize'", 1, true), 'client transport sends organize through the intent callback')
    local manifest = read('fxmanifest.lua')
    H.ok(manifest:find("'shared/organize.lua'", 1, true), 'planner is a shared script')
    H.ok(read('config.lua'):find('organize = {', 1, true), 'organize config exists')
end

H.finish()
