local H = dofile('test/harness.lua')

local registered = {}
exports = function(name, fn) registered[name] = fn end
AddEventHandler = function() end
GetCurrentResourceName = function() return 'qbinventory' end
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

local module = dofile('server/crafting.lua')
local crafting, weapons = module.crafting, module.weapons

local ok, err = crafting.register('oak_board', {
    ingredients = { { name = 'wood', amount = 2, metadata = { grade = 'oak' } } },
    output = { name = 'board', amount = 1 },
})
H.equal(ok, true, err)
H.equal(crafting.register('bad recipe', { ingredients = { wood = 1 }, output = { name = 'board' } }), false, 'ids are constrained')
H.equal(crafting.register('bad_output', { ingredients = { wood = 1 }, output = { name = 'not_real' } }), false, 'outputs are registered items only')

local crafted, output = crafting.craft(7, 'oak_board')
H.equal(crafted, true, output)
H.equal(state['player:7'].items[1].amount, 1, 'only matching crafting metadata is consumed')
H.equal(state['player:7'].items[2].amount, 1, 'nonmatching crafting metadata remains')
H.equal(state['player:7'].items[4].name, 'board', 'server recipe defines output')
H.equal(crafting.craft(7, 'oak_board'), false, 'missing ingredients reject atomically')
H.equal(state['player:7'].items[4].amount, 1, 'failed craft leaves output unchanged')

state['player:7'].items[1].amount = 6
state['player:7'].items[4] = nil
H.equal(crafting.canCraft(7, 'oak_board', 3), true, 'batch feasibility scales ingredients and outputs')
H.equal(crafting.canCraft(7, 'oak_board', 4), false, 'batch feasibility rejects an unavailable amount')
local craftedBatch, batchOutput = crafting.craft(7, 'oak_board', nil, 3)
H.equal(craftedBatch, true, batchOutput)
H.equal(batchOutput.amount, 3, 'batch craft reports the full output amount')
H.equal(state['player:7'].items[1].name, 'board', 'batch craft replaces the consumed ingredient slot with its output')
H.equal(state['player:7'].items[1].amount, 3, 'batch craft grants the scaled output amount atomically')
H.equal(crafting.craft(7, 'oak_board', nil, 101), false, 'batch amount is server bounded')
H.equal(crafting.craft(7, 'oak_board', nil, 'many'), false, 'malformed batch amounts are rejected')

state['player:7'].items[1] = { slot = 1, name = 'wood', amount = 3, weight = 10, info = { grade = 'oak' } }
state['player:7'].items[4] = nil
H.equal(crafting.register('too_many_outputs', {
    ingredients = { wood = 2 },
    outputs = { { name = 'board' }, { name = 'sawdust' }, { name = 'nails' } },
}), true, 'a recipe may declare several outputs')
H.equal(crafting.canCraft(7, 'too_many_outputs'), false, 'feasibility rejects when a later output cannot fit')
H.equal(crafting.craft(7, 'too_many_outputs'), false, 'a later output failure rejects the transaction')
H.equal(state['player:7'].items[1].amount, 3, 'later output failure does not consume ingredients')
H.equal(state['player:7'].items[4], nil, 'later output failure does not commit earlier outputs')
H.equal(crafting.register('board_and_dust', {
    ingredients = { wood = 2 },
    outputs = { { name = 'board', amount = 1 }, { name = 'sawdust', amount = 2 } },
}), true, 'multi-output recipes register')
H.equal(crafting.canCraft(7, 'board_and_dust'), true, 'craft feasibility is available without committing')
H.equal(state['player:7'].items[1].amount, 3, 'feasibility does not consume ingredients')
local craftedMany, outputs = crafting.craft(7, 'board_and_dust')
H.equal(craftedMany, true, outputs)
H.equal(#outputs, 2, 'multi-output craft returns all outputs')
H.equal(state['player:7'].items[4].name, 'board', 'first output is inserted')
H.equal(state['player:7'].items[5].name, 'sawdust', 'second output is inserted in the same transaction')
H.equal(state['player:7'].items[1].name, 'wood', 'existing ingredient stack remains in its slot')
H.equal(state['player:7'].items[2].name, 'wood', 'nonmatching metadata remains after multi-output craft')
H.equal(state['player:7'].items[1].amount, 1, 'multi-output craft consumes ingredients once')

local denied = crafting.register('denied', {
    ingredients = { wood = 1 }, output = { name = 'board' }, access = function() return false, 'station locked' end,
})
H.equal(denied, true, 'server recipe policy registers')
H.equal(crafting.craft(7, 'denied'), false, 'server recipe access policy blocks craft')

local prepared = assert(weapons.prepareMetadata('weapon_pistol', {}))
H.ok(prepared.serial:match('^QB%-WEAPONPISTOL%-') ~= nil, 'new weapon metadata receives a server serial')
H.equal(prepared.durability, 100, 'weapon gets configured default durability')
H.equal(prepared.quality, 100, 'legacy weapon quality mirrors canonical durability')
H.equal(prepared.ammo, 0, 'weapon ammo starts at zero')
H.equal(weapons.prepareMetadata('weapon_pistol', { components = { 'not_allowed' } }), nil, 'unconfigured component is rejected')
H.equal(weapons.setState(7, 3, { ammo = 500, components = { 'component_at_pi_flsh' } }), true, 'weapon state is committed through authority setter')
H.equal(state['player:7'].items[3].info.ammo, 250, 'ammo is clamped to server configuration')
H.equal(state['player:7'].items[3].info.components[1], 'component_at_pi_flsh', 'allowed component is canonicalised')
H.equal(weapons.setState(7, 3, { tint = 99 }), true, 'weapon tint is set through the server authority')
H.equal(state['player:7'].items[3].info.tint, 32, 'weapon tint is bounded to GTA tint range')
H.equal(weapons.consumeDurability(7, 3, 200), true, 'durability may be consumed server-side')
H.equal(state['player:7'].items[3].info.durability, 0, 'durability cannot become negative')
H.equal(state['player:7'].items[3].info.quality, 0, 'quality remains mirrored after durability changes')
H.equal(weapons.setState(7, 1, { ammo = 2 }), false, 'nonweapon slots cannot receive weapon state')

H.ok(type(registered.CraftItem) == 'function' and type(registered.CanCraftRecipe) == 'function'
    and type(registered.SetWeaponState) == 'function', 'server-only crafting and weapon exports are registered')
H.finish()
