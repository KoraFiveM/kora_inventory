-- Visible weapon carry, plus the draw/holster pacing that goes with it.
--
-- Two halves of one feature, deliberately in one module because they share a
-- single fact: whether a given weapon was openly carried. The carried list
-- decides what other players see on a body, and "was it visible" is exactly
-- what prices a draw (see `concealedDrawTime`).
--
-- Authority. The carried list is built HERE from qbcore-owned PlayerData and
-- pushed out on a server-set, replicated player state bag. A client never
-- submits, edits or extends its own carried list -- it only renders whatever
-- bag it receives -- so this cannot become a channel for advertising items a
-- player does not own, or for hiding items they do. The only thing a client
-- may say is "the draw you asked me for finished", and even that is matched
-- against a pending request this file issued and re-resolved against the real
-- slot before it is believed.
--
-- Nothing here mutates an inventory. Equipping does not remove the weapon
-- item (see server/useables.lua's note on why v1 keeps it in the slot).

QbInventory = QbInventory or {}
local inventory = QbInventory
local internal = assert(inventory.internal, 'qbinventory authority must load before weapon carry')

local config = Config.qbinventory
local carryConfig = config.weaponCarry or {}
local weaponConfig = config.weapons or {}
local durabilityConfig = weaponConfig.durability or {}

-- Replicated. Cleared with an explicit `false`, never a nil deletion: a nil
-- write is a key DELETION and does not replicate like a value change, so a
-- client would keep rendering the last list forever.
local STATE_KEY = 'qbinventory:weaponCarry'

-- src -> { slot, name }: what this player is currently holding, so it is not
-- also drawn on their back. Confirmed by the client after the draw animation
-- completes, and cleared when they put it away, die, or drop.
local equipped = {}
-- src -> { slot, name, action, expires }: the one toggle this server asked
-- for. A confirmation that does not match it is ignored.
local pending = {}
-- Temporary server-issued range weapons are not inventory items. Their finite
-- round count still lives here so training resources never trust a client
-- claim that a shot happened.
local training = {}
-- Native gunshots are reported by the local shooter, so rate-limit the only
-- client-originating edge of the ballistic pipeline before touching metadata.
local lastShotAt = {}

local function stopTraining(src)
    if not training[src] then
        return false
    end
    training[src] = nil
    TriggerClientEvent('qbinventory:client:stopTrainingWeapon', src)
    return true
end

local trainingOwnership = Kora.resources.serverRegistry(function(src)
    stopTraining(src)
end)

local function integer(value, fallback)
    local number = math.floor(tonumber(value) or fallback or 0)
    return number >= 0 and number or 0
end

local function enabled()
    return carryConfig.enabled == true
end
local function hotbarOnly()
    return enabled() and carryConfig.visibility == 'hotbar'
end
local function hotbarSlots()
    return integer(config.hotbarSlots, 5)
end

---The carry rules for one item name, or nil when it is not carried at all.
---A registry weapon is classified automatically by its `weapontype`; anything
---else (and any exception) needs an explicit entry in `weaponCarry.weapons`.
---@param name string
---@return table|nil
local function carryRule(name)
    local override = (carryConfig.weapons or {})[name]
    if override and override.tier == false then
        return nil
    end
    local def = internal.itemDef(name)
    local tier = override and override.tier or (def and (carryConfig.tiers or {})[def.weapontype])
    if not tier then
        return nil
    end
    if not (carryConfig.attachments or {})[tier] then
        return nil
    end
    return {
        tier = tier,
        model = override and override.model or nil,
        bone = override and override.bone or nil,
        pos = override and override.pos or nil,
        rot = override and override.rot or nil,
    }
end

---Weapon components the client is allowed to render on a carried weapon.
---Only names explicitly mapped in `weaponCarry.components` survive, so an
---item's stored metadata cannot ask for an arbitrary native component.
local function renderableComponents(info)
    local mapping = carryConfig.components or {}
    local list = type(info) == 'table' and info.components or nil
    if type(list) ~= 'table' then
        return nil
    end
    local out
    for _, component in ipairs(list) do
        local mapped = type(component) == 'string' and mapping[component] or nil
        if mapped then
            out = out or {}
            out[#out + 1] = mapped
        end
    end
    return out
end

---Build the ordered carry list for a player, straight from their real items.
---Slot order is the render order, so every client draws the same weapon in
---the same position on the same body.
---@param src integer
---@return table[]
local function buildCarryList(src)
    if not enabled() then
        return {}
    end
    local items = exports.kora_core:getPlayerData(src, { 'items' }) or {}
    local limit = hotbarOnly() and hotbarSlots() or math.huge
    local holding = equipped[src]

    local slots = {}
    for slot in pairs(items) do
        local slotNumber = tonumber(slot)
        if slotNumber and slotNumber <= limit then
            slots[#slots + 1] = slotNumber
        end
    end
    table.sort(slots)

    local carried = {}
    for _, slot in ipairs(slots) do
        local item = items[slot]
        -- A weapon in hand is not also on the back.
        local inHand = holding and holding.slot == slot and holding.name == item.name
        local rule = (not inHand) and type(item.name) == 'string' and carryRule(item.name) or nil
        if rule then
            local info = item.info or item.metadata
            carried[#carried + 1] = {
                name = item.name,
                tier = rule.tier,
                model = rule.model,
                bone = rule.bone,
                pos = rule.pos,
                rot = rule.rot,
                tint = tonumber(info and info.tint) or nil,
                components = renderableComponents(info),
            }
        end
    end
    return carried
end

---Recompute and replicate one player's carried weapons.
---@param src integer
local function publish(src)
    local player = Player(src)
    if not player or not player.state then
        return
    end
    local carried = enabled() and buildCarryList(src) or {}
    -- `false`, never nil -- see STATE_KEY above.
    player.state:set(STATE_KEY, #carried > 0 and carried or false, true)
end

---Draw duration for one slot. The concealment surcharge is only real while
---`visibility = 'hotbar'`: in 'all' mode (or with carry off) the weapon's
---slot says nothing about whether anyone could see it coming.
---@param slot integer
---@return integer milliseconds
local function drawDuration(slot)
    local duration = integer(carryConfig.drawTime, 0)
    if hotbarOnly() and slot > hotbarSlots() then
        duration = duration + integer(carryConfig.concealedDrawTime, 0)
    end
    return duration
end

---The animation tier for one weapon name: the same tier `tiers` assigns for
---carry, so where a weapon is worn and how it is produced stay one decision.
---
---Read straight from `tiers` rather than through `carryRule`, because a weapon
---excluded from CARRY still has to be drawn: a throwable or an item with
---`tier = false` is simply not rendered on the body, which says nothing about
---which animation suits it. Nil falls back to the single drawAnim/holsterAnim.
---@param name string
---@return string|nil
local function animTier(name)
    local def = internal.itemDef(name)
    return def and (carryConfig.tiers or {})[def.weapontype] or nil
end

---The shared combat settings for a weapon. Shared definitions are trusted
---server configuration; malformed modifiers fall back to GTA's native value.
---@param name string
---@return table
local function damageSettings(name)
    local definition = internal.itemDef(name)
    local modifier = tonumber(definition and definition.damageModifier)
    if not modifier or modifier < 0 then
        modifier = 1.0
    end
    return {
        modifier = modifier,
        disableCriticalHits = definition and definition.disableCriticalHits == true,
    }
end

---Durability percentage points lost for `rounds` accepted shots. This is
---entirely server config: a client cannot select a multiplier, opt out or
---report a positive/negative wear amount.
local function shotWear(name, rounds)
    if durabilityConfig.enabled ~= true or (durabilityConfig.excluded or {})[name] == true then
        return 0
    end
    local perShot = tonumber(durabilityConfig.perShot) or 0
    local multiplier = tonumber((durabilityConfig.multipliers or {})[name])
    if multiplier == nil then
        multiplier = tonumber(durabilityConfig.defaultMultiplier) or 1
    end
    return math.max(0, perShot * math.max(0, multiplier) * math.max(0, rounds))
end

---Server half of using a weapon item: decide draw vs holster, price it, and
---ask that one client to play it out. Nothing is committed until the client
---confirms below, so a cancelled draw leaves the player exactly as they were.
---@param src integer
---@param item table  -- already re-resolved from PlayerData by useItem
---@return boolean, table|string
local function toggle(src, item)
    local slot = math.floor(tonumber(item.slot) or 0)
    if slot <= 0 then
        return false, 'invalid weapon slot'
    end

    local holding = equipped[src]
    local holstering = holding ~= nil and holding.slot == slot and holding.name == item.name
    local action = holstering and 'holster' or 'draw'
    local duration = holstering and integer(carryConfig.holsterTime, 0) or drawDuration(slot)
    local info = item.info or item.metadata or {}

    pending[src] = {
        slot = slot,
        name = item.name,
        action = action,
        -- Generous: the client also has to load an anim dict and a weapon
        -- asset before its bar starts. Too tight a window would reject an
        -- honest slow client, which is worse than a loose one here -- the
        -- confirmation is re-validated against real possession anyway.
        expires = GetGameTimer() + duration + 15000,
    }

    TriggerClientEvent('qbinventory:client:toggleWeapon', src, {
        name = item.name,
        slot = slot,
        action = action,
        duration = duration,
        -- Item metadata is the durable source of truth. The client receives
        -- an initial value only to reproduce that server state on a new draw;
        -- shot reports below can decrease it but never increase it.
        ammo = math.floor(tonumber(info.ammo) or 0),
        tint = math.max(0, math.min(32, math.floor(tonumber(info.tint) or 0))),
        -- This uses the same allow-list as the carried prop renderer. The
        -- client never receives raw metadata component names.
        components = renderableComponents(info),
        -- Presentation for the bar; the client owns nothing else about it.
        label = item.label or item.name,
        -- Which animation to play. Resolved here because the tier already
        -- lives here, and it keeps the client from having to look a weapon's
        -- class up for itself just to pick an anim.
        tier = animTier(item.name),
        -- Combat tuning is registry data resolved on the server. The client
        -- only applies it after this draw puts the real weapon in hand.
        damage = damageSettings(item.name),
    })
    return true
end

---The client reporting that the draw/holster this server asked for actually
---finished. The slot is re-resolved against qbcore-owned PlayerData: a client
---cannot confirm a weapon it does not have, in a slot it was not asked about.
RegisterNetEvent('qbinventory:server:weaponToggled', function(slot)
    if GetInvokingResource() then
        return
    end
    local src = source
    local request = pending[src]
    if not request then
        return
    end
    if GetGameTimer() > request.expires then
        pending[src] = nil
        return
    end
    if math.floor(tonumber(slot) or 0) ~= request.slot then
        return
    end

    local owned = inventory.api.getItemBySlot(src, request.slot)
    if not owned or owned.name ~= request.name then
        pending[src] = nil
        return
    end

    pending[src] = nil
    equipped[src] = request.action == 'draw' and { slot = request.slot, name = request.name } or nil
    publish(src)
end)

---The client's weapon left their hands without a holster action -- a weapon
---wheel switch, a disarm, death, or a respawn. Carries no payload precisely
---because there is nothing here worth trusting a client with: it can only
---ever put a weapon BACK on its own player's body, never take one off.
RegisterNetEvent('qbinventory:server:weaponUnequipped', function()
    if GetInvokingResource() then
        return
    end
    local src = source
    if not equipped[src] then
        return
    end
    equipped[src] = nil
    pending[src] = nil
    publish(src)
end)

-- GTA owns the immediate shot count on the ped, but kora_inventory owns the
-- durable item state. A client report can only lower the ammo stored on the
-- weapon the server has already confirmed as drawn; reloading is the sole
-- server-side path that raises it. That makes this safe for both native
-- kora_inventory draws and the qb-weapons compatibility adapter.
RegisterNetEvent('qbinventory:server:weaponAmmoConsumed', function(slot, amount)
    if GetInvokingResource() then
        return
    end
    local src = source
    local holding = equipped[src]
    slot = math.floor(tonumber(slot) or 0)
    amount = math.floor(tonumber(amount) or -1)
    if not holding or slot ~= holding.slot or amount < 0 then
        return
    end
    local state = inventory.weapons and inventory.weapons.getState and inventory.weapons.getState(src, slot)
    local current = math.floor(tonumber(state and state.ammo) or 0)
    local rounds = current - amount
    if rounds <= 0 or not inventory.weapons then
        return
    end

    -- Ballistics-capable weapons consume their individually tracked rounds.
    -- A legacy count-only weapon stays supported through SetAmmo until its
    -- next state write migrates it to per-round metadata.
    local consumed = 0
    local bullets = type(state.loadedBullets) == 'table' and #state.loadedBullets or 0
    if
        weaponConfig.ballistics
        and weaponConfig.ballistics.enabled == true
        and bullets >= rounds
        and type(inventory.weapons.fireRound) == 'function'
    then
        for _ = 1, rounds do
            local fired = inventory.weapons.fireRound(src, slot)
            if not fired then
                break
            end
            consumed = consumed + 1
        end
    elseif inventory.weapons.setAmmo and inventory.weapons.setAmmo(src, slot, amount) then
        consumed = rounds
    end

    local wear = shotWear(holding.name, consumed)
    if wear > 0 and inventory.weapons.consumeDurability then
        inventory.weapons.consumeDurability(src, slot, wear)
    end
end)

-- The client sends no weapon, ammo, casing, coordinate, serial, or evidence
-- payload. This handler re-resolves the confirmed slot, consumes exactly one
-- loaded round, then lets the police domain create a casing from server-owned
-- data. FiveM cannot expose native weapon-fire state to the server, therefore
-- the cadence limit is an intentional anti-spam floor.
RegisterNetEvent('qbinventory:server:weaponFired', function()
    if GetInvokingResource() then
        return
    end
    local src = source
    local rangeWeapon = training[src]
    if rangeWeapon then
        local current = GetGameTimer()
        local minGap = math.max(0, math.floor(tonumber(((config.weapons or {}).ballistics or {}).shotCooldown) or 65))
        if lastShotAt[src] and current - lastShotAt[src] < minGap then
            return
        end
        lastShotAt[src] = current
        rangeWeapon.remaining = rangeWeapon.remaining - 1
        rangeWeapon.fired = rangeWeapon.fired + 1
        TriggerEvent('qbinventory:server:trainingRoundFired', src, {
            owner = rangeWeapon.owner,
            weapon = rangeWeapon.name,
            shot = rangeWeapon.fired,
            remaining = rangeWeapon.remaining,
        })
        if rangeWeapon.remaining <= 0 then
            trainingOwnership.untrack(src)
            stopTraining(src)
        end
        return
    end

    local holding = equipped[src]
    if not holding or not internal.fireWeaponShot then
        return
    end
    local now = GetGameTimer()
    local minGap = math.max(0, math.floor(tonumber(((config.weapons or {}).ballistics or {}).shotCooldown) or 65))
    if lastShotAt[src] and now - lastShotAt[src] < minGap then
        return
    end
    local fired, round = internal.fireWeaponShot(src, holding.slot, shotWear(holding.name, 1))
    if not fired then
        return
    end
    lastShotAt[src] = now
    TriggerEvent('qbinventory:server:weaponRoundFired', src, round)
end)

-- Every player item write funnels through kora_core's setPath, which fires this
-- for kora_inventory's own transfers as well as another resource's AddItem, so
-- one handler covers picking a rifle up, dropping it, and moving it in or out
-- of the hotbar range.
AddEventHandler('qbcore:server:inventoryChanged', function(src, path, value)
    if not enabled() then
        return
    end
    local holding = equipped[src]
    if holding then
        -- Metadata on the held weapon cannot change the list worn on the body.
        if type(path) == 'table' and #path == 2 and path[1] == 'items' and path[2] == holding.slot
            and type(value) == 'table' and value.name == holding.name then
            return
        end
        -- The held weapon may have just been moved, dropped or given away.
        local owned = exports.kora_core:getPlayerData(src, { 'items', holding.slot })
        if not owned or owned.name ~= holding.name then
            equipped[src] = nil
        end
    end
    publish(src)
end)

AddEventHandler('playerDropped', function()
    local src = source
    trainingOwnership.untrack(src)
    stopTraining(src)
    equipped[src], pending[src], lastShotAt[src] = nil, nil, nil
end)

AddEventHandler('qbcore:server:playerLoaded', function(src)
    -- A fresh spawn holds nothing, whatever a previous session left behind,
    -- and the bag has to be seeded before any client can render it.
    trainingOwnership.untrack(src)
    stopTraining(src)
    equipped[src], pending[src], lastShotAt[src] = nil, nil, nil
    publish(src)
end)

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then
        return
    end
    -- Leave no props attached to anyone when this resource goes away.
    for src in pairs(equipped) do
        local player = Player(src)
        if player and player.state then
            player.state:set(STATE_KEY, false, true)
        end
    end
end)

inventory.weaponCarry = {
    toggle = toggle,
    refresh = publish,
    buildCarryList = buildCarryList,
    carryRule = carryRule,
    drawDuration = drawDuration,
    shotWear = shotWear,
    damageSettings = damageSettings,
    stateKey = STATE_KEY,
    ---@param src integer
    ---@return table|nil  -- { slot, name, components? } or nil when empty-handed
    equippedWeapon = function(src)
        local holding = equipped[src]
        if not holding then return nil end
        local result = internal.copy(holding)
        local item = inventory.api.getItemBySlot(src, holding.slot)
        if item and item.name == holding.name then
            result.components = renderableComponents(item.info or item.metadata)
        end
        return result
    end,
}

-- Read-only. There is deliberately no exported setter: a resource that wants
-- a different carried list changes the player's items, not the render.
exports('GetCarriedWeapons', function(src)
    return buildCarryList(tonumber(src) or 0)
end)
exports('GetEquippedWeapon', inventory.weaponCarry.equippedWeapon)

exports('StartTrainingWeapon', function(src, weaponName, rounds)
    src = tonumber(src)
    rounds = math.floor(tonumber(rounds) or 0)
    local owner = GetInvokingResource()
    local definition = type(weaponName) == 'string' and internal.itemDef(weaponName) or nil
    if not src or not owner or not definition or not inventory.weapons.isWeapon(weaponName) then
        return false, 'invalid training weapon'
    end
    if rounds < 1 or rounds > 100 then
        return false, 'invalid training round count'
    end
    if equipped[src] or pending[src] then
        return false, 'holster the current weapon first'
    end
    if training[src] then
        return false, 'a training weapon is already active'
    end

    training[src] = { owner = owner, name = weaponName, remaining = rounds, fired = 0 }
    trainingOwnership.track(owner, src)
    TriggerClientEvent('qbinventory:client:startTrainingWeapon', src, weaponName, rounds, damageSettings(weaponName))
    return true
end)

exports('StopTrainingWeapon', function(src)
    src = tonumber(src)
    local state = src and training[src] or nil
    if not state or state.owner ~= GetInvokingResource() then
        return false
    end
    trainingOwnership.untrack(src)
    return stopTraining(src)
end)
