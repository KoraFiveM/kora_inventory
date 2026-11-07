-- Execute the real authority and its trusted callers without an FXServer.
local H = dofile('test/harness.lua')
Config = {}
dofile('config.lua')
dofile('shared.lua')

local events, threads, registered = {}, {}, {}
local writes, invokingResource, definitionHook = 0, nil, nil
local data = { [7] = { citizenid = 'CID7', items = {} } }
local definitions = {
    cash = { name = 'cash', weight = 0 },
    wood = { name = 'wood', weight = 1 },
    board = { name = 'board', weight = 1 },
    backpack = { name = 'backpack', unique = true, weight = 1 },
    weapon_pistol = { name = 'weapon_pistol', type = 'weapon', unique = true, weight = 1, ammotype = 'AMMO_PISTOL' },
}
local function noop() end
GetCurrentResourceName = function() return 'kora_inventory' end
GetInvokingResource = function() return invokingResource end
GetGameTimer = function() return 1000 end
GetPlayerPed = function(source) return source end
GetEntityCoords = function() return { x = 1, y = 2, z = 3 } end
GetPlayerRoutingBucket = function() return 0 end
CreateThread = function(callback) threads[#threads + 1] = callback end
Wait, RegisterCommand, TriggerClientEvent = noop, noop, noop
AddEventHandler = function(name, callback) events[name] = callback end
RegisterNetEvent = AddEventHandler
TriggerEvent = function(name, ...) if events[name] then events[name](...) end end
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
    end, clamp = function(value, min, max)
        if value < min then return min end
        if value > max then return max end
        return value
    end },
    resources = { serverRegistry = function() return { track = noop, untrack = noop } end },
    callback = { register = noop },
    distance = { player = function() return true end },
    sql = {},
}
exports = setmetatable({}, {
    __call = function(_, name, callback) registered[name] = callback end,
    __index = function(_, resource)
        return setmetatable({}, { __index = function(_, name)
            return function(_, ...)
                if resource == 'kora_core' then
                    local source, field, value = ...
                    if name == 'allShared' then return {} end
                    if name == 'registerPhysicalCash' then return true end
                    if name == 'getShared' then
                        if definitionHook then
                            local callback = definitionHook
                            definitionHook = nil
                            callback()
                        end
                        return definitions[field]
                    end
                    if name == 'getPlayerData' then
                        local player = data[source]
                        if not player or not field then return player end
                        if field[1] == 'items' and field[2] then return player.items[field[2]] end
                        return player[field[1]]
                    end
                    if name == 'setPath' then
                        writes = writes + 1
                        if field[2] then data[source].items[field[2]] = value else data[source].items = value end
                        TriggerEvent('qbcore:server:inventoryChanged', source)
                        return true
                    end
                end
                return registered[name] and registered[name](...)
            end
        end })
    end,
})
dofile('server.lua')
dofile('server/crafting.lua')
dofile('server/containers.lua')
dofile('server/compat/qb.lua')
-- This is kora_inventory's own compatibility module; no ox_lib code is loaded.
dofile('server/compat/ox.lua')

local inventory, internal = QbInventory, QbInventory.internal
data[7].items = {
    [1] = internal.buildItem('cash', 100, 1, { origin = { account = 'cash' } }),
    [2] = internal.buildItem('wood', 2, 2, {}),
    [3] = internal.buildItem('weapon_pistol', 1, 3, { serial = 'EXISTING', ammo = 2, durability = 100 }),
    [4] = internal.buildItem('backpack', 1, 4, {}),
}
H.ok(inventory.api.SetInventory(7, inventory.copy(data[7].items)), 'cash-off public replacement remains supported')
Config.qbinventory.cash.asItem = true
threads[1]() -- Cash registration only; capture the periodic session worker.

local revision = internal.getRevision('player:7')
H.ok(internal.setInventoryItems('player:7', inventory.copy(data[7].items)), 'unchanged trusted snapshot is allowed')
H.equal(internal.getRevision('player:7'), revision + 1, 'Core inventory-change notification does not double-bump revisions')
H.equal(data[7].items[1].info.origin.account, 'cash', 'nested cash metadata survives canonical rebuilding')

H.ok(inventory.crafting.register('boards', { ingredients = { wood = 1 }, output = { name = 'board', amount = 1 } }))
H.ok(inventory.crafting.canCraft(7, 'boards'), 'the real craft planner accepts this recipe')
H.ok(inventory.crafting.craft(7, 'boards'), 'the real craft commits with cash enabled')
H.equal(inventory.api.getItemCount(7, 'wood'), 1)
H.equal(inventory.api.getItemCount(7, 'board'), 1)
H.equal(data[7].items[1].amount, 100, 'craft preserves cash')

H.ok(inventory.weapons.setAmmo(7, 3, 2), 'weapon-state mutation works')
H.ok(inventory.weapons.fireRound(7, 3), 'server-owned loaded round is consumed')
H.ok(inventory.weapons.consumeDurability(7, 3, 1), 'firing durability mutation works')
H.equal(data[7].items[3].info.ammo, 1)
H.equal(data[7].items[3].info.durability, 99)
H.equal(data[7].items[1].amount, 100, 'weapon mutations preserve cash')

local bound, containerId = inventory.containers.bindItem(7, 4, {
    portable = true,
    access = function() return true end,
})
H.ok(bound, 'real container binding can commit without an outer lock')
H.equal(data[7].items[4].info.containerId, containerId)
H.ok(internal.getInventory('container:' .. containerId), 'bound container remains registered')
H.ok(inventory.compat.qb.SetItemData(7, 'wood', 'info', { batch = 'QB' }, 2), 'Kora metadata mutation commits')
inventory.compat.ox.SetMetadata(7, 2, { batch = 'adapter' })
H.equal(data[7].items[2].info.batch, 'adapter', 'native Kora adapter metadata path uses the same real funnel')

for _, replace in ipairs({ inventory.api.setItems, inventory.api.SetInventory, inventory.compat.qb.SetInventory }) do
    local ok, reason = replace(7, inventory.copy(data[7].items), true)
    H.equal(ok, false, 'public replacement cannot select a trusted-write bypass')
    H.equal(reason, 'SetInventory is unavailable while cash is an item', 'public cash-mode error contract is preserved')
end
local invalid, reason = inventory.api.setItems(7, false)
H.equal(invalid, false)
H.equal(reason, 'items must be a table', 'public type validation still precedes cash-mode refusal')

local function rejectsCash(items, label)
    local beforeWrites = writes
    local beforeRevision = internal.getRevision('player:7')
    local cash = inventory.api.getItemCount(7, 'cash')
    local ok = internal.setInventoryItems('player:7', items)
    H.equal(ok, false, label)
    H.equal(writes, beforeWrites, label .. ': no Core write')
    H.equal(internal.getRevision('player:7'), beforeRevision, label .. ': no revision bump')
    H.equal(inventory.api.getItemCount(7, 'cash'), cash, label .. ': cash unchanged')
end
for _, amount in ipairs({ 99, 101 }) do
    local items = inventory.copy(data[7].items)
    items[1].name, items[1].amount = 'CASH', amount
    rejectsCash(items, 'internal replacement cannot change canonical cash amount')
end
local missingCash = inventory.copy(data[7].items)
missingCash[1] = nil
rejectsCash(missingCash, 'internal replacement cannot remove the cash stack')
local extraCash = inventory.copy(data[7].items)
extraCash[6] = internal.buildItem('cash', 1, 6, {})
rejectsCash(extraCash, 'an additional cash stack cannot mint money')
H.equal(inventory.compat.qb.SetItemData(7, 'cash', 'amount', 101, 1), false, 'Kora item-data API cannot mint cash')

local stale = inventory.copy(data[7].items)
invokingResource = 'kora_core'
H.ok(registered.physicalCashAdd(7, 'cash', 5, 'test'), 'the existing cash bridge remains authoritative')
invokingResource = nil
rejectsCash(stale, 'stale trusted snapshot cannot undo a later cash credit')
H.equal(inventory.api.getItemCount(7, 'cash'), 105)

local duringValidation = inventory.copy(data[7].items)
local writesBeforeCredit = writes
local revisionBeforeCredit = internal.getRevision('player:7')
definitionHook = function()
    invokingResource = 'kora_core'
    H.ok(registered.physicalCashAdd(7, 'cash', 5, 'validation-test'))
    invokingResource = nil
end
H.equal(internal.setInventoryItems('player:7', duringValidation), false, 'cash is re-read after definition validation under the player lock')
H.equal(inventory.api.getItemCount(7, 'cash'), 110)
H.equal(writes, writesBeforeCredit + 1, 'only the trusted cash credit commits')
H.equal(internal.getRevision('player:7'), revisionBeforeCredit + 1, 'rejected stale replacement cannot bump the revision')

local moved = inventory.copy(data[7].items)
moved[7], moved[1] = moved[1], nil
moved[7].slot = 7
H.ok(internal.setInventoryItems('player:7', moved), 'same-player cash relocation preserves the authoritative balance')
H.equal(inventory.api.getItemCount(7, 'cash'), 110)
local split = inventory.copy(data[7].items)
split[7].amount = 95
split[1] = internal.buildItem('cash', 5, 1, {})
H.ok(internal.setInventoryItems('player:7', split), 'unchanged cash balance may span multiple stacks')
H.equal(inventory.api.getItemCount(7, 'cash'), 110, 'split keeps the ten units credited into the separate cash stack')

local holder = coroutine.create(function()
    return internal.lock({ 'player:7' }, function() coroutine.yield(); return true end)
end)
H.ok(coroutine.resume(holder))
local beforeWrites = writes
local busy, busyReason = internal.setInventoryItems('player:7', inventory.copy(data[7].items))
H.equal(busy, false, 'internal writes honor an existing player lock')
H.equal(busyReason, 'inventory busy')
H.equal(writes, beforeWrites)
H.ok(coroutine.resume(holder))
H.ok(internal.lock({ 'player:7' }, function()
    return internal.setInventoryItems('player:7', inventory.copy(data[7].items))
end), 'same-coroutine nested mutation retains the existing lock contract')

local savedItems = data[7].items
data[7].items = { [2] = internal.buildItem('wood', 1, 2, {}) }
H.ok(internal.setInventoryItems('player:7', inventory.copy(data[7].items)), 'cash-enabled players without cash can still mutate non-cash items')
local minted = inventory.copy(data[7].items)
minted[1] = internal.buildItem('cash', 1, 1, {})
rejectsCash(minted, 'an empty balance cannot gain cash through replacement')
data[7].items = savedItems

local invalidItems = inventory.copy(data[7].items)
invalidItems[2].name = 'unknown'
H.equal(internal.setInventoryItems('player:7', invalidItems), false, 'existing item-definition validation remains enforced')
local overweight = inventory.copy(data[7].items)
overweight[2].amount = Config.qbinventory.playerMaxWeight + 1
H.equal(internal.setInventoryItems('player:7', overweight), false, 'existing weight validation remains enforced')
local secondary = internal.createSecondary('stash', 'cash-regression', { slots = 5, maxWeight = 100 })
H.ok(internal.setInventoryItems(secondary.key, { [1] = internal.buildItem('wood', 2, 1, {}) }), 'secondary inventory funnel remains supported')
H.equal(secondary.items[1].amount, 2)
H.finish()
