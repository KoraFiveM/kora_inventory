-- Behavioural coverage for the qb-weapons transport. The old resource's
-- client item records must never become authority in the replacement.
local H = dofile('test/harness.lua')

local events, callbacks, uses, stateChanges, worn = {}, {}, {}, {}, {}
local inventory = {
    [1] = { slot = 1, name = 'weapon_pistol', info = { ammo = 12, durability = 90 } },
    [2] = { slot = 2, name = 'pistol_ammo', info = {} },
}

RegisterNetEvent = function(name, fn) events[name] = fn end
QB = { callback = { register = function(name, fn) callbacks[name] = fn end } }
source = 7

QbInventory = {
    internal = {
        playerKey = function(src) return 'player:' .. src end,
        resolveInventory = function(key)
            if key == 'player:7' then return key, { items = inventory } end
            return nil
        end,
        itemDef = function(name)
            if name == 'pistol_ammo' then return { ammoType = 'AMMO_PISTOL', rounds = 12 } end
        end,
    },
    api = { useItem = function(src, slot) uses[#uses + 1] = { src = src, slot = slot }; return true end },
    weapons = {
        isWeapon = function(item) return item.name == 'weapon_pistol' end,
        getState = function(_, slot) return inventory[slot] and inventory[slot].info end,
        setAmmo = function(_, slot, ammo) inventory[slot].info.ammo = ammo; stateChanges[#stateChanges + 1] = ammo; return true end,
        consumeDurability = function(_, slot, amount) worn[#worn + 1] = { slot = slot, amount = amount }; return true end,
    },
    weaponCarry = {
        equippedWeapon = function() return { slot = 1, name = 'weapon_pistol' } end,
        toggle = function(_, item) uses[#uses + 1] = { holster = item.slot }; return true end,
    },
}

dofile('server/compat/qb_weapons.lua')

H.ok(callbacks['qb-weapons:server:GetConfig'], 'registers retired config callback')
H.ok(callbacks['weapon:server:GetWeaponAmmo'], 'registers legacy ammo callback')
H.ok(type(callbacks['qb-weapons:server:GetConfig']()) == 'table'
    and next(callbacks['qb-weapons:server:GetConfig']()) == nil, 'no qb-weapons repair configuration is invented')
local ammo, name = callbacks['weapon:server:GetWeaponAmmo'](7, { slot = 1, name = 'weapon_rpg' })
H.equal(ammo, 12, 'ammo callback reads the authoritative weapon slot')
H.equal(name, 'weapon_pistol', 'ammo callback ignores a forged weapon name')
H.equal(select(1, callbacks['weapon:server:GetWeaponAmmo'](7, { slot = 2 })), 0, 'ammo callback rejects non-weapons')
H.equal(callbacks['qb-weapons:server:RepairWeapon'](), false, 'client repair callback is safely refused')

events['qb-weapons:server:UpdateWeaponAmmo']({ slot = 1, name = 'weapon_rpg' }, 4)
H.equal(inventory[1].info.ammo, 4, 'legacy shot report may lower equipped ammo')
events['qb-weapons:server:UpdateWeaponAmmo']({ slot = 1 }, 999)
H.equal(inventory[1].info.ammo, 4, 'legacy client report cannot mint ammunition')
events['qb-weapons:server:UpdateWeaponAmmo']({ slot = 2 }, 0)
H.equal(#stateChanges, 1, 'only the server-equipped weapon may report ammunition')

events['qb-weapons:server:UpdateWeaponQuality']({ slot = 1, name = 'weapon_rpg' }, 2)
H.equal(worn[1].slot, 1, 'durability targets the real equipped slot')
H.equal(worn[1].amount, 2, 'durability amount is a decrement')
events['qb-weapons:server:SetWeaponQuality']({ slot = 1 }, 100)
H.equal(#worn, 1, 'legacy arbitrary quality setter is a no-op')

events['qbinventory:server:legacyWeaponUse'](1)
H.equal(uses[1].slot, 1, 'legacy use resolves a real weapon slot')
events['qbinventory:server:legacyWeaponUse'](2)
H.equal(#uses, 1, 'legacy use cannot invoke an arbitrary item')
events['qb-weapons:server:removeWeaponAmmoItem']({ slot = 2, name = 'forged' })
H.equal(uses[2].slot, 2, 'legacy ammo removal resolves the real magazine slot')
events['qbinventory:server:legacyWeaponHolster']()
H.equal(uses[3].holster, 1, 'legacy check weapon requests a server-resolved holster')

H.finish()
