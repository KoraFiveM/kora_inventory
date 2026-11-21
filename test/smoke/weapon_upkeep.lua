-- Weapon upkeep: jams, repair kits, cleaning and repair counters.
--
-- The policy pinned here: every decision is made on the SERVER about the weapon
-- weaponcarry recorded as drawn. The clear-jam intent carries no payload, a
-- jammed weapon cannot consume rounds, kits never exceed maxDurability, and a
-- counter charges only a player standing at it.
local H = dofile('test/harness.lua')

Kora = {
    util = { clamp = function(value, min, max)
        if value < min then return min end
        if value > max then return max end
        return value
    end },
    logging = { error = function() end, warn = function() end },
    lang = function(key) return key end,
}

local handlers, netEvents, clientEvents, localEvents, exported = {}, {}, {}, {}, {}
AddEventHandler = function(name, fn) handlers[name] = fn end
RegisterNetEvent = function(name, fn) netEvents[name] = fn end
GetCurrentResourceName = function() return 'kora_inventory' end
GetInvokingResource = function() return nil end
TriggerEvent = function(name, ...) localEvents[#localEvents + 1] = { name = name, args = { ... } } end
TriggerClientEvent = function(name, src, payload) clientEvents[#clientEvents + 1] = { name = name, src = src, payload = payload } end

local NOW = 1000
GetGameTimer = function() return NOW end

Config = { SerialPrefix = 'KORA', kora_inventory = {} }
dofile('config.lua')
local weaponConfig = Config.kora_inventory.weapons
-- crafting.lua's per-round pipeline is on in the real config; keep it.
weaponConfig.ballistics.enabled = true
weaponConfig.maxAmmo = 250

local definitions = {
    weapon_pistol = { name = 'weapon_pistol', weight = 100, type = 'weapon', unique = true, ammotype = 'AMMO_PISTOL', weapontype = 'Pistol', label = 'Pistol' },
    weapon_revolver = { name = 'weapon_revolver', weight = 100, type = 'weapon', unique = true, ammotype = 'AMMO_PISTOL', weapontype = 'Pistol', label = 'Revolver' },
    weapon_bat = { name = 'weapon_bat', weight = 100, type = 'weapon', unique = true, weapontype = 'Melee', label = 'Bat' },
    weapon_grenade = { name = 'weapon_grenade', weight = 100, type = 'weapon', unique = false, ammotype = 'AMMO_GRENADE', weapontype = 'Throwable', label = 'Grenade' },
    weapon_flashlight = { name = 'weapon_flashlight', weight = 100, type = 'weapon', unique = true, label = 'Flashlight' },
    repairkit = { name = 'repairkit', weight = 10 },
    advancedrepairkit = { name = 'advancedrepairkit', weight = 10 },
    cleaningkit = { name = 'cleaningkit', weight = 10 },
    water_bottle = { name = 'water_bottle', weight = 10 },
}

local function bullets(count)
    local out = {}
    for i = 1, count do out[i] = { id = 'RD-' .. i, ammoType = 'AMMO_PISTOL', lot = 'LOT' } end
    return out
end

local state
local function resetState()
    state = { ['player:7'] = { items = {
        [1] = { slot = 1, name = 'weapon_pistol', amount = 1, unique = true, info = { serial = 'S1', durability = 80, ammo = 3, loadedBullets = bullets(3), components = {} } },
        [2] = { slot = 2, name = 'weapon_bat', amount = 1, unique = true, info = { serial = 'S2', durability = 80, components = {} } },
        [3] = { slot = 3, name = 'repairkit', amount = 2, info = {} },
        [4] = { slot = 4, name = 'advancedrepairkit', amount = 1, info = {} },
        [5] = { slot = 5, name = 'cleaningkit', amount = 1, info = {} },
        [6] = { slot = 6, name = 'weapon_revolver', amount = 1, unique = true, info = { serial = 'S6', durability = 100, ammo = 0, components = {} } },
    } } }
end
resetState()

local function copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for key, nested in pairs(value) do out[key] = copy(nested) end
    return out
end

local money = { cash = 1000, bank = 0 }
local charges, refunds = {}, {}
local sharedHandler
local coords, bucket = { x = 10.0, y = 10.0, z = 30.0 }, 0
local core = {
    getPlayerData = function(_, src, path)
        local player = state['player:' .. src]
        if not player then return nil end
        if path[1] == 'citizenid' then return 'CID' .. src end
        if path[2] then return copy(player.items[path[2]]) end
        return copy(player.items)
    end,
    allShared = function(_, registry)
        local out = {}
        if registry == 'items' then
            for _, def in pairs(definitions) do out[#out + 1] = def end
        end
        return out
    end,
    onSharedChange = function(_, _, fn) sharedHandler = fn end,
    removeMoney = function(_, _, account, amount, reason)
        charges[#charges + 1] = { account = account, amount = amount, reason = reason }
        if (money[account] or 0) < amount then return false, 'insufficient funds' end
        money[account] = money[account] - amount
        return true
    end,
    addMoney = function(_, _, account, amount, reason)
        refunds[#refunds + 1] = { account = account, amount = amount, reason = reason }
        money[account] = (money[account] or 0) + amount
        return true
    end,
}
exports = setmetatable({ kora_core = core }, { __call = function(_, name, fn) exported[name] = fn end })

GetPlayerPed = function() return 1 end
GetEntityCoords = function() return coords end
GetPlayerRoutingBucket = function() return bucket end

-- Server bar answer. Advances the clock by the bar's duration like a real one.
local barRequests = {}
local barAnswer = true
local barAdvance = true
local beforeAnswer
local registeredCallbacks = {}
Kora.callback = {
    trigger = function(src, name, payload)
        barRequests[#barRequests + 1] = { src = src, name = name, payload = payload }
        if beforeAnswer then beforeAnswer() end
        if barAdvance then NOW = NOW + (payload.time or 0) end
        if barAnswer == 'error' then error('timeout') end
        return barAnswer
    end,
    register = function(name, fn) registeredCallbacks[name] = fn end,
}
local notices = {}
Kora.notify = { send = function(_, payload) notices[#notices + 1] = payload end }

local removals, removeResult = {}, true
KoraInventory = {
    copy = copy,
    sameInfo = function() return false end,
    internal = {},
    api = {
        getItemBySlot = function(src, slot) return copy(state['player:' .. src].items[slot]) end,
        removeItem = function(src, name, amount, slot, reason)
            removals[#removals + 1] = { src = src, name = name, amount = amount, slot = slot, reason = reason }
            if removeResult ~= true then return false, removeResult end
            local item = state['player:' .. src].items[slot]
            item.amount = item.amount - amount
            if item.amount <= 0 then state['player:' .. src].items[slot] = nil end
            return true
        end,
    },
}
dofile('shared.lua')
local I = KoraInventory.internal
I.copy = copy
I.playerKey = function(src) return 'player:' .. src end
I.itemDef = function(name) return definitions[type(name) == 'string' and name:lower() or name] end
I.lock = function(_, fn) return fn() end
I.setPlayerItemInfo = function(src, slot, info)
    local item = state[I.playerKey(src)].items[slot]
    item.info, item.metadata = copy(info), copy(info)
    return true
end
local useables, useableKinds = {}, {}
I.setBuiltInUseable = function(name, fn, kind)
    useableKinds[name] = useableKinds[name] or {}
    useableKinds[name][kind or 'default'] = fn
    useables[name] = fn or nil
end

local crafting = dofile('server/crafting.lua')
local weapons = crafting.weapons
KoraInventory.weapons = weapons

local equipped = {}
KoraInventory.weaponCarry = {
    equippedWeapon = function(src) return equipped[src] and copy(equipped[src]) or nil end,
}
local upkeep = dofile('server/weapon_upkeep.lua')

local function info(slot) return state['player:7'].items[slot].info end
local function draw(slot)
    equipped[7] = { slot = slot, name = state['player:7'].items[slot].name }
end
local function reset()
    resetState()
    equipped = {}
    clientEvents, localEvents, barRequests, notices = {}, {}, {}, {}
    charges, refunds, removals = {}, {}, {}
    money = { cash = 1000, bank = 0 }
    barAnswer, barAdvance, beforeAnswer, removeResult = true, true, nil, true
    coords, bucket = { x = 10.0, y = 10.0, z = 30.0 }, 0
    upkeep.random = math.random
    weaponConfig.jams.enabled = false
    weaponConfig.jams.excluded = {}
    weaponConfig.repair.enabled = true
    weaponConfig.repair.maxDurability = 100
    weaponConfig.repair.counters.enabled = false
    weaponConfig.repair.counters.locations = {}
    weaponConfig.repair.counters.account = 'cash'
    weaponConfig.repair.counters.pricePerPoint = 15
end

---------------------------------------------------------------------------
-- Defaults ship disabled
---------------------------------------------------------------------------
reset()
H.equal(weaponConfig.jams.enabled, false, 'jams ship disabled')
H.equal(weaponConfig.jams.baseChance, 0.002, 'default base jam chance')
H.equal(weaponConfig.jams.lowDurabilityChance, 0.03, 'default low durability jam chance')
H.equal(weaponConfig.jams.lowDurabilityBelow, 30, 'default low durability threshold')
H.equal(weaponConfig.jams.clearTime, 1500, 'default clear time')
H.equal(weaponConfig.repair.counters.enabled, false, 'repair counters ship disabled')
H.equal(#weaponConfig.repair.counters.locations, 0, 'and with no locations')
H.equal(weaponConfig.repair.kits.repairkit.restore, 25, 'repairkit restores 25')
H.equal(weaponConfig.repair.kits.advancedrepairkit.restore, 60, 'advancedrepairkit restores 60')
H.equal(weaponConfig.repair.cleaning.item, 'cleaningkit', 'cleaning item default')

---------------------------------------------------------------------------
-- Jam chance curve (pure)
---------------------------------------------------------------------------
local function near(actual, expected, message)
    H.ok(math.abs(actual - expected) < 1e-9, ('%s: expected %s, got %s'):format(message, expected, actual))
end
local cfg = { baseChance = 0.002, lowDurabilityChance = 0.03, lowDurabilityBelow = 30 }
near(upkeep.jamChance(100, cfg), 0.002, 'full durability uses the base chance')
near(upkeep.jamChance(30, cfg), 0.03, 'at the threshold uses the low chance')
near(upkeep.jamChance(5, cfg), 0.03, 'below the threshold stays at the low chance')
near(upkeep.jamChance(0, cfg), 0.03, 'a broken weapon uses the low chance')
near(upkeep.jamChance(65, cfg), 0.016, 'halfway between blends linearly')
H.ok(upkeep.jamChance(90, cfg) < upkeep.jamChance(60, cfg), 'chance rises as durability falls')
near(upkeep.jamChance(250, cfg), 0.002, 'durability above 100 is clamped')
near(upkeep.jamChance(-5, cfg), 0.03, 'negative durability is clamped')
near(upkeep.jamChance(50, { baseChance = 0.5, lowDurabilityChance = 0.5, lowDurabilityBelow = 100 }), 0.5, 'threshold 100 means always the low chance')
near(upkeep.jamChance(50, { baseChance = 7, lowDurabilityChance = 9, lowDurabilityBelow = 30 }), 1, 'chances are capped at 1')
near(upkeep.jamChanceForRounds(100, 0, cfg), 0, 'no rounds, no chance')
near(upkeep.jamChanceForRounds(100, 1, cfg), 0.002, 'one round equals the single chance')
H.ok(upkeep.jamChanceForRounds(100, 10, cfg) > 0.002, 'several rounds raise the chance')

---------------------------------------------------------------------------
-- Which weapons can jam
---------------------------------------------------------------------------
H.equal(upkeep.canJam('weapon_pistol'), true, 'a pistol can jam')
H.equal(upkeep.canJam('weapon_bat'), false, 'melee never jams')
H.equal(upkeep.canJam('weapon_grenade'), false, 'throwables never jam')
H.equal(upkeep.canJam('weapon_flashlight'), false, 'a weapon that takes no ammo never jams')
H.equal(upkeep.canJam('not_a_weapon'), false, 'an unknown item never jams')
weaponConfig.jams.excluded = { weapon_pistol = true }
H.equal(upkeep.canJam('weapon_pistol'), false, 'excluded weapons never jam')
weaponConfig.jams.excluded = {}

---------------------------------------------------------------------------
-- Jam on an accepted shot
---------------------------------------------------------------------------
reset()
draw(1)
upkeep.random = function() return 0 end -- would always jam
H.equal(upkeep.afterShots(7, equipped[7], 1), false, 'jams disabled: never jams')
weaponConfig.jams.enabled = true
H.equal(upkeep.afterShots(7, equipped[7], 1), true, 'enabled and rolled: the weapon jams')
H.equal(info(1).jammed, true, 'the jam is stored on the weapon slot')
H.equal(clientEvents[#clientEvents].name, 'kora_inventory:client:weaponJamState', 'the client is told')
H.equal(clientEvents[#clientEvents].payload.slot, 1, 'which slot')
H.equal(clientEvents[#clientEvents].payload.jammed, true, 'and that it is jammed')
local events = #clientEvents
H.equal(upkeep.afterShots(7, equipped[7], 1), false, 'an already jammed weapon is not re-rolled')
H.equal(#clientEvents, events, 'and the client is not told twice')

reset()
weaponConfig.jams.enabled = true
upkeep.random = function() return 0 end
draw(2)
H.equal(upkeep.afterShots(7, equipped[7], 1), false, 'a drawn melee weapon never jams')
H.equal(info(2).jammed, nil, 'and stores nothing')
draw(1)
weaponConfig.jams.excluded = { weapon_pistol = true }
H.equal(upkeep.afterShots(7, equipped[7], 1), false, 'an excluded weapon never jams')
weaponConfig.jams.excluded = {}
upkeep.random = function() return 0.999 end
H.equal(upkeep.afterShots(7, equipped[7], 1), false, 'a roll above the chance does not jam')
H.equal(info(1).jammed, nil, 'and stores nothing')

-- The chance follows the weapon's durability.
local seen
upkeep.random = function() seen = true; return 0.01 end
info(1).durability = 100
H.equal(upkeep.afterShots(7, equipped[7], 1), false, '1% roll vs 0.2% chance at full durability: no jam')
info(1).durability = 10
H.equal(upkeep.afterShots(7, equipped[7], 1), true, '1% roll vs 3% chance at low durability: jams')
H.ok(seen, 'the roll uses the injected random')

---------------------------------------------------------------------------
-- A jammed weapon rejects shots (server-side)
---------------------------------------------------------------------------
reset()
local before = #info(1).loadedBullets
local fired = weapons.fireRound(7, 1)
H.equal(fired, true, 'an un-jammed weapon fires')
H.equal(#info(1).loadedBullets, before - 1, 'and spends one round')
weapons.setState(7, 1, { jammed = true })
H.equal(info(1).jammed, true, 'setState stores the jam')
local ok, reason = weapons.fireRound(7, 1)
H.equal(ok, false, 'a jammed weapon rejects the shot')
H.equal(reason, 'weapon is jammed', 'with the jam as the reason')
H.equal(#info(1).loadedBullets, before - 1, 'and keeps its ammunition')
ok, reason = KoraInventory.internal.fireWeaponShot(7, 1, 0.1)
H.equal(ok, false, 'the native shot path (fireWeaponShot) rejects it too')
H.equal(info(1).durability, 80, 'and applies no wear')
H.equal(select(1, weapons.setState(7, 1, { jammed = 'yes' })), false, 'a non-boolean jam state is refused')
weapons.setState(7, 1, { jammed = false })
H.equal(info(1).jammed, nil, 'clearing removes the key entirely')
H.equal(weapons.fireRound(7, 1), true, 'and the weapon fires again')
local prepared = weapons.prepareMetadata('weapon_pistol', { jammed = 'yes' })
H.equal(prepared.jammed, nil, 'metadata normalisation drops a non-boolean jam')
prepared = weapons.prepareMetadata('weapon_pistol', { jammed = true })
H.equal(prepared.jammed, true, 'and keeps a real one')

---------------------------------------------------------------------------
-- Clearing a jam: server-resolved weapon, server-run bar
---------------------------------------------------------------------------
reset()
weapons.setState(7, 1, { jammed = true })
local cleared, why = upkeep.clearJam(7)
H.equal(cleared, false, 'nothing drawn: nothing is cleared')
H.equal(info(1).jammed, true, 'the jam stays')
H.equal(#barRequests, 0, 'and no bar is run')

draw(2)
cleared = upkeep.clearJam(7)
H.equal(cleared, false, 'a drawn weapon that is not jammed cannot be cleared')
H.equal(info(1).jammed, true, 'the OTHER weapon is untouched: the server resolved the drawn one')
H.equal(#barRequests, 0, 'no bar for a weapon that is not jammed')

draw(1)
cleared = upkeep.clearJam(7)
H.equal(cleared, true, 'the drawn jammed weapon is cleared')
H.equal(info(1).jammed, nil, 'the jam is gone from metadata')
H.equal(barRequests[1].name, 'kora_inventory:client:weaponUpkeepBar', 'a bar was requested from the client')
H.equal(barRequests[1].payload.kind, 'clear', 'for clearing')
H.equal(barRequests[1].payload.time, 1500, 'with the configured clear time')
H.equal(clientEvents[#clientEvents].payload.jammed, false, 'and the client is told it is clear')

-- Cancelled / instant / dead-client bars never clear
for _, case in ipairs({ { 'cancelled bar', false, true }, { 'client error', 'error', true }, { 'instant answer', true, false } }) do
    reset()
    weapons.setState(7, 1, { jammed = true })
    draw(1)
    barAnswer, barAdvance = case[2], case[3]
    H.equal(upkeep.clearJam(7), false, case[1] .. ' does not clear')
    H.equal(info(1).jammed, true, case[1] .. ' leaves the jam')
    H.equal(upkeep.clearJam(7) == false and true or false, true, case[1] .. ' can be retried')
end

-- Swapping weapons mid-bar does not clear a jam on a different weapon
reset()
weapons.setState(7, 1, { jammed = true })
draw(1)
beforeAnswer = function() draw(6) end
H.equal(upkeep.clearJam(7), false, 'holstering/swapping mid-bar aborts the clear')
H.equal(info(1).jammed, true, 'the jam stays')

-- The net event carries no payload and ignores anything sent
reset()
weapons.setState(7, 1, { jammed = true })
weapons.setState(7, 6, { jammed = true })
draw(1)
source = 7
netEvents['kora_inventory:server:clearJam']('weapon_revolver', 6, 'forged')
H.equal(info(1).jammed, nil, 'the event clears the server-resolved drawn weapon')
H.equal(info(6).jammed, true, 'and nothing named in a forged payload')
equipped = {}
weapons.setState(7, 1, { jammed = true })
netEvents['kora_inventory:server:clearJam']()
H.equal(info(1).jammed, true, 'with nothing drawn the event does nothing')
GetInvokingResource = function() return 'other_resource' end
draw(1)
netEvents['kora_inventory:server:clearJam']()
H.equal(info(1).jammed, true, 'a local trigger from another resource is ignored')
GetInvokingResource = function() return nil end

-- Draw sync: a weapon drawn while jammed arrives blocked
reset()
weapons.setState(7, 1, { jammed = true })
draw(1)
clientEvents = {}
upkeep.syncDrawn(7)
H.equal(clientEvents[1].payload.jammed, true, 'syncDrawn tells the client a drawn weapon is jammed')

---------------------------------------------------------------------------
-- Built-in usables are registered only for configured names
---------------------------------------------------------------------------
reset()
upkeep.refresh()
H.ok(useables.repairkit, 'repairkit gets a built-in handler')
H.ok(useables.advancedrepairkit, 'advancedrepairkit gets a built-in handler')
H.ok(useables.cleaningkit, 'cleaningkit gets a built-in handler')
H.equal(useables.water_bottle, nil, 'an unlisted item is not hijacked')
H.equal(useableKinds.repairkit.upkeep ~= nil, true, 'registered under the composable upkeep kind')
weaponConfig.repair.enabled = false
upkeep.refresh()
H.equal(useables.repairkit, nil, 'repair.enabled = false leaves the items to other resources')
H.equal(useables.cleaningkit, nil, 'including the cleaning item')
weaponConfig.repair.enabled = true
weaponConfig.repair.kits.advancedrepairkit = false
upkeep.refresh()
H.equal(useables.advancedrepairkit, nil, 'a kit set to false is released')
weaponConfig.repair.kits.advancedrepairkit = { restore = 60, time = 6000 }
sharedHandler(nil, 'repairkit', definitions.repairkit)
H.ok(useables.repairkit, 'a registry change re-registers the handler')
sharedHandler(nil, 'repairkit', nil)
H.equal(useables.repairkit, nil, 'and a removed definition unregisters it')
upkeep.refresh()

---------------------------------------------------------------------------
-- Repair kits
---------------------------------------------------------------------------
reset()
upkeep.refresh()
local used, usedWhy = useables.repairkit(7, { name = 'repairkit', slot = 3 })
H.equal(used, false, 'a kit with nothing drawn is refused')
H.equal(#removals, 0, 'and not consumed')
H.equal(#barRequests, 0, 'and no bar runs')

draw(1)
used = useables.repairkit(7, { name = 'repairkit', slot = 3 })
H.equal(used, true, 'a kit repairs the drawn weapon')
H.equal(info(1).durability, 100, 'restores 25 from 80, capped at 100')
H.equal(#removals, 1, 'one kit is consumed')
H.equal(removals[1].slot, 3, 'from the used slot')
H.equal(barRequests[1].payload.kind, 'repair', 'a repair bar ran')
H.equal(barRequests[1].payload.time, 4000, 'for the kit time')
H.equal(info(2).durability, 80, 'the weapon that is not drawn is untouched')

reset()
upkeep.refresh()
draw(1)
info(1).durability = 10
H.equal(useables.advancedrepairkit(7, { name = 'advancedrepairkit', slot = 4 }), true, 'advanced kit works')
H.equal(info(1).durability, 70, 'restores 60 points')
H.equal(barRequests[1].payload.time, 6000, 'with its own time')

reset()
upkeep.refresh()
draw(1)
weaponConfig.repair.maxDurability = 90
H.equal(useables.repairkit(7, { name = 'repairkit', slot = 3 }), true, 'repair under a lower ceiling')
H.equal(info(1).durability, 90, 'never goes above maxDurability')
H.equal(useables.repairkit(7, { name = 'repairkit', slot = 3 }), false, 'a weapon at the ceiling is refused')
H.equal(#removals, 1, 'and no second kit is consumed')
H.equal(upkeep.restoreTarget(95, 25, 100), 100, 'restoreTarget caps at max')
H.equal(upkeep.restoreTarget(40, 25, 100), 65, 'restoreTarget adds below max')
H.equal(upkeep.restoreTarget(40, -10, 100), 40, 'restoreTarget never subtracts')
H.equal(upkeep.maxDurability(), 90, 'maxDurability is read live')
weaponConfig.repair.maxDurability = 5000
H.equal(upkeep.maxDurability(), 100, 'and never exceeds the 100 hard ceiling')

reset()
upkeep.refresh()
draw(1)
barAnswer = false
H.equal(useables.repairkit(7, { name = 'repairkit', slot = 3 }), false, 'a cancelled bar keeps the kit')
H.equal(info(1).durability, 80, 'and repairs nothing')
H.equal(#removals, 0, 'and consumes nothing')
barAnswer, barAdvance = true, false
H.equal(useables.repairkit(7, { name = 'repairkit', slot = 3 }), false, 'an instant answer is treated as a cancel')
barAdvance = true
removeResult = 'cannot remove'
H.equal(useables.repairkit(7, { name = 'repairkit', slot = 3 }), false, 'a kit that cannot be charged')
H.equal(info(1).durability, 80, 'repairs nothing (the restore is undone)')
removeResult = true
beforeAnswer = function() state['player:7'].items[3] = nil end
H.equal(useables.repairkit(7, { name = 'repairkit', slot = 3 }), false, 'a kit dropped mid-bar is refused')
H.equal(info(1).durability, 80, 'and repairs nothing')
beforeAnswer = nil
beforeAnswer = function() draw(6) end
H.equal(useables.repairkit(7, { name = 'repairkit', slot = 3 }), false, 'swapping weapons mid-bar is refused')
H.equal(info(1).durability, 80, 'and the old weapon is not repaired')
H.equal(info(6).durability, 100, 'nor the new one')

reset()
upkeep.refresh()
draw(2)
state['player:7'].items[3].name = 'water_bottle'
H.equal(useables.repairkit(7, { name = 'water_bottle', slot = 3 }), false, 'an item that is not a configured kit is refused')

---------------------------------------------------------------------------
-- Cleaning
---------------------------------------------------------------------------
reset()
upkeep.refresh()
draw(1)
weapons.setState(7, 1, { jammed = true })
H.equal(useables.cleaningkit(7, { name = 'cleaningkit', slot = 5 }), true, 'cleaning works')
H.equal(info(1).jammed, nil, 'it clears the jam')
H.equal(info(1).durability, 85, 'and restores 5 durability')
H.equal(#removals, 1, 'consuming one item')
H.equal(barRequests[1].payload.kind, 'clean', 'with a cleaning bar')
H.equal(barRequests[1].payload.time, 3000, 'of the configured time')

reset()
upkeep.refresh()
draw(1)
info(1).durability = 100
H.equal(useables.cleaningkit(7, { name = 'cleaningkit', slot = 5 }), false, 'a clean, undamaged weapon needs no cleaning')
H.equal(#removals, 0, 'and nothing is consumed')
weaponConfig.repair.cleaning.clearsJam = false
weapons.setState(7, 1, { jammed = true })
H.equal(useables.cleaningkit(7, { name = 'cleaningkit', slot = 5 }), false, 'clearsJam = false: a jammed full-durability weapon is not cleaned')
H.equal(info(1).jammed, true, 'and the jam is untouched')
weaponConfig.repair.cleaning.clearsJam = true

---------------------------------------------------------------------------
-- Repair counters
---------------------------------------------------------------------------
H.equal(upkeep.counterPrice(20, 15), 300, 'price is missing points times the per-point price')
H.equal(upkeep.counterPrice(20.01, 15), 301, 'a fraction of a point rounds the price up')
H.equal(upkeep.counterPrice(0, 15), 0, 'nothing missing costs nothing')
H.equal(upkeep.counterPrice(-4, 15), 0, 'negative missing costs nothing')
H.equal(upkeep.counterPrice(10, 0), 0, 'a free counter is free')

local counter = { coords = { x = 10.0, y = 10.0, z = 30.0 }, distance = 2.5, label = 'Weapon repairs' }
H.equal(upkeep.withinCounter(counter, { x = 11.0, y = 10.0, z = 30.0 }, 0), true, 'within range')
H.equal(upkeep.withinCounter(counter, { x = 12.5, y = 10.0, z = 30.0 }, 0), true, 'exactly at the radius')
H.equal(upkeep.withinCounter(counter, { x = 13.0, y = 10.0, z = 30.0 }, 0), false, 'too far')
H.equal(upkeep.withinCounter(counter, { x = 10.0, y = 10.0, z = 40.0 }, 0), false, 'distance includes height')
H.equal(upkeep.withinCounter(counter, { x = 10.0, y = 10.0, z = 30.0 }, 3), false, 'a different routing bucket is refused')
H.equal(upkeep.withinCounter({ coords = counter.coords, bucket = 3 }, { x = 10.0, y = 10.0, z = 30.0 }, 3), true, 'a counter can name its bucket')
H.equal(upkeep.withinCounter({}, { x = 0, y = 0, z = 0 }, 0), false, 'a counter without coordinates never matches')

reset()
weaponConfig.repair.counters.locations = { counter }
draw(1)
local repaired, result = exported.repairWeaponAt(7, 1)
H.equal(repaired, false, 'disabled counters refuse')
H.equal(#charges, 0, 'and charge nothing')

weaponConfig.repair.counters.enabled = true
repaired, result = exported.repairWeaponAt(7, 1)
H.equal(repaired, true, 'an enabled counter repairs the drawn weapon')
H.equal(result.price, 300, 'priced at 20 missing points x 15')
H.equal(info(1).durability, 100, 'restored to maxDurability')
H.equal(#charges, 1, 'charged exactly once')
H.equal(charges[1].account, 'cash', 'to the configured account')
H.equal(charges[1].amount, 300, 'for the computed price')
H.equal(money.cash, 700, 'the money left the account')

info(1).durability = 80
weaponConfig.repair.counters.account = 'bank'
money.bank = 5000
weaponConfig.repair.counters.pricePerPoint = 20
repaired, result = exported.repairWeaponAt(7, 1)
H.equal(repaired, true, 'config is read live: bank account')
H.equal(charges[2].account, 'bank', 'charged to the bank')
H.equal(charges[2].amount, 400, 'at the live price per point')
weaponConfig.repair.counters.account = 'nonsense'
info(1).durability = 90
exported.repairWeaponAt(7, 1)
H.equal(charges[3].account, 'cash', 'an unknown account falls back to cash')

-- Refusals charge nothing
local function refused(message, index)
    local count = #charges
    local ok2 = exported.repairWeaponAt(7, index or 1)
    H.equal(ok2, false, message)
    H.equal(#charges, count, message .. ' (nothing charged)')
end
info(1).durability = 50
coords = { x = 30.0, y = 10.0, z = 30.0 }
refused('too far from the counter')
H.equal(info(1).durability, 50, 'and the weapon is not repaired')
coords = { x = 10.0, y = 10.0, z = 30.0 }
bucket = 4
refused('wrong routing bucket')
bucket = 0
refused('an unknown counter index', 2)
refused('a zero counter index', 0)
refused('a negative counter index', -1)
refused('a non-numeric counter index', 'abc')
equipped = {}
refused('no weapon drawn')
draw(1)
info(1).durability = 100
refused('a weapon that needs no repair')
info(1).durability = 50
weaponConfig.repair.counters.account = 'cash'
money.cash = 10
H.equal(exported.repairWeaponAt(7, 1), false, 'insufficient funds refuse the repair')
H.equal(money.cash, 10, 'and take nothing')
H.equal(info(1).durability, 50, 'a failed payment repairs nothing')
money.cash = 10000

-- A counter repair also clears a jam
weapons.setState(7, 1, { jammed = true })
H.equal(exported.repairWeaponAt(7, 1), true, 'a jammed weapon is repaired at the counter')
H.equal(info(1).jammed, nil, 'which also clears the jam')
info(1).durability = 100
weapons.setState(7, 1, { jammed = true })
H.equal(exported.repairWeaponAt(7, 1), true, 'a full-durability jammed weapon can still be serviced')
H.equal(info(1).jammed, nil, 'clearing its jam')

-- Quote then confirm
reset()
weaponConfig.repair.counters.locations = { counter }
weaponConfig.repair.counters.enabled = true
draw(1)
local quoted, quote = registeredCallbacks['kora_inventory:server:repairQuote'](7, 1)
H.equal(quoted, true, 'a quote is issued at the counter')
H.equal(quote.price, 300, 'with the server-computed price')
H.equal(quote.account, 'cash', 'and account')
H.equal(quote.weapon, 'Pistol', 'naming the drawn weapon')
H.equal(#charges, 0, 'a quote charges nothing')
source = 7
netEvents['kora_inventory:server:repairConfirm'](1)
H.equal(#charges, 1, 'confirming charges')
H.equal(info(1).durability, 100, 'and repairs')
netEvents['kora_inventory:server:repairConfirm'](1)
H.equal(#charges, 1, 'a confirm cannot be replayed without a new quote')

info(1).durability = 50
registeredCallbacks['kora_inventory:server:repairQuote'](7, 1)
netEvents['kora_inventory:server:repairConfirm'](2)
H.equal(#charges, 1, 'a confirm for a different counter is refused')
registeredCallbacks['kora_inventory:server:repairQuote'](7, 1)
info(1).durability = 70 -- shots fired since the quote: the price moved
netEvents['kora_inventory:server:repairConfirm'](1)
H.equal(#charges, 1, 'a confirm after the price changed is refused')
registeredCallbacks['kora_inventory:server:repairQuote'](7, 1)
NOW = NOW + 31000
netEvents['kora_inventory:server:repairConfirm'](1)
H.equal(#charges, 1, 'an expired quote is refused')
netEvents['kora_inventory:server:repairConfirm'](1)
H.equal(#charges, 1, 'and so is a confirm with no quote at all')
coords = { x = 99.0, y = 10.0, z = 30.0 }
quoted = registeredCallbacks['kora_inventory:server:repairQuote'](7, 1)
H.equal(quoted, false, 'no quote is issued away from the counter')
coords = { x = 10.0, y = 10.0, z = 30.0 }
registeredCallbacks['kora_inventory:server:repairQuote'](7, 1)
coords = { x = 99.0, y = 10.0, z = 30.0 }
netEvents['kora_inventory:server:repairConfirm'](1)
H.equal(#charges, 1, 'a confirm after walking away is refused (position re-checked)')

H.finish()
