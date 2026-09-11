-- Client weapon-damage settings are presentation-side native calls, but they
-- must be bound to qbinventory's draw lifecycle rather than a permanent loop.
local H = dofile('test/harness.lua')

local events, cacheHandlers, damageCalls, criticalCalls, sent = {}, {}, {}, {}, {}
local currentWeapon = 0

Config = { qbinventory = { weaponCarry = { enabled = false } } }
QB = {
    cache = {
        ped = function() return 42 end,
        weapon = function() return currentWeapon end,
        onChange = function(name, callback) cacheHandlers[name] = callback end,
    },
    progressbar = { start = function() return true end },
}

RegisterNetEvent = function(name, callback) events[name] = callback end
AddEventHandler = function() end
TriggerServerEvent = function(name, ...)
    sent[#sent + 1] = { name = name, args = { ... } }
end
joaat = function(name) return 'hash:' .. name end
HasPedGotWeapon = function() return false end
GiveWeaponToPed = function() end
SetPedAmmo = function() end
SetPedWeaponTintIndex = function() end
SetCurrentPedWeapon = function(_, weapon) currentWeapon = weapon end
SetWeaponDamageModifier = function(weapon, modifier)
    damageCalls[#damageCalls + 1] = { weapon = weapon, modifier = modifier }
end
SetPedSuffersCriticalHits = function(_, enabled) criticalCalls[#criticalCalls + 1] = enabled end
GetAmmoInPedWeapon = function() return 0 end
RemoveWeaponFromPed = function() end
GetCurrentResourceName = function() return 'qbinventory' end

dofile('client/weaponcarry.lua')

events['qbinventory:client:toggleWeapon']({
    name = 'weapon_pistol', slot = 1, action = 'draw', duration = 0, ammo = 0,
    damage = { modifier = 0.8, disableCriticalHits = true },
})
H.equal(damageCalls[1].weapon, 'hash:weapon_pistol', 'damage is applied to the weapon just drawn')
H.equal(damageCalls[1].modifier, 0.8, 'the shared modifier reaches the native')
H.equal(criticalCalls[1], false, 'the shared critical-hit setting reaches the native')

events['qbinventory:client:toggleWeapon']({ name = 'weapon_pistol', slot = 1, action = 'holster', duration = 0 })
H.equal(damageCalls[2].modifier, 1.0, 'holstering restores GTA damage immediately')
H.equal(criticalCalls[2], true, 'holstering restores critical hits immediately')

events['qbinventory:client:toggleWeapon']({
    name = 'weapon_bat', slot = 2, action = 'draw', duration = 0, ammo = 0,
    damage = { modifier = 0.4, disableCriticalHits = true },
})
cacheHandlers.weapon('hash:weapon_unarmed')
H.equal(damageCalls[4].modifier, 1.0, 'switching away resets damage without polling')
H.equal(criticalCalls[4], true, 'switching away restores critical hits without polling')
H.equal(sent[#sent].name, 'qbinventory:server:weaponUnequipped', 'switching away reports the server-owned unequip')

H.finish()
