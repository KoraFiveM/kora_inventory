-- Client compatibility for the retired qb-weapons resource.
--
-- These names are registered because older resources commonly TriggerEvent
-- them.  They never consume a client-provided weapon table locally: the table
-- is reduced to a slot and qbinventory's server re-resolves the real item.

local function slotOf(value)
    local slot = math.floor(tonumber(type(value) == 'table' and value.slot or value) or 0)
    return slot > 0 and slot or nil
end

-- qb-weapons exposed this client export for attachment UIs. Build the old
-- item -> weapon -> native-component shape from qbinventory's two explicit
-- allow-lists; nothing inferred from a caller reaches the result.
local function legacyAttachmentConfig()
    local weapons = (Config.qbinventory.weapons or {}).components or {}
    local render = (Config.qbinventory.weaponCarry or {}).components or {}
    local out = {}
    for weapon, allowed in pairs(weapons) do
        if type(weapon) == 'string' and type(allowed) == 'table' then
            for key, value in pairs(allowed) do
                local item = type(key) == 'number' and value or key
                local native = type(item) == 'string' and render[item] or nil
                if native then
                    out[item] = out[item] or {}
                    out[item][weapon] = native
                end
            end
        end
    end
    return out
end

exports('getConfigWeaponAttachments', legacyAttachmentConfig)

RegisterNetEvent('qb-weapons:client:UseWeapon', function(legacy)
    local slot = slotOf(legacy)
    if slot then TriggerServerEvent('qbinventory:server:legacyWeaponUse', slot) end
end)

RegisterNetEvent('qb-weapons:client:AddAmmo', function(_, _, legacy)
    local slot = slotOf(legacy)
    if slot then TriggerServerEvent('qbinventory:server:legacyWeaponUse', slot) end
end)

RegisterNetEvent('qb-weapons:client:CheckWeapon', function()
    TriggerServerEvent('qbinventory:server:legacyWeaponHolster')
end)

-- The two events below used to maintain qb-weapons' private client state.
-- qbinventory owns that state in client/weaponcarry.lua; accepting them as
-- no-ops avoids a stale resource error without creating competing controllers.
RegisterNetEvent('qb-weapons:client:SetCurrentWeapon', function() end)
RegisterNetEvent('qb-weapons:client:SetWeaponQuality', function() end)
RegisterNetEvent('qb-weapons:client:SyncRepairShops', function() end)

-- Tint drawing is harmless presentation and may be sent by a trusted server
-- after it persisted tint metadata through qbinventory's server-side API.
RegisterNetEvent('qb-weapons:client:EquipTint', function(weapon, tint)
    if type(weapon) ~= 'string' and type(weapon) ~= 'number' then return end
    local index = math.floor(tonumber(tint) or -1)
    if index >= 0 and index <= 32 then
        SetPedWeaponTintIndex(QB.cache.ped(), type(weapon) == 'string' and joaat(weapon) or weapon, index)
    end
end)
