-- Use-item handlers: weapon equip/holster toggle, and a generic data-driven
-- consumable effect handler (food/drink/alcohol/drugs). Registered here via
-- the plain global createUseable (defined in server.lua, same resource and
-- realm -- see load order in fxmanifest.lua) rather than
-- exports.qbcore:createUseable: qbinventory's OWN useables table is what
-- actually powers the NUI's Use button (see hasUseable/buildItem in
-- server.lua); a handler registered on qbcore's separate useables table is
-- never consulted by qbinventory's use flow.

-- --- weapons ---

-- Equip/holster toggle only, ammo always starts at 0. The weapon item stays
-- in the player's inventory the whole time it's equipped -- simplest,
-- desync-free behaviour (matches vanilla weapon-wheel semantics), rather than
-- a remove-on-equip/restore-on-holster/ammo-loading system, which is a
-- separate feature this doesn't attempt.
--
-- The draw itself (which way the toggle goes, how long it takes, and the
-- carried-weapon prop it swaps with) belongs to server/weaponcarry.lua, which
-- loads after this file -- so it is resolved per use, not captured here.
local function weaponUseable(src, item)
    local carry = QbInventory.weaponCarry
    if carry then return carry.toggle(src, item) end
    -- weaponcarry.lua is a sibling module, not a dependency: without it a
    -- weapon still equips, just instantly and with nothing shown on the back.
    TriggerClientEvent('qbinventory:client:toggleWeapon', src, { name = item.name, slot = item.slot, action = 'toggle', duration = 0 })
    return true -- successful use; item remains in inventory because no removal is performed
end

for _, def in ipairs(exports.qbcore:allShared('weapons')) do
    -- weapon_unarmed isn't a real carryable item -- nothing stocks/loots it.
    if def.name ~= 'weapon_unarmed' then
        createUseable(def.name, weaponUseable)
    end
end

-- --- consumables ---

-- name -> { hunger?, thirst?, stress?, drunk?, high? } deltas, applied via
-- exports.qbcore:incrementMetaData (clamped 0-100). drunk/high are new
-- metadata keys -- no existing convention to clash with. Unlike hunger/
-- thirst (see qbcore/modules/needs), nothing decays them passively yet;
-- that's a natural follow-up if permanent drunk/high stacking is unwanted.
local CONSUMABLE_EFFECTS = {
    -- food
    sandwich      = { hunger = 35 },
    bread         = { hunger = 20 },
    chocolate_bar = { hunger = 15, stress = -5 },
    -- drink
    water_bottle  = { thirst = 40 },
    soda          = { thirst = 25, stress = -3 },
    -- alcohol
    beer          = { thirst = 10, stress = -10, drunk = 15 },
    whiskey       = { thirst = 5,  stress = -20, drunk = 30 },
    -- drugs
    weed          = { stress = -25, high = 30 },
}

local function consumableUseable(src, item)
    local effects = CONSUMABLE_EFFECTS[item.name]
    if not effects then return false end

    local removed, removeErr = removeItem(src, item.name, 1, item.slot, 'consumed')
    if not removed then return false, removeErr end

    if effects.hunger then exports.qbcore:incrementMetaData(src, 'hunger', effects.hunger, 0, 100) end
    if effects.thirst then exports.qbcore:incrementMetaData(src, 'thirst', effects.thirst, 0, 100) end
    if effects.stress then exports.qbcore:incrementMetaData(src, 'stress', effects.stress, 0, 100) end
    if effects.drunk then exports.qbcore:incrementMetaData(src, 'drunk', effects.drunk, 0, 100) end
    if effects.high then exports.qbcore:incrementMetaData(src, 'high', effects.high, 0, 100) end

    TriggerClientEvent('qbinventory:client:consumeEffect', src, item.name, effects)
    return true
end

for name in pairs(CONSUMABLE_EFFECTS) do
    createUseable(name, consumableUseable)
end
