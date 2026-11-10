-- Client half of server/weaponcarry.lua: renders every player's carried
-- weapons, and plays out the draw/holster this client was asked for.
--
-- Nothing here is authority. The carried list arrives on a server-set,
-- replicated player state bag and is only ever rendered; the local half of
-- the toggle only reports that the animation the server asked for actually
-- finished, and the server re-checks real possession before believing it.

local config = Config.kora_inventory
local carryConfig = config.weaponCarry or {}
local STATE_KEY = 'kora_inventory:weaponCarry'

local function vec(point, fallbackZero)
    if type(point) ~= 'table' then
        return fallbackZero and vector3(0.0, 0.0, 0.0) or nil
    end
    return vector3(tonumber(point.x) or 0.0, tonumber(point.y) or 0.0, tonumber(point.z) or 0.0)
end

-- The weapon this client believes it is holding because of a kora_inventory
-- draw. Used only to notice the weapon leaving their hands by some other
-- route (weapon wheel, disarm, death) so the server can put the prop back.
local drawn
local drawnSlot
local drawnName
local drawnThrowable = false
-- A drawn throwable's last round has been spent and the throw is still
-- playing out; see the weapon onChange handler below.
local throwing = false
-- Time the throw animation needs to release the grenade after attack is let go.
local THROW_RELEASE_MS = 1000
-- Longest a cooked grenade is waited on while attack is held.
local THROW_HOLD_MAX_MS = 10000
local toggling = false
local trainingWeapon
local modifiedWeapon
local criticalHitsDisabled = false
local lastShotAt
local lastShotPed

local function resetShotCadence()
    lastShotAt, lastShotPed = nil, nil
end

-- Damage tuning is applied as part of a confirmed inventory draw rather than
-- in a polling loop. Reset it immediately when that weapon leaves the hand so
-- another resource's weapon is never affected by this inventory setting.
local function clearDamageSettings()
    if modifiedWeapon then
        SetWeaponDamageModifier(modifiedWeapon, 1.0)
        modifiedWeapon = nil
    end
    if criticalHitsDisabled then
        SetPedSuffersCriticalHits(Kora.cache.ped(), true)
        criticalHitsDisabled = false
    end
end

local function applyDamageSettings(weapon, settings)
    clearDamageSettings()
    local modifier = tonumber(type(settings) == 'table' and settings.modifier) or 1.0
    if modifier < 0 then
        modifier = 1.0
    end
    if modifier ~= 1.0 then
        SetWeaponDamageModifier(weapon, modifier)
        modifiedWeapon = weapon
    end
    if type(settings) == 'table' and settings.disableCriticalHits == true then
        SetPedSuffersCriticalHits(Kora.cache.ped(), false)
        criticalHitsDisabled = true
    end
end

local function reportUnequipped()
    if not drawn then
        return
    end
    clearDamageSettings()
    drawn = nil
    drawnSlot = nil
    drawnName = nil
    drawnThrowable = false
    resetShotCadence()
    TriggerServerEvent('kora_inventory:server:weaponUnequipped')
end

---Take a drawn weapon out of the ped's hands and clear the carry state,
---because the item that backed it is no longer in the inventory.
local function stripDrawn(name)
    local hash = name and joaat(name) or drawn
    local ped = Kora.cache.ped()
    if hash and hash ~= joaat('weapon_unarmed') then
        if Kora.cache.weapon() == hash then
            SetCurrentPedWeapon(ped, joaat('weapon_unarmed'), true)
        end
        RemoveWeaponFromPed(ped, hash)
    end
    clearDamageSettings()
    resetShotCadence()
    drawn, drawnSlot, drawnName = nil, nil, nil
    drawnThrowable = false
end

-- The server saw the equipped item leave the inventory (dropped, given, moved
-- into a container, removed or sold).
RegisterNetEvent('kora_inventory:client:weaponRemoved', function(name)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    if type(name) ~= 'string' then
        return
    end
    if drawn == joaat(name) then
        stripDrawn(name)
    elseif not drawn and not toggling then
        -- A draw confirmed after the item had already gone.
        local hash = joaat(name)
        if HasPedGotWeapon(Kora.cache.ped(), hash, false) then
            stripDrawn(name)
        end
    end
end)

---The animation for one draw/holster.
---
---Per-tier first, then the single fallback. A tier set to `false` in
---drawAnims/holsterAnims means "no animation for this class" and must NOT fall
---through to the generic one, so the two lookups are kept apart rather than
---collapsed into an `or` chain.
---@param action string
---@param tier string|nil
---@return table|nil
local function toggleAnim(action, tier)
    local perTier = action == 'holster' and carryConfig.holsterAnims or carryConfig.drawAnims

    if tier and type(perTier) == 'table' then
        local entry = perTier[tier]
        if entry == false then
            return nil
        end
        if type(entry) == 'table' then
            return entry
        end
    end

    local fallback = action == 'holster' and carryConfig.holsterAnim or carryConfig.drawAnim
    return type(fallback) == 'table' and fallback or nil
end

---Run the draw/holster animation for `duration`, reporting whether it ran to
---completion. A zero duration keeps the original instant behaviour.
---@param action string
---@param duration integer
---@param label string
---@param tier string|nil Weapon class tier, chosen by the server.
---@return boolean completed
local function playToggle(action, duration, label, tier)
    if duration <= 0 then
        return true
    end
    local anim = toggleAnim(action, tier)
    return Kora.progressbar.start({
        label = label,
        duration = duration,
        -- A draw is committed once started: cancelling it would be a free way
        -- to skip the concealment surcharge by tapping the item repeatedly.
        canCancel = false,
        disable = carryConfig.disable,
        anim = type(anim) == 'table' and {
            dict = anim.dict,
            clip = anim.clip,
            flag = anim.flag,
        } or nil,
    }) == true
end

RegisterNetEvent('kora_inventory:client:toggleWeapon', function(request)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    if type(request) ~= 'table' or type(request.name) ~= 'string' then
        return
    end
    -- One draw at a time. Without this a player could start several bars and
    -- have each of them confirm the same slot. A throw in progress must
    -- finish first, or its consume would be lost to the new draw.
    if toggling or throwing then
        return
    end

    local ped = Kora.cache.ped()
    local hash = joaat(request.name)
    -- 'toggle' is the fallback shape server/useables.lua emits when
    -- weaponcarry.lua is not loaded; resolve it the way that code used to.
    local action = request.action
    if action ~= 'draw' and action ~= 'holster' then
        action = Kora.cache.weapon() == hash and 'holster' or 'draw'
    end

    toggling = true
    local completed = playToggle(
        action,
        math.floor(tonumber(request.duration) or 0),
        request.label or request.name,
        type(request.tier) == 'string' and request.tier or nil
    )
    toggling = false
    if not completed then
        return
    end

    -- Re-read the ped: a respawn during a long concealed draw would have
    -- replaced the handle the bar started with.
    ped = Kora.cache.ped()
    resetShotCadence()
    if action == 'holster' then
        SetCurrentPedWeapon(ped, joaat('weapon_unarmed'), true)
        clearDamageSettings()
        drawn = nil
        drawnSlot = nil
        drawnName = nil
        drawnThrowable = false
    else
        local ammo = math.max(0, math.floor(tonumber(request.ammo) or 0))
        if not HasPedGotWeapon(ped, hash, false) then
            GiveWeaponToPed(ped, hash, ammo, false, true)
        end
        SetPedAmmo(ped, hash, ammo)
        for _, component in ipairs(type(request.components) == 'table' and request.components or {}) do
            local componentHash = type(component) == 'string' and joaat(component) or tonumber(component)
            if componentHash then
                GiveWeaponComponentToPed(ped, hash, componentHash)
            end
        end
        local tint = math.floor(tonumber(request.tint) or 0)
        if tint >= 0 and tint <= 32 then
            SetPedWeaponTintIndex(ped, hash, tint)
        end
        SetCurrentPedWeapon(ped, hash, true)
        applyDamageSettings(hash, request.damage)
        drawn = hash
        drawnSlot = tonumber(request.slot)
        drawnName = request.name
        drawnThrowable = request.throwable == true
    end

    if request.slot then
        TriggerServerEvent('kora_inventory:server:weaponToggled', request.slot)
    end
end)

-- Loading a magazine. The weapon is named BY THE SERVER, from its own record of
-- what this player drew (server/useables.lua's ammoUseable) -- this client is
-- told what to load, and contributes nothing to the decision.
--
-- GiveWeaponToPed rather than AddAmmoToPed alone: ammo can only sit on a weapon
-- the ped actually has, and a weapon-wheel switch mid-use can leave the ped
-- momentarily without it. Giving it back with 0 rounds is a no-op when the ped
-- already holds it and repairs the case where it does not, so the magazine the
-- server has already consumed is never silently lost.
RegisterNetEvent('kora_inventory:client:addAmmo', function(request)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    if type(request) ~= 'table' or type(request.weapon) ~= 'string' then
        return
    end

    local rounds = math.floor(tonumber(request.rounds) or 0)
    if rounds <= 0 then
        return
    end

    local ped = Kora.cache.ped()
    local hash = joaat(request.weapon)

    if not HasPedGotWeapon(ped, hash, false) then
        GiveWeaponToPed(ped, hash, 0, false, false)
    end

    -- Clamped twice: against the weapon's own engine maximum, which is what
    -- stops a magazine overfilling a weapon, and against the configured
    -- ceiling, which is a server policy on top of it.
    local _, maxAmmo = GetMaxAmmo(ped, hash)
    local ceiling = math.floor(tonumber(request.maxAmmo) or 0)
    if ceiling > 0 then
        maxAmmo = maxAmmo and maxAmmo > 0 and math.min(maxAmmo, ceiling) or ceiling
    end

    local target = math.floor(tonumber(request.ammo) or -1)
    if target < 0 then
        -- Backwards-compatible shape for callers from before ammo was
        -- persisted by the server. kora_inventory itself sends `ammo` above.
        target = (GetAmmoInPedWeapon(ped, hash) or 0) + rounds
    end
    if maxAmmo and maxAmmo > 0 then
        target = math.min(target, maxAmmo)
    end

    SetPedAmmo(ped, hash, target)
end)

RegisterNetEvent('kora_inventory:client:startTrainingWeapon', function(name, rounds, damage)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    if type(name) ~= 'string' then
        return
    end
    local ped = Kora.cache.ped()
    resetShotCadence()
    trainingWeapon = joaat(name)
    GiveWeaponToPed(ped, trainingWeapon, math.max(0, math.floor(tonumber(rounds) or 0)), false, true)
    SetCurrentPedWeapon(ped, trainingWeapon, true)
    applyDamageSettings(trainingWeapon, damage)
end)

RegisterNetEvent('kora_inventory:client:stopTrainingWeapon', function()
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    if not trainingWeapon then
        return
    end
    clearDamageSettings()
    RemoveWeaponFromPed(Kora.cache.ped(), trainingWeapon)
    trainingWeapon = nil
    resetShotCadence()
end)

-- A drawn weapon can leave the player's hands without a holster: the weapon
-- wheel, a disarm, death, a respawn. Tell the server so the prop goes back on
-- their body instead of vanishing for everyone until their next use.
Kora.cache.onChange('weapon', function(weapon)
    if not drawn or weapon == drawn or throwing then
        return
    end
    -- A drawn throwable that left the hand empty was thrown: the server
    -- consumes the item. GTA spends the round and moves the selection off
    -- the throwable as the pin is pulled, while the grenade is still in the
    -- hand -- forcing a weapon or stripping the item now cancels the throw.
    -- So wait for it to leave the hand before acting on it.
    if drawnThrowable and (GetAmmoInPedWeapon(Kora.cache.ped(), drawn) or 0) <= 0 then
        local thrown = drawn
        throwing = true
        CreateThread(function()
            -- Holding attack keeps a cooked grenade in the hand.
            local deadline = GetGameTimer() + THROW_HOLD_MAX_MS
            while (IsControlPressed(0, 24) or IsDisabledControlPressed(0, 24)) and GetGameTimer() < deadline do
                Wait(0)
            end
            Wait(THROW_RELEASE_MS)
            throwing = false
            -- Death or the item being removed meanwhile already cleared it.
            if drawn ~= thrown then
                return
            end
            -- Sent before weaponUnequipped so the server still sees the slot
            -- as drawn.
            TriggerServerEvent('kora_inventory:server:throwableThrown')
            SetCurrentPedWeapon(Kora.cache.ped(), joaat('weapon_unarmed'), true)
            reportUnequipped()
        end)
        return
    end
    reportUnequipped()
end)
-- Safety net for the server event above: after every replicated inventory
-- update, a drawn weapon must still be backed by its item in its slot.
exports.kora_core:onPlayerDataChange({ 'items' }, function()
    if not drawn or not drawnSlot or not drawnName or toggling then
        return
    end
    local data = exports.kora_core:getPlayerData()
    local item = type(data) == 'table' and type(data.items) == 'table' and data.items[drawnSlot] or nil
    if type(item) == 'table' and tostring(item.name):lower() == drawnName:lower() then
        return
    end
    local name = drawnName
    reportUnequipped()
    stripDrawn(name)
end)

Kora.cache.onChange('isDead', function(isDead)
    if isDead then
        reportUnequipped()
        resetShotCadence()
        if trainingWeapon then
            clearDamageSettings()
            RemoveWeaponFromPed(Kora.cache.ped(), trainingWeapon)
            trainingWeapon = nil
        end
    end
end)

-- A running emote (kora_emotemenu replicates `kora_emotemenu:active` as the emote
-- name, or false) owns the hands: a drawn weapon would hang off the prop pose
-- and still aim and fire. Holster it -- the weaponUnequipped report puts the
-- prop back on the player's body -- and keep aim/fire disabled until it ends.
local EMOTE_KEY = 'kora_emotemenu:active'
local EMOTE_BLOCKED_CONTROLS = { 24, 25, 37, 47, 68, 69, 70, 91, 92, 140, 141, 142, 257, 263, 264 }
local emoteGuard = false

local function holsterForEmote()
    if not drawn or toggling then
        return
    end
    SetCurrentPedWeapon(Kora.cache.ped(), joaat('weapon_unarmed'), true)
    reportUnequipped()
end

Kora.state.onChange(EMOTE_KEY, nil, function(context)
    if carryConfig.holsterOnEmote == false or not context.value or emoteGuard then
        return
    end
    if context.bagName ~= ('player:%d'):format(Kora.cache.serverId() or -1) then
        return
    end
    emoteGuard = true
    CreateThread(function()
        while LocalPlayer.state[EMOTE_KEY] do
            holsterForEmote()
            DisablePlayerFiring(PlayerId(), true)
            for _, control in ipairs(EMOTE_BLOCKED_CONTROLS) do
                DisableControlAction(0, control, true)
            end
            Wait(0)
        end
        emoteGuard = false
    end)
end)

-- Persist only ammunition that has been consumed. The server checks both the
-- slot and its own equipped record, and refuses any report that would raise
-- ammo, so this cannot turn the native client weapon count into an item-mint.
AddEventHandler('CEventGunShot', function(_, eventEntity)
    if not trainingWeapon and (not drawn or not drawnSlot) then
        return
    end
    -- While a thrown grenade is being settled the slot still reads as the
    -- throwable, but whatever GTA auto-selected is what fired. Do not bill
    -- those shots to the throwable's slot.
    if throwing and not trainingWeapon then
        return
    end
    local ped = PlayerPedId()
    if eventEntity ~= ped then
        return
    end
    local ballistics = ((config.weapons or {}).ballistics or {})
    -- The server already knows the equipped slot. Never submit a claimed ammo
    -- amount, weapon hash, coordinates, serial, or casing from this client.
    if trainingWeapon or ballistics.enabled == true then
        local now = GetGameTimer()
        local minGap = math.max(0, math.floor(tonumber(ballistics.shotCooldown) or 65))
        -- GTA can deliver several gunshot callbacks. Avoid sending reports
        -- inside the same cadence floor the server already enforces.
        if lastShotPed == ped and lastShotAt and now - lastShotAt < minGap then
            return
        end
        lastShotAt, lastShotPed = now, ped
        TriggerServerEvent('kora_inventory:server:weaponFired')
    else
        -- Retain the older lower-only persistence path when a server owner
        -- deliberately turns forensic round tracking off.
        TriggerServerEvent(
            'kora_inventory:server:weaponAmmoConsumed',
            drawnSlot,
            GetAmmoInPedWeapon(ped, drawn) or 0
        )
    end
end)

-- Logout / character switch: the drawn weapon (and its ammo) belongs to the
-- character that is leaving; the server forgets it on the same event.
RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    if drawn then
        stripDrawn()
    end
    if trainingWeapon then
        RemoveWeaponFromPed(Kora.cache.ped(), trainingWeapon)
        trainingWeapon = nil
    end
end)

AddEventHandler('onClientResourceStop', function(name)
    if name ~= GetCurrentResourceName() then
        return
    end
    -- The server forgets every equipped weapon when it stops; a weapon left in
    -- hand would fire untracked rounds until the next draw.
    if drawn then
        stripDrawn()
    end
    clearDamageSettings()
    if trainingWeapon then
        RemoveWeaponFromPed(Kora.cache.ped(), trainingWeapon)
        trainingWeapon = nil
    end
end)

-- --- carried props ----------------------------------------------------------

if carryConfig.enabled ~= true then
    return
end

-- serverId -> { entity, ... } for every player this client has rendered,
-- including itself.
local rendered = {}

local function destroy(entities)
    for _, entity in ipairs(entities or {}) do
        if entity and DoesEntityExist(entity) then
            DeleteEntity(entity)
        end
    end
end

local function clearPlayer(serverId)
    local entities = rendered[serverId]
    if not entities then
        return
    end
    rendered[serverId] = nil
    destroy(entities)
end

---Resolve the ped for a `player:<serverId>` bag, waiting briefly for it to
---stream in. Returns 0 when that player never became renderable here.
---@param serverId integer
---@return integer ped
local function pedFor(serverId)
    local playerId = GetPlayerFromServerId(serverId)
    if playerId == -1 then
        return 0
    end
    local ped = GetPlayerPed(playerId)
    if ped and ped > 0 then
        return ped
    end
    local resolved = 0
    Kora.loops.controlled(function()
        local id = GetPlayerFromServerId(serverId)
        local candidate = id ~= -1 and GetPlayerPed(id) or 0
        if candidate and candidate > 0 then
            resolved = candidate
            return true
        end
    end, false, 5000, true)
    return resolved
end

---Take the next unused attachment position in a tier, or nil when that tier
---is already full -- an extra weapon is dropped rather than stacked into a
---position another one is already using.
---@param used table<string, integer>
---@param tier string
---@return table|nil
local function nextAttachment(used, tier)
    local positions = (carryConfig.attachments or {})[tier]
    if type(positions) ~= 'table' then
        return nil
    end
    local index = (used[tier] or 0) + 1
    if index > #positions then
        return nil
    end
    used[tier] = index
    return positions[index]
end

---Create the entity for one carried item: a plain prop when the server sent a
---`model`, otherwise the weapon itself so attachments and tint show.
---@param carried table
---@return integer entity
local function createCarried(carried)
    if carried.model then
        local model = Kora.stream.loadModel(carried.model)
        if not model then
            return 0
        end
        local object = CreateObject(model, 0.0, 0.0, 0.0, false, false, false)
        SetModelAsNoLongerNeeded(model)
        return object or 0
    end

    -- A configured override can name something that is not a real weapon.
    -- Kora.stream.loadWeaponAsset asserts on that, so check first: an entry
    -- with neither a valid weapon nor a `model` simply renders nothing.
    if not IsWeaponValid(joaat(carried.name)) then
        return 0
    end

    local entity = 0
    Kora.stream.loadWeaponAsset(carried.name, function(hash)
        entity = CreateWeaponObject(hash, 0, 0.0, 0.0, 0.0, true, 1.0, 0, false, true) or 0
        if entity == 0 then
            return
        end
        for _, component in ipairs(carried.components or {}) do
            local componentHash = type(component) == 'string' and joaat(component) or tonumber(component)
            if componentHash then
                GiveWeaponComponentToWeaponObject(entity, componentHash)
            end
        end
        if carried.tint then
            SetWeaponObjectTintIndex(entity, carried.tint)
        end
    end)
    return entity
end

-- Rendering yields (streaming a weapon asset, waiting for a ped), so two
-- overlapping renders for the same player -- a bag change landing while a
-- respawn rebuild is still waiting -- would both attach their entities and
-- leak one set. Each render claims a generation and abandons its work if a
-- newer one started meanwhile.
local generation = {}

---Render one player's whole carried list, replacing whatever was on them.
---@param serverId integer
---@param list table[]|false|nil
local function render(serverId, list)
    local mine = (generation[serverId] or 0) + 1
    generation[serverId] = mine
    clearPlayer(serverId)
    if type(list) ~= 'table' or #list == 0 then
        return
    end

    local ped = pedFor(serverId)
    if ped == 0 or generation[serverId] ~= mine then
        return
    end

    local entities, used = {}, {}
    for _, carried in ipairs(list) do
        local attachment = nextAttachment(used, carried.tier)
        -- A per-item override may supply its own geometry; it still consumes
        -- a tier position so two overridden weapons don't land on each other.
        local bone = tonumber(carried.bone) or (attachment and attachment.bone)
        local pos = vec(carried.pos) or (attachment and vec(attachment.pos, true))
        local rot = vec(carried.rot) or (attachment and vec(attachment.rot, true))
        if bone and pos and rot then
            local entity = createCarried(carried)
            if entity and entity > 0 then
                AttachEntityToEntity(
                    entity,
                    ped,
                    GetPedBoneIndex(ped, bone),
                    pos.x,
                    pos.y,
                    pos.z,
                    rot.x,
                    rot.y,
                    rot.z,
                    true,
                    true,
                    false,
                    false,
                    2,
                    true
                )
                SetEntityCompletelyDisableCollision(entity, false, true)
                entities[#entities + 1] = entity
            end
        end
    end
    if generation[serverId] ~= mine then
        -- Superseded while streaming: these entities belong to nobody now.
        destroy(entities)
        return
    end
    rendered[serverId] = entities
end

---`player:<serverId>` -> the server id, or nil for any other bag.
---@param bagName string
---@return integer|nil
local function serverIdFromBag(bagName)
    if type(bagName) ~= 'string' then
        return nil
    end
    local id = bagName:match('^player:(%-?%d+)$')
    return id and tonumber(id) or nil
end

-- No bag filter: this subscribes to every player's bag rather than one name,
-- so it is registered at load without waiting for a session. (A handler bound
-- to a literal `player:<id>` would have to wait -- GetPlayerServerId is -1
-- during the loading screen and AddStateBagChangeHandler binds the name once.)
Kora.state.onChange(STATE_KEY, nil, function(context)
    local serverId = serverIdFromBag(context.bagName)
    if not serverId or serverId < 0 then
        return
    end
    -- The bag arrives before its owner's ped may exist here, and rendering
    -- waits for it, so never block the state-bag callback itself.
    CreateThread(function()
        render(serverId, context.value)
    end)
end)

-- A player who leaves takes their props with them: the bag stops arriving,
-- but the entities are attached to a ped that is about to be destroyed and
-- would otherwise be left floating. `onPlayerDropped` covers the clean case;
-- the sweep below covers a player who simply streamed out of range and back
-- as a different handle, which fires no event at all.
RegisterNetEvent('onPlayerDropped', function(serverId)
    if type(serverId) == 'number' and serverId > 0 then
        clearPlayer(serverId)
    end
end)

CreateThread(function()
    while true do
        Wait(10000)
        for serverId in pairs(rendered) do
            if GetPlayerFromServerId(serverId) == -1 then
                clearPlayer(serverId)
            end
        end
    end
end)

-- A new ped (respawn, model change, clothing) drops every attachment, so the
-- local player's props have to be rebuilt onto the new handle.
Kora.cache.onChange('ped', function()
    local serverId = Kora.cache.serverId()
    if not serverId or serverId <= 0 then
        return
    end
    local list = LocalPlayer.state[STATE_KEY]
    CreateThread(function()
        render(serverId, list)
    end)
end)

AddEventHandler('onClientResourceStop', function(name)
    if name ~= GetCurrentResourceName() then
        return
    end
    for serverId in pairs(rendered) do
        destroy(rendered[serverId])
    end
    rendered = {}
end)

-- Catch-up for `ensure kora_inventory` while players are already in the world:
-- their bags were set before this handler existed, so nothing would arrive
-- until their next inventory change.
CreateThread(function()
    while not NetworkIsSessionStarted() do
        Wait(100)
    end
    Wait(500)
    for _, playerId in ipairs(GetActivePlayers()) do
        local serverId = GetPlayerServerId(playerId)
        local list = serverId > 0 and Player(serverId).state[STATE_KEY] or nil
        if type(list) == 'table' then
            render(serverId, list)
        end
    end
end)
