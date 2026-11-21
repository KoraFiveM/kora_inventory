-- Weapon upkeep: jams, repair kits, cleaning and repair counters.
--
-- Everything here acts on the weapon the SERVER already knows the player has
-- drawn (weaponcarry's `equipped` record, read through
-- KoraInventory.weaponCarry.equippedWeapon), exactly like the ammunition loader
-- in useables.lua. No net event in this file accepts a weapon name, slot,
-- durability, price or item: the only client-supplied values are the payload-
-- free "clear my jam" intent and a counter INDEX (a position in the owner's
-- own config list, re-checked against the player's server-side position and
-- routing bucket before anything is charged).
--
-- All settings are read from Config at call time, so /config changes apply
-- without a restart (the kit item names are the one exception: a built-in
-- use handler is registered per name when the item registry loads or changes).

local inventory = assert(KoraInventory, 'kora_inventory authority must load before weapon upkeep')
local internal = assert(inventory.internal, 'kora_inventory internal API must load before weapon upkeep')
local api = assert(inventory.api, 'kora_inventory api must load before weapon upkeep')

local upkeep = {}
inventory.weaponUpkeep = upkeep

-- Hard ceiling: weapon metadata clamps durability to 0..100.
local DURABILITY_CEILING = 100
-- A real progress bar cannot report back sooner than its duration.
local BAR_TOLERANCE = 500
-- How long a counter quote stays valid for its confirm press.
local QUOTE_TTL = 30000

-- Weapon types that can never jam (nothing to misfeed).
local NEVER_JAM_TYPES = { Melee = true, Throwable = true, Unarmed = true }

-- Replaceable for tests.
upkeep.random = math.random

local function weaponsConfig()
    return (Config.kora_inventory and Config.kora_inventory.weapons) or {}
end
local function jamConfig()
    return weaponsConfig().jams or {}
end
local function repairConfig()
    return weaponsConfig().repair or {}
end
local function counterConfig()
    return repairConfig().counters or {}
end

local function number(value, fallback)
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then
        return fallback
    end
    return n
end

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function text(key, fallback, vars)
    return inventory.text and inventory.text(key, fallback, vars) or fallback
end

local function notify(src, key, fallback, vars, kind)
    if not (Kora and Kora.notify and Kora.notify.send) then
        return
    end
    pcall(Kora.notify.send, src, {
        title = text('inventory.title', 'Inventory'),
        message = text(key, fallback, vars),
        type = kind or 'error',
    })
end

---------------------------------------------------------------------------
-- Pure rules (no player state; unit-tested directly)
---------------------------------------------------------------------------

---Jam chance for ONE accepted shot at `durability` percent. Linear from
---`baseChance` at 100% to `lowDurabilityChance` at/below `lowDurabilityBelow`.
---@param durability number
---@param cfg table|nil jams config
---@return number chance 0..1
function upkeep.jamChance(durability, cfg)
    cfg = cfg or jamConfig()
    local base = clamp(number(cfg.baseChance, 0.002), 0, 1)
    local low = clamp(number(cfg.lowDurabilityChance, 0.03), 0, 1)
    local below = clamp(number(cfg.lowDurabilityBelow, 30), 0, DURABILITY_CEILING)
    local value = clamp(number(durability, DURABILITY_CEILING), 0, DURABILITY_CEILING)
    if value <= below or below >= DURABILITY_CEILING then
        return low
    end
    local t = (DURABILITY_CEILING - value) / (DURABILITY_CEILING - below)
    return clamp(base + (low - base) * t, 0, 1)
end

---Chance that at least one of `rounds` independent shots jams.
function upkeep.jamChanceForRounds(durability, rounds, cfg)
    rounds = math.max(0, math.floor(number(rounds, 0)))
    if rounds == 0 then
        return 0
    end
    local single = upkeep.jamChance(durability, cfg)
    return 1 - (1 - single) ^ rounds
end

---Whether a weapon can ever jam. Melee, throwables, weapons that take no
---ammunition, and anything in `jams.excluded` cannot.
---@param name string
---@return boolean
function upkeep.canJam(name, def)
    if type(name) ~= 'string' then
        return false
    end
    if (jamConfig().excluded or {})[name] == true then
        return false
    end
    def = def or internal.itemDef(name)
    if type(def) ~= 'table' or NEVER_JAM_TYPES[def.weapontype] then
        return false
    end
    return type(def.ammotype) == 'string' and def.ammotype ~= ''
end

---Highest durability repairs may reach.
function upkeep.maxDurability()
    return clamp(number(repairConfig().maxDurability, DURABILITY_CEILING), 1, DURABILITY_CEILING)
end

---Durability after restoring `restore` points, never above `max`.
function upkeep.restoreTarget(current, restore, max)
    max = max or upkeep.maxDurability()
    current = clamp(number(current, DURABILITY_CEILING), 0, DURABILITY_CEILING)
    return math.min(max, current + math.max(0, number(restore, 0)))
end

---Price of repairing `missing` durability points, rounded up to whole money.
function upkeep.counterPrice(missing, pricePerPoint)
    missing = math.max(0, number(missing, 0))
    local per = math.max(0, number(pricePerPoint, 0))
    return math.ceil(missing * per - 1e-9)
end

---Whether a player at `coords` / `bucket` can use `counter`.
---`coords` and the counter's coords need only expose x/y/z, so server vectors
---and plain tables both work.
function upkeep.withinCounter(counter, coords, bucket)
    local point = type(counter) == 'table' and counter.coords or nil
    if point == nil or coords == nil then
        return false
    end
    local cx, cy, cz = tonumber(point.x), tonumber(point.y), tonumber(point.z)
    local px, py, pz = tonumber(coords.x), tonumber(coords.y), tonumber(coords.z)
    if not (cx and cy and cz and px and py and pz) then
        return false
    end
    if bucket ~= (math.floor(number(counter.bucket, 0))) then
        return false
    end
    local distance = math.max(0, number(counter.distance, 2.5))
    local dx, dy, dz = px - cx, py - cy, pz - cz
    return dx * dx + dy * dy + dz * dz <= distance * distance
end

---------------------------------------------------------------------------
-- Server-resolved drawn weapon
---------------------------------------------------------------------------

---The weapon this player has drawn, from the server's own record, with its
---state. Nothing here is client supplied.
---@return table|nil holding { slot, name }
---@return table|string stateOrReason
local function resolveDrawn(src)
    local carry = inventory.weaponCarry
    local holding = carry and carry.equippedWeapon(src)
    if not holding then
        return nil, 'draw a weapon first'
    end
    local state = inventory.weapons and inventory.weapons.getState and inventory.weapons.getState(src, holding.slot)
    if type(state) ~= 'table' then
        return nil, 'weapon unavailable'
    end
    return holding, state
end

local function sameWeapon(left, right)
    return left ~= nil and right ~= nil and left.slot == right.slot and left.name == right.name
end

local function durabilityOf(state)
    return number(state.durability, number(state.quality, number(weaponsConfig().defaultDurability, DURABILITY_CEILING)))
end

-- Players with an upkeep action (clear / kit / clean / counter) in flight.
local busy = {}

local function withBusy(src, fn)
    if busy[src] then
        return false, 'already busy'
    end
    busy[src] = true
    local ok, first, second = pcall(fn)
    busy[src] = nil
    if not ok then
        return false, first
    end
    return first, second
end

---Ask the client for a progress bar and require that it took about as long as
---it should. The client reports its own result, so a bar answered instantly is
---treated as a cancel (same rule as the parachute).
local function runBar(src, kind, duration)
    duration = math.max(0, math.floor(number(duration, 0)))
    local startedAt = GetGameTimer()
    local ok, completed = pcall(Kora.callback.trigger, src, 'kora_inventory:client:weaponUpkeepBar', {
        kind = kind,
        time = duration,
    })
    if not ok or completed ~= true then
        return false
    end
    if duration > 0 and GetGameTimer() - startedAt < duration - BAR_TOLERANCE then
        return false
    end
    return true
end

---------------------------------------------------------------------------
-- Jams
---------------------------------------------------------------------------

-- src -> { slot, jammed }: what the client was last told, so a shot does not
-- send a network event unless the jam state actually changed.
local told = {}

local function tellClient(src, slot, jammed, force)
    local last = told[src]
    if not force and last and last.slot == slot and last.jammed == jammed then
        return
    end
    told[src] = { slot = slot, jammed = jammed }
    TriggerClientEvent('kora_inventory:client:weaponJamState', src, { slot = slot, jammed = jammed })
end

---Re-send the jam state of the drawn weapon (called right after a draw is
---confirmed, so a weapon drawn while jammed arrives already blocked).
function upkeep.syncDrawn(src)
    local holding, state = resolveDrawn(src)
    if not holding then
        told[src] = nil
        return
    end
    tellClient(src, holding.slot, state.jammed == true, true)
end

---Called by weaponcarry after the server ACCEPTED `rounds` shots from the
---weapon it has recorded as drawn. Rolls the jam chance and, on a jam, stores
---it on the weapon and tells the client.
---@return boolean jammed
function upkeep.afterShots(src, holding, rounds)
    if jamConfig().enabled ~= true or type(holding) ~= 'table' then
        return false
    end
    if not upkeep.canJam(holding.name) then
        return false
    end
    local state = inventory.weapons and inventory.weapons.getState and inventory.weapons.getState(src, holding.slot)
    if type(state) ~= 'table' or state.jammed == true then
        return false
    end
    local chance = upkeep.jamChanceForRounds(durabilityOf(state), rounds)
    if chance <= 0 or upkeep.random() >= chance then
        return false
    end
    local saved = inventory.weapons.setState(src, holding.slot, { jammed = true })
    if not saved then
        return false
    end
    tellClient(src, holding.slot, true)
    TriggerEvent('kora_inventory:server:weaponJammed', src, holding.name)
    return true
end

---Clear the jam on the drawn weapon after a server-run progress bar. Takes no
---weapon argument: the weapon is whatever the server recorded as drawn.
---@return boolean cleared
---@return string|nil reason
function upkeep.clearJam(src)
    return withBusy(src, function()
        local holding, state = resolveDrawn(src)
        if not holding then
            return false, state
        end
        if state.jammed ~= true then
            return false, 'weapon is not jammed'
        end
        if not runBar(src, 'clear', jamConfig().clearTime or 1500) then
            return false, 'cancelled'
        end
        -- The player may have holstered, swapped or lost the weapon mid-bar.
        local after, fresh = resolveDrawn(src)
        if not sameWeapon(holding, after) or fresh.jammed ~= true then
            return false, 'weapon changed'
        end
        local saved, err = inventory.weapons.setState(src, after.slot, { jammed = false })
        if not saved then
            return false, err
        end
        tellClient(src, after.slot, false)
        notify(src, 'inventory.weapon_jam_cleared', 'You cleared the jam.', nil, 'success')
        return true
    end)
end

-- Payload-free on purpose: see docs/security.md. The weapon is resolved from
-- the server's own equipped record, never from this event.
RegisterNetEvent('kora_inventory:server:clearJam', function()
    if GetInvokingResource() then
        return
    end
    local src = source
    if internal.isDowned and internal.isDowned(src) then
        return
    end
    if internal.isCuffed and internal.isCuffed(src) then
        return
    end
    upkeep.clearJam(src)
end)

-- Keep the client in step when ANY writer changes the drawn weapon's jam state
-- (a kit, another resource's SetWeaponState). Deduplicated, so a shot that
-- changes nothing sends nothing.
AddEventHandler('kora_inventory:server:weaponStateChanged', function(src, slot, info)
    local carry = inventory.weaponCarry
    local holding = carry and carry.equippedWeapon(src)
    if holding and holding.slot == slot and type(info) == 'table' then
        tellClient(src, slot, info.jammed == true)
    end
end)

---------------------------------------------------------------------------
-- Repair kits and cleaning
---------------------------------------------------------------------------

---Which upkeep action an item name maps to, from live config.
---@return string|nil kind 'kit' | 'clean'
---@return table|nil settings
local function classify(name)
    local repair = repairConfig()
    if repair.enabled == false or type(name) ~= 'string' then
        return nil
    end
    local cleaning = repair.cleaning
    if type(cleaning) == 'table' and cleaning.item == name then
        return 'clean', cleaning
    end
    local kit = (repair.kits or {})[name]
    if type(kit) == 'table' then
        return 'kit', kit
    end
    return nil
end
upkeep.classify = classify

local function upkeepUseable(src, item)
    local kind, settings = classify(item.name)
    if not kind then
        return false, 'not a weapon upkeep item'
    end
    local holding, state = resolveDrawn(src)
    if not holding then
        return false, 'draw a weapon before using ' .. tostring(item.name)
    end
    local max = upkeep.maxDurability()
    local current = durabilityOf(state)
    local restore = math.max(0, number(settings.restore, 0))
    local wasJammed = state.jammed == true
    local clearsJam = kind == 'clean' and settings.clearsJam ~= false

    if kind == 'kit' then
        if current >= max then
            notify(src, 'inventory.weapon_repair_not_needed', 'That weapon does not need repairs.')
            return false, 'weapon does not need repairs'
        end
    elseif not ((clearsJam and wasJammed) or (restore > 0 and current < max)) then
        notify(src, 'inventory.weapon_clean_not_needed', 'That weapon does not need cleaning.')
        return false, 'weapon does not need cleaning'
    end

    local used, reason = withBusy(src, function()
        if not runBar(src, kind == 'kit' and 'repair' or 'clean', settings.time) then
            return false, 'cancelled'
        end
        local after, fresh = resolveDrawn(src)
        if not sameWeapon(holding, after) then
            return false, 'weapon changed'
        end
        -- The kit must still be where it was used from.
        local owned = api.getItemBySlot(src, item.slot)
        if not owned or owned.name ~= item.name then
            return false, 'item no longer available'
        end

        local before = { durability = durabilityOf(fresh), jammed = fresh.jammed == true }
        local changes = { durability = upkeep.restoreTarget(before.durability, restore, max) }
        if clearsJam and before.jammed then
            changes.jammed = false
        end
        local saved, saveErr = inventory.weapons.setState(src, after.slot, changes)
        if not saved then
            return false, saveErr
        end
        local removed, removeErr = api.removeItem(src, item.name, 1, item.slot,
            kind == 'kit' and 'used weapon repair kit' or 'used weapon cleaning kit')
        if not removed then
            -- Nothing was charged, so undo the repair.
            inventory.weapons.setState(src, after.slot, before)
            return false, removeErr
        end
        local nowJammed = before.jammed
        if changes.jammed == false then
            nowJammed = false
        end
        tellClient(src, after.slot, nowJammed)
        notify(src, kind == 'kit' and 'inventory.weapon_repaired_kit' or 'inventory.weapon_cleaned',
            kind == 'kit' and 'Weapon repaired to %{durability}%.' or 'Weapon cleaned (%{durability}%).',
            { durability = math.floor(changes.durability + 0.5) }, 'success')
        return true
    end)
    if not used then
        return false, reason
    end
    return true
end
upkeep.useItem = upkeepUseable

local function refreshUpkeepUseable(name, def)
    -- Registered only for names the owner listed; an item another resource
    -- gives its own createUseable handler always takes precedence in useItem.
    local kind = def and classify(name)
    internal.setBuiltInUseable(name, kind and upkeepUseable or nil, 'upkeep')
end

local function refreshAll()
    for _, def in ipairs(exports.kora_core:allShared('items')) do
        refreshUpkeepUseable(def.name, def)
    end
end
refreshAll()
exports.kora_core:onSharedChange('items', function(_, name, def)
    refreshUpkeepUseable(name, def)
end)
upkeep.refresh = refreshAll

---------------------------------------------------------------------------
-- Repair counters
---------------------------------------------------------------------------

local quotes = {}

local function counterAt(index)
    index = math.floor(number(index, 0))
    local list = counterConfig().locations
    if index < 1 or type(list) ~= 'table' then
        return nil
    end
    return list[index], index
end

local function counterAccount()
    return counterConfig().account == 'bank' and 'bank' or 'cash'
end

---Everything needed to price a repair for this player at this counter, or a
---refusal. Shared by the quote and the charge so they cannot disagree.
local function evaluate(src, counterIndex)
    if counterConfig().enabled ~= true then
        return nil, 'repair counters are disabled'
    end
    local counter, index = counterAt(counterIndex)
    if not counter then
        return nil, 'unknown repair counter'
    end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then
        return nil, 'player entity unavailable'
    end
    if not upkeep.withinCounter(counter, GetEntityCoords(ped), GetPlayerRoutingBucket(src)) then
        return nil, 'too far from the repair counter'
    end
    local holding, state = resolveDrawn(src)
    if not holding then
        return nil, state
    end
    local max = upkeep.maxDurability()
    local current = durabilityOf(state)
    local missing = math.max(0, max - current)
    if missing <= 0 and state.jammed ~= true then
        return nil, 'weapon does not need repairs'
    end
    return {
        index = index,
        holding = holding,
        state = state,
        max = max,
        current = current,
        missing = missing,
        price = upkeep.counterPrice(missing, counterConfig().pricePerPoint),
        account = counterAccount(),
    }
end

---Price the drawn weapon's repair at a counter and remember it for the
---confirm press. Returns a table with price/account/durability for display.
function upkeep.quoteRepair(src, counterIndex)
    local plan, reason = evaluate(src, counterIndex)
    if not plan then
        quotes[src] = nil
        return false, reason
    end
    quotes[src] = { index = plan.index, price = plan.price, expires = GetGameTimer() + QUOTE_TTL }
    local def = internal.itemDef(plan.holding.name)
    return true, {
        price = plan.price,
        account = plan.account,
        durability = math.floor(plan.current + 0.5),
        max = plan.max,
        weapon = def and (def.label or def.name) or plan.holding.name,
    }
end

---Charge for and perform a counter repair of the weapon the player has drawn.
---`expectedPrice` (optional) refuses the repair if the price moved since a quote.
---@param src integer
---@param counterIndex integer index into weapons.repair.counters.locations
---@return boolean ok
---@return table|string result { price, durability } or a reason
function upkeep.repairWeaponAt(src, counterIndex, expectedPrice)
    src = tonumber(src)
    if not src then
        return false, 'invalid player'
    end
    return withBusy(src, function()
        local plan, reason = evaluate(src, counterIndex)
        if not plan then
            return false, reason
        end
        if expectedPrice ~= nil and plan.price ~= expectedPrice then
            return false, 'the repair price changed'
        end
        local price, account = plan.price, plan.account
        if price > 0 then
            local paid, payErr = exports.kora_core:removeMoney(src, account, price, 'kora_inventory-weapon-repair')
            if not paid then
                return false, payErr or 'insufficient funds'
            end
        end
        local saved, saveErr = inventory.weapons.setState(src, plan.holding.slot, {
            durability = plan.max,
            jammed = false,
        })
        if not saved then
            if price > 0 then
                local refunded = exports.kora_core:addMoney(src, account, price, 'kora_inventory-weapon-repair-refund', true)
                if not refunded then
                    Kora.logging.error('weapon.repair_refund_failed', 'Weapon repair refund failed', {
                        playerId = src, price = price,
                    })
                end
            end
            return false, saveErr
        end
        tellClient(src, plan.holding.slot, false)
        return true, { price = price, durability = plan.max, account = account }
    end)
end

exports('repairWeaponAt', function(src, counterIndex)
    return upkeep.repairWeaponAt(src, counterIndex)
end)

Kora.callback.register('kora_inventory:server:repairQuote', function(src, counterIndex)
    local ok, result = upkeep.quoteRepair(src, counterIndex)
    if not ok then
        return false, result
    end
    return true, result
end)

-- The confirm carries only the counter index. It is honoured only against a
-- live quote this server issued for the same counter, and the price is
-- recomputed and compared before a cent is taken.
RegisterNetEvent('kora_inventory:server:repairConfirm', function(counterIndex)
    if GetInvokingResource() then
        return
    end
    local src = source
    local quote = quotes[src]
    quotes[src] = nil
    if not quote or GetGameTimer() > quote.expires or quote.index ~= math.floor(number(counterIndex, 0)) then
        notify(src, 'inventory.weapon_repair_expired', 'That repair quote has expired.')
        return
    end
    local ok, result = upkeep.repairWeaponAt(src, quote.index, quote.price)
    if ok then
        notify(src, 'inventory.weapon_repaired_counter', 'Weapon repaired for $%{price}.',
            { price = result.price }, 'success')
    else
        notify(src, 'inventory.weapon_repair_failed', 'Repair failed: %{reason}', { reason = tostring(result) })
    end
end)

local function forget(src)
    busy[src], told[src], quotes[src] = nil, nil, nil
end
AddEventHandler('playerDropped', function()
    forget(source)
end)
AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
    forget(tonumber(src) or source)
end)

return upkeep
