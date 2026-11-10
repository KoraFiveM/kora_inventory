-- Use-item handlers: weapon equip/holster toggle, ammo loading and parachute.
-- Consumables live in kora_consumables. Registered here via
-- kora_inventory's explicit server API (defined in server.lua and available by
-- this file's manifest load position) rather than
-- exports.kora_core:createUseable: kora_inventory's OWN useables table is what
-- actually powers the NUI's Use button (see hasUseable/buildItem in
-- server.lua); a handler registered on kora_core's separate useables table is
-- never consulted by kora_inventory's use flow.

local api = assert(KoraInventory and KoraInventory.api, 'kora_inventory server authority must load before useables')
local internal = assert(KoraInventory.internal, 'kora_inventory internal API must load before useables')

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
    local carry = KoraInventory.weaponCarry
    if carry then
        return carry.toggle(src, item)
    end
    -- weaponcarry.lua is a sibling module, not a dependency: without it a
    -- weapon still equips, just instantly and with nothing shown on the back.
    TriggerClientEvent(
        'kora_inventory:client:toggleWeapon',
        src,
        { name = item.name, slot = item.slot, action = 'toggle', duration = 0 }
    )
    return true -- successful use; item remains in inventory because no removal is performed
end

local function refreshWeaponUseable(name, def)
    -- weapon_unarmed isn't a real carryable item -- nothing stocks/loots it.
    internal.setBuiltInUseable(
        name,
        def and name ~= 'weapon_unarmed' and weaponUseable or nil,
        'weapon'
    )
end

for _, def in ipairs(exports.kora_core:allShared('weapons')) do
    refreshWeaponUseable(def.name, def)
end
exports.kora_core:onSharedChange('weapons', function(_, name, def)
    refreshWeaponUseable(name, def)
end)

-- Food, drink, alcohol and smokes are NOT handled here. kora_consumables owns every
-- consumable (progress bar, prop, status effects, removal on finish); this resource
-- only registers weapon, ammo and parachute use.

-- Loading a magazine into the weapon in the player's hands.
--
-- Before this, no ammo useable was registered at all: `pistol_ammo` and the
-- rest were stocked by Ammu-Nation, defined with an `ammoType` and a `rounds`
-- count in kora_core's shared items, and completely inert -- every weapon sat at
-- zero rounds forever with no way to load one.
--
-- Which weapon is being loaded is resolved on the SERVER, from
-- weaponcarry's `equipped` record. That record is only ever set after the
-- client confirms a draw the server itself asked for, and is re-validated
-- against kora_core-owned PlayerData at that point -- so the client contributes
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
    local def = KoraInventory.internal.itemDef(item.name)
    local rounds = math.floor(tonumber(def and def.rounds) or 0)
    if not def or not def.ammoType or rounds <= 0 then
        return false, 'not usable ammunition'
    end

    local carry = KoraInventory.weaponCarry
    local holding = carry and carry.equippedWeapon(src)
    if not holding then
        return false, 'draw a weapon before loading ammunition'
    end

    local weaponDef = KoraInventory.internal.itemDef(holding.name)
    if not weaponDef or weaponDef.ammotype ~= def.ammoType then
        return false,
            ('%s does not take %s'):format(
                weaponDef and (weaponDef.label or weaponDef.name) or 'that weapon',
                def.label or def.name
            )
    end

    -- Persist each round before telling the client to add it. The client
    -- event is presentation-only; weapon metadata is the authoritative
    -- magazine and has one record per loaded round.
    local state = KoraInventory.weapons
            and KoraInventory.weapons.getState
            and KoraInventory.weapons.getState(src, holding.slot)
        or {}
    local current = math.floor(tonumber(state and state.ammo) or 0)
    local weaponConfig = Config.kora_inventory.weapons or {}
    local ceiling = math.floor(tonumber(weaponConfig.maxAmmo) or 0)
    local ballisticCap = math.floor(tonumber((weaponConfig.ballistics or {}).maxLoadedRounds) or ceiling)
    if ceiling > 0 and ballisticCap > 0 then
        ceiling = math.min(ceiling, ballisticCap)
    end
    if ceiling <= 0 then
        return false, 'weapon ammunition capacity is not configured'
    end
    if current + rounds > ceiling then
        return false, 'not enough room for that magazine'
    end

    local loadRounds = KoraInventory.weapons and KoraInventory.weapons.loadRounds
    if not loadRounds then
        return false, 'weapon ballistics state unavailable'
    end
    local saved, stateOrErr = loadRounds(src, holding.slot, def.ammoType, rounds)
    if not saved then
        return false, stateOrErr
    end
    local target = math.floor(tonumber(stateOrErr and stateOrErr.ammo) or 0)

    local removed, removeErr = api.removeItem(src, item.name, 1, item.slot, 'loaded ammunition')
    if not removed then
        -- Do not leave a durable ammo increase behind when the magazine could
        -- not be charged. `setAmmo` only touches the same server-resolved
        -- weapon slot, so this restores the pre-use value without consulting
        -- any client state.
        local setAmmo = KoraInventory.weapons and KoraInventory.weapons.setAmmo
        if setAmmo then
            setAmmo(src, holding.slot, current)
        end
        return false, removeErr
    end

    -- The weapon NAME comes from the server's own equipped record, so the
    -- client is told what to load rather than asked. The cap is config, and the
    -- client clamps against the weapon's own maximum on top of it.
    TriggerClientEvent('kora_inventory:client:addAmmo', src, {
        weapon = holding.name,
        rounds = rounds,
        -- Send the absolute amount rather than a delta: if shots were fired
        -- while a reload was in progress the client still converges on the
        -- server's durable value.
        ammo = target,
        maxAmmo = ceiling,
    })
    return true
end

-- Every ammo item in the shared registry, found by the fields that MAKE it one
-- (`ammoType` + `rounds`) rather than by a name pattern, so a server adding its
-- own magazine item gets a working use with no change here.
local function refreshAmmoUseable(name, def)
    local isAmmo = def and def.ammoType and tonumber(def.rounds) and tonumber(def.rounds) > 0
    internal.setBuiltInUseable(name, isAmmo and ammoUseable or nil, 'ammo')
end

for _, def in ipairs(exports.kora_core:allShared('items')) do
    refreshAmmoUseable(def.name, def)
end
exports.kora_core:onSharedChange('items', function(_, name, def)
    refreshAmmoUseable(name, def)
end)

-- Parachute. Using the item shows a progress bar on the client, hands the
-- player GADGET_PARACHUTE (and the visible pack, see client/useables.lua) and
-- consumes one. The ped's weapons live on the client, so the handler asks the
-- client and WAITS for its answer: the slot stays locked against drop/give/move
-- for the whole bar (see the mid-use lock in server.lua) and the item is only
-- consumed when the client reports the parachute was actually equipped. A
-- cancelled bar, a dead player or one already wearing a parachute keeps the item.
local PARACHUTE_ITEM = 'parachute'
-- A real bar cannot come back sooner than its duration; allow some slack.
local PARACHUTE_FINISH_TOLERANCE = 500

local function builtinConfig()
    return Config.kora_inventory.builtinUsables or {}
end

local function parachuteUseable(src, item)
    local duration = math.max(0, math.floor(tonumber(builtinConfig().parachuteTime) or 2500))
    local startedAt = GetGameTimer()
    local ok, equipped = pcall(Kora.callback.trigger, src, 'kora_inventory:client:useParachute', {
        time = duration,
        tint = tonumber(builtinConfig().parachuteTint),
    })
    if not ok or equipped ~= true then
        return false
    end
    -- The client reports its own result, so a modified client could answer at once.
    if GetGameTimer() - startedAt < duration - PARACHUTE_FINISH_TOLERANCE then
        return false
    end
    local owned = api.getItemBySlot(src, item.slot)
    if not owned or owned.name ~= PARACHUTE_ITEM then
        return false
    end
    api.removeItem(src, PARACHUTE_ITEM, 1, item.slot, 'used parachute')
    return true
end

if builtinConfig().parachute ~= false then
    internal.setBuiltInUseable(PARACHUTE_ITEM, parachuteUseable)
end
