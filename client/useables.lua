-- Client half of server/useables.lua (parachute pack).
--
-- The weapon equip/holster toggle used to live here too. It moved to
-- client/weaponcarry.lua, which owns the whole draw: the timing, the
-- animation, and the carried prop that has to come off the player's back as
-- the weapon reaches their hands.

local PARACHUTE_ANIM = { dict = 'clothingshirt', clip = 'try_shirt_positive_d', flag = 49 }
local BAG_COMPONENT = 5

-- Puts the parachute pack on the ped's back (bag component) and returns what
-- was there so it can be restored. Freemode peds only: other models have no
-- matching bag drawable. Disabled with builtinUsables.parachuteBag.enabled = false.
local function wearParachutePack(ped)
    local bag = (Config.kora_inventory.builtinUsables or {}).parachuteBag
    if type(bag) ~= 'table' or bag.enabled == false then
        return nil
    end
    local model = GetEntityModel(ped)
    local sex = (model == joaat('mp_m_freemode_01') and 'male') or (model == joaat('mp_f_freemode_01') and 'female') or nil
    local look = sex and bag[sex]
    if type(look) ~= 'table' or tonumber(look.drawable) == nil then
        return nil
    end
    local previous = {
        drawable = GetPedDrawableVariation(ped, BAG_COMPONENT),
        texture = GetPedTextureVariation(ped, BAG_COMPONENT),
        palette = GetPedPaletteVariation(ped, BAG_COMPONENT),
    }
    local worn = { drawable = math.floor(look.drawable), texture = math.floor(tonumber(look.texture) or 0) }
    SetPedComponentVariation(ped, BAG_COMPONENT, worn.drawable, worn.texture, 0)
    return previous, worn
end

-- Local mirror of the cached ped so the wait loop below reads an upvalue instead
-- of making an export call every iteration.
local currentPed = Kora.cache.ped()
Kora.cache.onChange('ped', function(ped) currentPed = ped end)

-- Restores the previous bag once the parachute is deployed or gone. Nothing is
-- touched if the player changed their bag meanwhile (e.g. via the clothing menu).
local function restoreBagWhenDone(ped, chute, previous, worn)
    CreateThread(function()
        Wait(1000)
        while currentPed == ped and not IsPedDeadOrDying(ped, true) do
            local state = GetPedParachuteState(ped)
            if not HasPedGotWeapon(ped, chute, false) or state >= 1 then
                break
            end
            Wait(500)
        end
        if DoesEntityExist(ped)
            and GetPedDrawableVariation(ped, BAG_COMPONENT) == worn.drawable
            and GetPedTextureVariation(ped, BAG_COMPONENT) == worn.texture
        then
            SetPedComponentVariation(ped, BAG_COMPONENT, previous.drawable, previous.texture, previous.palette)
        end
    end)
end

-- Server callback: runs the equip progress bar and gives the parachute. The
-- server waits on the answer (true = equipped), which keeps the item locked
-- mid-use and lets it consume the item only on success.
Kora.callback.register('kora_inventory:client:useParachute', function(request)
    local chute = joaat('gadget_parachute')
    local ped = Kora.cache.ped()
    if HasPedGotWeapon(ped, chute, false) then
        Kora.notify.send({
            title = Kora.lang('inventory.title'),
            message = Kora.lang('inventory.parachute_equipped'),
            type = 'error',
        })
        return false
    end

    local duration = math.floor(tonumber(request and request.time) or 0)
    if duration > 0 then
        local started, completed = pcall(Kora.progressbar.start, {
            label = Kora.lang('inventory.parachute_equipping'),
            duration = duration,
            canCancel = true,
            anim = { dict = PARACHUTE_ANIM.dict, clip = PARACHUTE_ANIM.clip, flag = PARACHUTE_ANIM.flag },
        })
        if not started or completed ~= true then
            return false
        end
    end
    if Kora.cache.ped() ~= ped or IsPedDeadOrDying(ped, true) then
        return false
    end

    GiveWeaponToPed(ped, chute, 1, false, true)
    local tint = tonumber(request and request.tint)
    if tint then
        SetPedParachuteTintIndex(ped, math.floor(tint))
    end
    local previous, worn = wearParachutePack(ped)
    if previous then
        restoreBagWhenDone(ped, chute, previous, worn)
    end
    return true
end)
