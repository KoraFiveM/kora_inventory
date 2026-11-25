-- Splitting a stack into an empty slot. Behavioural: runs the real transfer
-- callback against a stash. The bug it guards: an empty target slot fell back
-- to "merge into any matching stack", which found the source stack and put the
-- split amount straight back (10 stayed 10, nothing appeared in the new slot).
local H = dofile('test/harness.lua')

Config = { kora_inventory = {} }
dofile('config.lua')
dofile('config/shops/ammunation.lua')
dofile('shared.lua')

local callbacks = {}
Kora = {
    util = { deepClone = function(value)
        local seen = {}
        local function clone(v)
            if type(v) ~= "table" then return v end
            if seen[v] then return seen[v] end
            local copy = {}
            seen[v] = copy
            for k, vv in pairs(v) do copy[clone(k)] = clone(vv) end
            return copy
        end
        return clone(value)
    end },
    resources = { serverRegistry = function() return { track = function() end, untrack = function() end } end },
    callback = { register = function(name, fn) callbacks[name] = fn end },
    sql = {},
}
GetCurrentResourceName = function() return 'kora_inventory' end
GetInvokingResource = function() return nil end
CreateThread = function() end
RegisterCommand = function() end
AddEventHandler = function() end
RegisterNetEvent = function() end
TriggerClientEvent = function() end
TriggerEvent = function() end
GetGameTimer = function() return 12345 end

local ITEMS = {
    water_bottle = { name = 'water_bottle', label = 'Water', weight = 500, type = 'item', unique = false, gridWidth = 2 },
    bread = { name = 'bread', label = 'Bread', weight = 100, type = 'item', unique = false },
    kit = { name = 'kit', label = 'Kit', weight = 100, type = 'item', unique = true, gridWidth = 2, gridHeight = 2 },
}

local registered = {}
local player
exports = setmetatable({}, {
    __call = function(_, name, fn) registered[name] = fn end,
    __index = function(_, resourceName)
        return setmetatable({}, {
            __index = function(_, exportName)
                return function(_, ...)
                    if resourceName == 'kora_core' then
                        if exportName == 'allShared' then return {} end
                        if exportName == 'getShared' then
                            local registry, itemName = ...
                            return registry == 'items' and ITEMS[itemName] or nil
                        end
                        if player and exportName == 'getPlayerData' then
                            local _, path = ...
                            if path then return Kora.util.deepClone(player[path[1]]) end
                            return Kora.util.deepClone(player)
                        end
                        if player and exportName == 'setPath' then
                            local _, path, value = ...
                            if path[2] then
                                player.items[path[2]] = Kora.util.deepClone(value)
                            else
                                player.items = Kora.util.deepClone(value)
                            end
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
dofile('server/grid.lua')
dofile('server.lua')

local internal = KoraInventory.internal
internal.createSecondary('stash', 'split-test', { label = 'Stash', slots = 10, maxWeight = 1000000 })
local stashKey = internal.key('stash', 'split-test')
local src = 1
local opened, session = internal.open(src, stashKey)
H.ok(opened, 'sanity: a session on the stash opened')

local function slotAmount(slot)
    local item = internal.getInventory(stashKey).items[slot]
    return item and item.amount or 0
end

local function total()
    local sum = 0
    for _, item in pairs(internal.getInventory(stashKey).items) do sum = sum + item.amount end
    return sum
end

local function move(fromSlot, toSlot, amount)
    return callbacks['kora_inventory:server:transfer'](src, {
        token = session.token, fromInventory = stashKey, toInventory = stashKey,
        fromSlot = fromSlot, toSlot = toSlot, amount = amount,
    })
end

H.ok(internal.addTo(stashKey, 'water_bottle', 10, 1, { quality = 80 }, 'seed'), 'seeded 10 water with metadata')

local ok, err = move(1, 2, 5)
H.ok(ok, 'split 5 of 10 into an empty slot succeeds: ' .. tostring(err))
H.equal(slotAmount(1), 5, 'source keeps 5')
H.equal(slotAmount(2), 5, 'the empty slot receives 5')
H.equal(internal.getInventory(stashKey).items[2].info.quality, 80, 'metadata is preserved on the split stack')
H.equal(total(), 10, 'total is conserved')

-- Odd amount, split as entered rather than rounded.
ok = move(1, 3, 3)
H.ok(ok, 'split an odd amount')
H.equal(slotAmount(1), 2, 'source keeps the remainder')
H.equal(slotAmount(3), 3, 'target gets exactly the entered amount')
H.equal(total(), 10, 'total is conserved after the odd split')

-- Stacking onto a matching stack is unchanged.
ok = move(3, 2, 3)
H.ok(ok, 'moving onto a matching stack still stacks')
H.equal(slotAmount(2), 8, 'stack grew')
H.equal(slotAmount(3), 0, 'emptied source slot is cleared')

-- A different item in the target rejects a partial move and changes nothing.
internal.addTo(stashKey, 'bread', 4, 5, {}, 'seed')
ok, err = move(1, 5, 1)
H.equal(ok, false, 'partial split onto a different item is rejected')
H.equal(slotAmount(1), 2, 'source untouched after rejection')
H.equal(slotAmount(5), 4, 'other item untouched after rejection')

-- Moving a whole stack into an empty slot lands in that slot, not elsewhere.
ok = move(2, 7, 8)
H.ok(ok, 'whole-stack move to an empty slot succeeds')
H.equal(slotAmount(7), 8, 'it lands in the requested slot')
H.equal(slotAmount(2), 0, 'and leaves the old slot empty')

-- Existing rows stay accessible and gain a footprint when explicitly placed.
Config.kora_inventory.grid.enabled = true
Config.kora_inventory.grid.columns = 4
local legacy = internal.view(stashKey, src)
H.equal(legacy.gridColumns, 4, 'shaped panel reports row width')
H.equal(legacy.items[1].gridWidth, 1, 'legacy anchor keeps a one-cell fallback')
H.equal(legacy.items[1].gridBaseWidth, 2, 'legacy item reports its real footprint for moves')

internal.createSecondary('stash', 'grid-test', { slots = 10, maxWeight = 1000000 })
local shapedKey = internal.key('stash', 'grid-test')
local _, shapedSession = internal.open(src, shapedKey)
local shaped = internal.getInventory(shapedKey)

local function shapedMove(fromSlot, toSlot, amount, rotated)
    local revision = internal.getRevision(shapedKey)
    return callbacks['kora_inventory:server:transfer'](src, {
        token = shapedSession.token, fromInventory = shapedKey, toInventory = shapedKey,
        fromSlot = fromSlot, toSlot = toSlot, amount = amount, rotated = rotated,
        fromRevision = revision, toRevision = revision,
    })
end

H.equal(internal.addTo(shapedKey, 'water_bottle', 5, 4, {}), false, 'wide items cannot wrap a row')
H.ok(internal.addTo(shapedKey, 'water_bottle', 5, 4, { quality = 80 }, nil, true, true), 'rotation fits at the row edge')
H.equal(internal.addTo(shapedKey, 'bread', 1, 8, {}), false, 'grants cannot overlap a covered cell')
H.equal(internal.canAdd(shapedKey, 'bread', 1, 8, {}), false, 'carry check also accounts for covered cells')
H.equal(shapedMove(4, 8, 2, false), false, 'a split cannot overlap the remainder')
H.equal(shaped.items[4].amount, 5, 'failed split restores quantity')
H.equal(shaped.items[4].gridRotated, true, 'failed split restores rotation')
H.equal(shaped.items[4].info.quality, 80, 'failed split restores metadata')
H.ok(shapedMove(4, 8, 5, false) == false, 'whole move cannot cross a row edge')
H.ok(shapedMove(4, 8, 5, true) == false, 'whole move cannot extend below the last row')
H.ok(shapedMove(4, 3, 5, false), 'whole move can use cells vacated by itself')
H.ok(shapedMove(3, 3, 5, true), 'same-anchor rotation is supported')
H.equal(shaped.items[3].gridHeight, 2, 'rotated state persists at the anchor')
H.ok(shapedMove(3, 1, 2, false), 'split fits a disjoint footprint')
H.equal(shaped.items[1].amount, 2, 'split writes the selected count')
H.equal(shaped.items[3].amount, 3, 'split conserves the remainder')
H.equal(shapedMove(1, 3, 2, false), true, 'a matching anchor stacks regardless of orientation')
H.equal(shaped.items[3].amount, 5, 'stacking preserves quantity')
H.equal(shaped.items[3].gridRotated, true, 'stacking preserves the receiving orientation')

H.equal(internal.addTo(shapedKey, 'kit', 3, nil, {}), false, 'multi-unique grant reserves all rectangles first')
H.ok(internal.addTo(shapedKey, 'kit', 1, 1, {}), 'one unique footprint fits')
H.ok(internal.addTo(shapedKey, 'bread', 1, 8, {}), 'seed a blocker in the displaced item footprint')
H.equal(shapedMove(3, 1, 5, false), false, 'a swap is rejected if either resulting footprint cannot fit')
H.equal(shaped.items[1].name, 'kit', 'failed swap preserves the first item')
H.equal(shaped.items[3].name, 'water_bottle', 'failed swap preserves the second item')

Config.kora_inventory.grid.enabled = false
H.ok(internal.addTo(shapedKey, 'bread', 1, 2, {}, nil, true), 'classic mode can reuse formerly covered cells')
H.equal(internal.view(shapedKey, src).gridColumns, nil, 'classic panel emits no shaped layout')
Config.kora_inventory.grid.enabled = true
local reopened = internal.view(shapedKey, src)
H.equal(reopened.items[1].gridWidth, 1, 'a conflicting stored footprint falls back to its anchor')
H.equal(reopened.items[2].name, 'bread', 're-enabling keeps all existing anchors accessible')

player = { items = {}, metadata = {} }
local api = KoraInventory.api
H.ok(api.addItem(src, 'kit', 1, 1), 'player placement writes the footprint through the core funnel')
H.equal(player.items[1].gridHeight, 2, 'the core-owned item keeps its footprint')
H.equal(api.getFreeSlot(src), 3, 'the player free-slot export skips covered cells')
H.equal(api.addItem(src, 'bread', 1, 2), false, 'an explicit player grant cannot use a covered cell')
H.equal(api.setItems(src, {
    [1] = { name = 'kit', amount = 1 },
    [2] = { name = 'bread', amount = 1 },
}), false, 'bulk replacements cannot overlap footprints')
H.equal(player.items[2], nil, 'the failed replacement writes no partial state')
H.ok(api.addItem(src, 'water_bottle', 1, 3), 'another shaped item fits in the player layout')
H.ok(api.moveItem(src, 3, 3, 1, true), 'trusted player movement also supports rotation')
H.equal(player.items[3].gridRotated, true, 'the rotated record persists in core')

H.ok(api.setItems(src, {}), 'clear the player before replaying a confiscation snapshot')
H.ok(internal.setInventoryItems(internal.playerKey(src), {
    [1] = { name = 'kit', amount = 1 },
    [2] = { name = 'bread', amount = 1 },
}, true), 'a saved legacy snapshot preserves both anchors when restored')
H.equal(player.items[1].gridWidth, 1, 'a restored legacy item keeps its one-cell layout')
H.equal(player.items[2].name, 'bread', 'the second restored item survives intact')

H.finish()
