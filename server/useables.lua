-- Use-item handlers: weapon equip/holster toggle, and a generic data-driven
-- consumable effect handler (food/drink/alcohol/drugs). Registered here via
-- the plain global createUseable (defined in server.lua, same resource and
-- realm -- see load order in fxmanifest.lua) rather than
-- exports.qbcore:createUseable: qbinventory's OWN useables table is what
-- actually powers the NUI's Use button (see hasUseable/buildItem in
-- server.lua); a handler registered on qbcore's separate useables table is
-- never consulted by qbinventory's use flow.

-- --- weapons ---

-- Equip/holster toggle. The weapon item stays in the player's inventory the
-- whole time it's equipped -- simplest, desync-free behaviour (matches vanilla
-- weapon-wheel semantics), rather than a remove-on-equip/restore-on-holster
-- system.
--
-- A drawn weapon starts at zero rounds and is loaded by using an ammo item;
-- see the ammunition section at the bottom of this file. Ammo is NOT persisted
-- in item metadata across a holster -- that remains a separate feature.
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

-- --- ammunition ---

-- Loading a magazine into the weapon in the player's hands.
--
-- Before this, no ammo useable was registered at all: `pistol_ammo` and the
-- rest were stocked by Ammu-Nation, defined with an `ammoType` and a `rounds`
-- count in qbcore's shared items, and completely inert -- every weapon sat at
-- zero rounds forever with no way to load one.
--
-- Which weapon is being loaded is resolved on the SERVER, from
-- weaponcarry's `equipped` record. That record is only ever set after the
-- client confirms a draw the server itself asked for, and is re-validated
-- against qbcore-owned PlayerData at that point -- so the client contributes
-- nothing here beyond "use the item in this slot". No weapon name, hash, ammo
-- type or round count crosses the wire inbound.
--
-- The requirement to have the weapon DRAWN is deliberate, not a shortcut:
-- GTA's ammo lives on the ped's weapon, and the ped only has the weapon while
-- it is drawn. Loading a holstered weapon would need ammo persisted in item
-- metadata and reapplied on every draw, which is a different (and larger)
-- feature -- and silently accepting the use while doing nothing would consume
-- the magazine for no effect, which is worse than refusing it.
local function ammoUseable(src, item)
    local def = QbInventory.internal.itemDef(item.name)
    local rounds = math.floor(tonumber(def and def.rounds) or 0)
    if not def or not def.ammoType or rounds <= 0 then return false, 'not usable ammunition' end

    local carry = QbInventory.weaponCarry
    local holding = carry and carry.equippedWeapon(src)
    if not holding then return false, 'draw a weapon before loading ammunition' end

    local weaponDef = QbInventory.internal.itemDef(holding.name)
    if not weaponDef or weaponDef.ammotype ~= def.ammoType then
        return false, ('%s does not take %s'):format(weaponDef and (weaponDef.label or weaponDef.name) or 'that weapon', def.label or def.name)
    end

    local removed, removeErr = removeItem(src, item.name, 1, item.slot, 'loaded ammunition')
    if not removed then return false, removeErr end

    -- The weapon NAME comes from the server's own equipped record, so the
    -- client is told what to load rather than asked. The cap is config, and the
    -- client clamps against the weapon's own maximum on top of it.
    TriggerClientEvent('qbinventory:client:addAmmo', src, {
        weapon = holding.name,
        rounds = rounds,
        maxAmmo = math.floor(tonumber((Config.qbinventory.weapons or {}).maxAmmo) or 0),
    })
    return true
end

-- Every ammo item in the shared registry, found by the fields that MAKE it one
-- (`ammoType` + `rounds`) rather than by a name pattern, so a server adding its
-- own magazine item gets a working use with no change here.
for _, def in ipairs(exports.qbcore:allShared('items')) do
    if def.ammoType and tonumber(def.rounds) and tonumber(def.rounds) > 0 then
        createUseable(def.name, ammoUseable)
    end
end
