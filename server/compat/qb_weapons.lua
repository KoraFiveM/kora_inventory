-- qb-weapons compatibility transport.
--
-- kora_inventory provides qb-weapons so a resource which merely depends on the
-- retired resource still starts.  These are intentionally adapters, not a
-- second weapon controller: every live weapon is still kora_inventory's item,
-- draw record and canonical metadata.  In particular, legacy tables received
-- from a client contribute at most a slot; their weapon name, serial, quality,
-- attachments and ammo count are never authority.

local inventory = assert(KoraInventory, 'kora_inventory authority missing')
local internal = assert(inventory.internal, 'kora_inventory internal authority missing')
local api = assert(inventory.api, 'kora_inventory api missing')
local weapons = assert(inventory.weapons, 'kora_inventory weapon state missing')

local function slotOf(value)
    local slot = math.floor(tonumber(type(value) == 'table' and value.slot or value) or 0)
    return slot > 0 and slot or nil
end

local function itemAt(src, value)
    local slot = slotOf(value)
    if not slot then
        return nil
    end
    local key = internal.playerKey(src)
    local resolved, inventory = internal.resolveInventory(key)
    if resolved ~= key or not inventory then
        return nil
    end
    local item = inventory.items[slot]
    if not item or not weapons.isWeapon(item) then
        return nil
    end
    return item, slot
end

-- A client may only report a value about the weapon the server itself still
-- considers drawn. This closes the old protocol's arbitrary `{slot, name}`
-- table while allowing ammunition to decrease after a shot.
local function equippedAt(src, value)
    local item, slot = itemAt(src, value)
    local carrying = inventory.weaponCarry and inventory.weaponCarry.equippedWeapon(src)
    if not item or not carrying or carrying.slot ~= slot or carrying.name ~= item.name then
        return nil
    end
    return item, slot
end

local function weaponAmmo(src, legacy)
    local _, slot = itemAt(src, legacy)
    if not slot then
        return 0
    end
    return math.floor(tonumber(weapons.getState(src, slot).ammo) or 0)
end

-- Current qb-weapons asks this callback while reconstructing its client state.
-- kora_inventory has no repair-point config of its own, so an empty configuration
-- is the compatible, no-hang response for a left-over caller.
Kora.callback.register('qb-weapons:server:GetConfig', function()
    return {}
end)
Kora.callback.register('weapon:server:GetWeaponAmmo', function(src, legacy)
    local item, slot = itemAt(src, legacy)
    if not item then
        return 0, nil
    end
    local state = weapons.getState(src, slot) or {}
    return math.floor(tonumber(state.ammo) or 0), item.name
end)

-- Repairs were a qb-weapons-owned world system (stations, money rules, mail
-- and timers), not an inventory primitive. Do not pretend a client callback
-- can authorise one; gameplay resources should perform their server-side
-- check and call SetWeaponState. Registering the old names prevents a stale
-- client from waiting forever and returns a safe refusal.
Kora.callback.register('qb-weapons:server:RepairWeapon', function()
    return false
end)
Kora.callback.register('qb-weapons:server:RemoveAttachment', function()
    return false
end)

RegisterNetEvent('kora_inventory:server:legacyWeaponUse', function(value)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    local src = source
    local _, slot = itemAt(src, value)
    if slot then
        api.useItem(src, slot)
    end
end)

RegisterNetEvent('kora_inventory:server:legacyWeaponHolster', function()
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    local src = source
    local carrying = inventory.weaponCarry and inventory.weaponCarry.equippedWeapon(src)
    local item = carrying and itemAt(src, carrying.slot)
    if item and inventory.weaponCarry then
        inventory.weaponCarry.toggle(src, item)
    end
end)

-- Old clients periodically send the ped's ammunition count.  That client
-- count can only make our durable amount go DOWN; magazine use is the only
-- route that can add rounds, and it does so server-side in useables.lua.
RegisterNetEvent('qb-weapons:server:UpdateWeaponAmmo', function(legacy, amount)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    local src = source
    local _, slot = equippedAt(src, legacy)
    local requested = math.floor(tonumber(amount) or -1)
    if not slot or requested < 0 then
        return
    end
    local current = math.floor(tonumber(weapons.getState(src, slot).ammo) or 0)
    if requested < current then
        weapons.setAmmo(src, slot, requested)
    end
end)

-- A legacy shot report may wear down only the caller's actually equipped
-- weapon. It can never improve quality; repairs must go through a server-side
-- gameplay policy and SetWeaponState.
RegisterNetEvent('qb-weapons:server:UpdateWeaponQuality', function(legacy, amount)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    local src = source
    local _, slot = equippedAt(src, legacy)
    amount = math.floor(tonumber(amount) or 0)
    if slot and amount > 0 then
        weapons.consumeDurability(src, slot, math.min(amount, 100))
    end
end)

-- Kept as a deliberate no-op. The old SetWeaponQuality event accepts an
-- arbitrary client HP value, which would let anyone repair their own weapon.
-- The similarly shaped SetWeaponState export is server-only by design.
RegisterNetEvent('qb-weapons:server:SetWeaponQuality', function()
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
end)

-- Older scripts fire this after the old client-side AddAmmo handler. Resolve
-- and use the real ammunition item from the caller's slot instead of trusting
-- its name, amount or metadata. This is equivalent to pressing Use in the
-- current inventory and therefore inherits the drawn-weapon/ammo-type checks.
RegisterNetEvent('qb-weapons:server:removeWeaponAmmoItem', function(legacy)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    local src = source
    local slot = slotOf(legacy)
    if not slot then
        return
    end
    local key = internal.playerKey(src)
    local resolved, inventory = internal.resolveInventory(key)
    local item = resolved == key and inventory and inventory.items[slot] or nil
    local definition = item and internal.itemDef(item.name)
    if definition and definition.ammoType and tonumber(definition.rounds) and tonumber(definition.rounds) > 0 then
        api.useItem(src, slot)
    end
end)

-- The retired repair flow calls this when collecting a weapon. It had a
-- resource-local repair table which no longer exists, so rejecting it is
-- safer than accepting a client-selected repair point/item.
RegisterNetEvent('qb-weapons:server:TakeBackWeapon', function()
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
end)

inventory.compat = inventory.compat or {}
inventory.compat.koraWeapons = { itemAt = itemAt, equippedAt = equippedAt, weaponAmmo = weaponAmmo }
