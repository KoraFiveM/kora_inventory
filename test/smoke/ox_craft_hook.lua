-- ox `craftItem` hook bridge: crafting.craft dispatches through the shared hook
-- runner; returning false cancels before anything is consumed.
local H = dofile('test/harness.lua')

local registered = {}
AddEventHandler = function() end
GetCurrentResourceName = function() return 'kora_inventory' end
GetInvokingResource = function() return 'crafting-test' end
TriggerEvent = function() end

Config = {
    qbinventory = {
        crafting = {},
        weapons = {
            defaultDurability = 100,
            maxAmmo = 250,
            serialPrefix = 'QB',
            components = { weapon_pistol = { 'component_at_pi_flsh', 'component_at_pi_supp' } },
        },
    },
}

local definitions = {
    wood = { name = 'wood', weight = 10 },
    board = { name = 'board', weight = 15 },
    sawdust = { name = 'sawdust', weight = 1 },
    nails = { name = 'nails', weight = 1 },
    weapon_pistol = { name = 'weapon_pistol', weight = 100, type = 'weapon', unique = true },
}
local state = {
    ['player:7'] = {
        key = 'player:7', type = 'player', id = 7, slots = 5, maxWeight = 200,
        items = {
            [1] = { slot = 1, name = 'wood', amount = 3, weight = 10, info = { grade = 'oak' } },
            [2] = { slot = 2, name = 'wood', amount = 1, weight = 10, info = { grade = 'pine' } },
            [3] = { slot = 3, name = 'weapon_pistol', amount = 1, weight = 100, unique = true, info = { serial = 'OLD', durability = 80, ammo = 10, components = {} } },
        },
    },
}

local function copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for key, nested in pairs(value) do out[key] = copy(nested) end
    return out
end
exports = setmetatable({ kora_core = {
    getPlayerData = function(_, src, path)
        local player = state['player:' .. src]
        if not player then return nil end
        if path[1] == 'citizenid' then return 'CID' .. src end
        if path[2] then return copy(player.items[path[2]]) end
        return copy(player.items)
    end,
} }, { __call = function(_, name, fn) registered[name] = fn end })
local function totalWeight(items)
    local total = 0
    for _, item in pairs(items or {}) do total = total + (item.weight or 0) * (item.amount or 0) end
    return total
end

QbInventory = {
    copy = copy,
    sameInfo = function(a, b)
        a, b = a or {}, b or {}
        for key, value in pairs(a) do if b[key] ~= value then return false end end
        for key, value in pairs(b) do if a[key] ~= value then return false end end
        return true
    end,
    internal = {},
}
-- Load the real shared primitives over the mock rather than hand-rolling a
-- third copy of them: these mocks had already drifted (they redeclared copy
-- and sameInfo), so a primitive added to shared.lua was invisible here until
-- it blew up at call time. shared.lua is pure Lua with no FXServer deps, and
-- `QbInventory = QbInventory or {}` preserves the mock's `internal` table.
dofile('shared.lua')
local I = QbInventory.internal
I.copy = copy
I.playerKey = function(src) return 'player:' .. src end
I.itemDef = function(name) return definitions[type(name) == 'string' and name:lower() or name] end
I.buildItem = function(name, amount, slot, info)
    local def = I.itemDef(name)
    if not def then return nil, 'unknown item' end
    return { slot = slot, name = def.name, amount = amount, weight = def.weight or 0, unique = def.unique or false, type = def.type,
        info = copy(info or {}), metadata = copy(info or {}) }
end
I.resolveInventory = function(key) return key, state[key] end
I.totalWeight = totalWeight
I.lock = function(_, fn) return fn() end
I.setInventoryItems = function(key, items) state[key].items = copy(items); return true end
I.setPlayerItemInfo = function(src, slot, info)
    local item = state[I.playerKey(src)].items[slot]
    item.info, item.metadata = copy(info), copy(info)
    return true
end

local module = dofile('server/crafting.lua')
local crafting, weapons = module.crafting, module.weapons


local hookCalls = {}
local verdict = true
I.runHooks = function(name, src, payload)
    hookCalls[#hookCalls + 1] = { name = name, src = src, payload = payload }
    if verdict == false then return false, 'action denied by hook' end
    return true
end

crafting.register('oak_board', {
    ingredients = { { name = 'wood', amount = 2, metadata = { grade = 'oak' } } },
    output = { name = 'board', amount = 1 },
})
local ok1 = crafting.craft(7, 'oak_board', { benchId = 'bench1' }, 1)
H.equal(ok1, true, 'craft proceeds when the hook allows')
H.equal(hookCalls[1].name, 'craftItem', 'craftItem event dispatched')
H.equal(hookCalls[1].src, 7, 'source passed')
H.equal(hookCalls[1].payload.recipeId, 'oak_board', 'recipe id in payload')
H.equal(hookCalls[1].payload.itemName, 'board', 'itemName is the first output for itemFilter')
H.equal(hookCalls[1].payload.benchId, 'bench1', 'bench id from context')
H.equal(hookCalls[1].payload.toInventory, 'player:7', 'toInventory in payload')
state['player:7'].items[1] = { slot = 1, name = 'wood', amount = 4, weight = 10, info = { grade = 'oak' } }
local woodBefore = state['player:7'].items[1].amount
verdict = false
local ok2, err2 = crafting.craft(7, 'oak_board')
H.equal(ok2, false, 'a false hook cancels the craft')
H.equal(err2, 'action denied by hook', 'cancel reason surfaced')
H.equal(state['player:7'].items[1].amount, woodBefore, 'nothing consumed on cancel')

H.finish()
