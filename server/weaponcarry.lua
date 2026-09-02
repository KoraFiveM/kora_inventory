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
local I = QbInventory
local internal = assert(I.internal, 'qbinventory authority must load before weapon carry')

local C = Config.qbinventory
local cfg = C.weaponCarry or {}

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

local function integer(value, fallback)
    local n = math.floor(tonumber(value) or fallback or 0)
    return n >= 0 and n or 0
end

local function enabled() return cfg.enabled == true end
local function hotbarOnly() return enabled() and cfg.visibility == 'hotbar' end
local function hotbarSlots() return integer(C.hotbarSlots, 5) end

---The carry rules for one item name, or nil when it is not carried at all.
---A registry weapon is classified automatically by its `weapontype`; anything
---else (and any exception) needs an explicit entry in `weaponCarry.weapons`.
---@param name string
---@return table|nil
local function carryRule(name)
    local override = (cfg.weapons or {})[name]
    if override and override.tier == false then return nil end
    local def = internal.itemDef(name)
    local tier = override and override.tier
        or (def and (cfg.tiers or {})[def.weapontype])
    if not tier then return nil end
    if not (cfg.attachments or {})[tier] then return nil end
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
    local mapping = cfg.components or {}
    local list = type(info) == 'table' and info.components or nil
    if type(list) ~= 'table' then return nil end
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
    if not enabled() then return {} end
    local items = exports.qbcore:getPlayerData(src, { 'items' }) or {}
    local limit = hotbarOnly() and hotbarSlots() or math.huge
    local holding = equipped[src]

    local slots = {}
    for slot in pairs(items) do
        local n = tonumber(slot)
        if n and n <= limit then slots[#slots + 1] = n end
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
    if not player or not player.state then return end
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
    local duration = integer(cfg.drawTime, 0)
    if hotbarOnly() and slot > hotbarSlots() then
        duration = duration + integer(cfg.concealedDrawTime, 0)
    end
    return duration
end

---Server half of using a weapon item: decide draw vs holster, price it, and
---ask that one client to play it out. Nothing is committed until the client
---confirms below, so a cancelled draw leaves the player exactly as they were.
---@param src integer
---@param item table  -- already re-resolved from PlayerData by useItem
---@return boolean, table|string
local function toggle(src, item)
    local slot = math.floor(tonumber(item.slot) or 0)
    if slot <= 0 then return false, 'invalid weapon slot' end

    local holding = equipped[src]
    local holstering = holding ~= nil and holding.slot == slot and holding.name == item.name
    local action = holstering and 'holster' or 'draw'
    local duration = holstering and integer(cfg.holsterTime, 0) or drawDuration(slot)

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
        -- Presentation for the bar; the client owns nothing else about it.
        label = item.label or item.name,
    })
    return true
end

---The client reporting that the draw/holster this server asked for actually
---finished. The slot is re-resolved against qbcore-owned PlayerData: a client
---cannot confirm a weapon it does not have, in a slot it was not asked about.
RegisterNetEvent('qbinventory:server:weaponToggled', function(slot)
    local src = source
    local request = pending[src]
    if not request then return end
    if GetGameTimer() > request.expires then pending[src] = nil; return end
    if math.floor(tonumber(slot) or 0) ~= request.slot then return end

    local owned = getItemBySlot(src, request.slot)
    if not owned or owned.name ~= request.name then pending[src] = nil; return end

    pending[src] = nil
    equipped[src] = request.action == 'draw' and { slot = request.slot, name = request.name } or nil
    publish(src)
end)

---The client's weapon left their hands without a holster action -- a weapon
---wheel switch, a disarm, death, or a respawn. Carries no payload precisely
---because there is nothing here worth trusting a client with: it can only
---ever put a weapon BACK on its own player's body, never take one off.
RegisterNetEvent('qbinventory:server:weaponUnequipped', function()
    local src = source
    if not equipped[src] then return end
    equipped[src] = nil
    pending[src] = nil
    publish(src)
end)

-- Every player item write funnels through qbcore's setPath, which fires this
-- for qbinventory's own transfers as well as another resource's AddItem, so
-- one handler covers picking a rifle up, dropping it, and moving it in or out
-- of the hotbar range.
AddEventHandler('qbcore:server:inventoryChanged', function(src)
    if not enabled() then return end
    local holding = equipped[src]
    if holding then
        -- The held weapon may have just been moved, dropped or given away.
        local owned = getItemBySlot(src, holding.slot)
        if not owned or owned.name ~= holding.name then equipped[src] = nil end
    end
    publish(src)
end)

AddEventHandler('playerDropped', function()
    local src = source
    equipped[src], pending[src] = nil, nil
end)

AddEventHandler('qbcore:server:playerLoaded', function(src)
    -- A fresh spawn holds nothing, whatever a previous session left behind,
    -- and the bag has to be seeded before any client can render it.
    equipped[src], pending[src] = nil, nil
    publish(src)
end)

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    -- Leave no props attached to anyone when this resource goes away.
    for src in pairs(equipped) do
        local player = Player(src)
        if player and player.state then player.state:set(STATE_KEY, false, true) end
    end
end)

I.weaponCarry = {
    toggle = toggle,
    refresh = publish,
    buildCarryList = buildCarryList,
    carryRule = carryRule,
    drawDuration = drawDuration,
    stateKey = STATE_KEY,
    ---@param src integer
    ---@return table|nil  -- { slot, name } or nil when empty-handed
    equippedWeapon = function(src) return equipped[src] and internal.copy(equipped[src]) or nil end,
}

-- Read-only. There is deliberately no exported setter: a resource that wants
-- a different carried list changes the player's items, not the render.
exports('GetCarriedWeapons', function(src) return buildCarryList(tonumber(src) or 0) end)
exports('GetEquippedWeapon', I.weaponCarry.equippedWeapon)
