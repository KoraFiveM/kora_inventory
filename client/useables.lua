-- Client half of server/useables.lua: weapon equip/holster toggle, and the
-- eat/drink animation + brief screen effect for a consumed item.

RegisterNetEvent('qbinventory:client:toggleWeapon', function(weaponName)
    local ped = PlayerPedId()
    local hash = GetHashKey(weaponName)

    if GetSelectedPedWeapon(ped) == hash then
        SetCurrentPedWeapon(ped, GetHashKey('weapon_unarmed'), true)
        return
    end

    if not HasPedGotWeapon(ped, hash, false) then
        GiveWeaponToPed(ped, hash, 0, false, true)
    end
    SetCurrentPedWeapon(ped, hash, true)
end)

local EAT_ANIM = { dict = 'mp_player_inteat@burger', anim = 'mp_player_int_eat_burger', flag = 49 }
local DRINK_ANIM = { dict = 'amb@world_human_drinking@coffee@male@idle_a', anim = 'idle_c', flag = 49 }

-- Purely cosmetic: a few seconds of mild timecycle tint for a drunk/high
-- item, nothing that impairs controls -- movement/vision impairment while
-- drunk or high is a separate feature this doesn't attempt.
local function flashTimecycle(name, ms)
    SetTimecycleModifier(name)
    SetTimeout(ms, function()
        if GetTimecycleModifierIndex() ~= -1 then ClearTimecycleModifier() end
    end)
end

RegisterNetEvent('qbinventory:client:consumeEffect', function(_, effects)
    local ped = PlayerPedId()
    local anim = (effects.thirst or effects.drunk) and DRINK_ANIM or EAT_ANIM

    RequestAnimDict(anim.dict)
    local waited = 0
    while not HasAnimDictLoaded(anim.dict) and waited < 2000 do
        Wait(10)
        waited = waited + 10
    end
    if HasAnimDictLoaded(anim.dict) then
        TaskPlayAnim(ped, anim.dict, anim.anim, 8.0, -8.0, 2000, anim.flag, 0, false, false, false)
    end

    if effects.drunk then
        flashTimecycle('drug_wobbly_01', 6000)
    elseif effects.high then
        flashTimecycle('spectator5', 6000)
    end
end)
