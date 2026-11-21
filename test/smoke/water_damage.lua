-- Water damage: payload-free report, rate limit, injected-RNG chance rolls, the
-- flag / convert / remove modes, the use block, repair and the disabled config.
-- Real server.lua + server/water_damage.lua; only natives and kora_core are stubbed.
local H = dofile('test/harness.lua')

Config = { kora_inventory = {} }
dofile('config.lua')
dofile('shared.lua')

local function clone(value)
    local seen = {}
    local function copy(v)
        if type(v) ~= 'table' then return v end
        if seen[v] then return seen[v] end
        local out = {}
        seen[v] = out
        for k, vv in pairs(v) do out[copy(k)] = copy(vv) end
        return out
    end
    return copy(value)
end

local callbacks, handlers, netEvents = {}, {}, {}
local notified = {}
Kora = {
    util = { deepClone = clone },
    resources = { serverRegistry = function() return { track = function() end, untrack = function() end } end },
    callback = { register = function(name, fn) callbacks[name] = fn end },
    distance = { player = function() return true end },
    sql = {},
    notify = { send = function(_, payload) notified[#notified + 1] = payload end },
    lang = function(key) return key end,
}
NOW = 100000
GetCurrentResourceName = function() return 'kora_inventory' end
GetInvokingResource = function() return nil end
CreateThread = function() end
RegisterCommand = function() end
AddEventHandler = function(name, fn) handlers[name] = handlers[name] or {}; table.insert(handlers[name], fn) end
RegisterNetEvent = function(name, fn) netEvents[name] = fn end
TriggerClientEvent = function() end
TriggerEvent = function(name, ...) for _, fn in ipairs(handlers[name] or {}) do fn(...) end end
GetGameTimer = function() return NOW end
GetPlayerPed = function(source) return source end
GetEntityCoords = function() return { x = 0, y = 0, z = 0 } end
GetPlayerRoutingBucket = function() return 0 end

local ITEMS = {
    phone = { name = 'phone', label = 'Phone', weight = 100, useable = true },
    iphone = { name = 'iphone', label = 'iPhone', weight = 100, useable = true },
    radio = { name = 'radio', label = 'Radio', weight = 200, useable = true },
    electronickit = { name = 'electronickit', label = 'Electronic Kit', weight = 300, useable = true },
    garbage = { name = 'garbage', label = 'Garbage', weight = 50 },
    sandwich = { name = 'sandwich', label = 'Sandwich', weight = 50 },
    backpack = { name = 'backpack', label = 'Backpack', weight = 500, unique = true },
}
local playerData = { [7] = { citizenid = 'CID-7' }, [8] = { citizenid = 'CID-8' } }
local playersItems = { [7] = {}, [8] = {} }
playersMetadata = {}
local registered = {}
exports = setmetatable({}, {
    __call = function(_, name, fn) registered[name] = fn end,
    __index = function(_, resource)
        return setmetatable({}, { __index = function(_, name)
            return function(_, ...)
                if resource == 'kora_core' then
                    if name == 'allShared' then return {} end
                    if name == 'getShared' then
                        local registry, item = ...
                        return registry == 'items' and ITEMS[item] or nil
                    end
                    if name == 'getPlayerData' then
                        local src, fields = ...
                        if not playerData[src] then return nil end
                        if fields and fields[1] == 'items' then
                            if fields[2] then return playersItems[src][fields[2]] end
                            return playersItems[src]
                        end
                        if fields and fields[1] == 'metadata' then return playersMetadata[src] end
                        return playerData[src]
                    end
                    if name == 'setPath' then
                        local src, path, value = ...
                        if path[1] ~= 'items' then return false, 'unsupported path' end
                        if path[2] then playersItems[src][path[2]] = value else playersItems[src] = value end
                        return true
                    end
                end
                local fn = registered[name]
                if fn then return fn(...) end
            end
        end })
    end,
})

dofile('server/persistence.lua')
dofile('server.lua')
dofile('server/containers.lua')
dofile('server/water_damage.lua')

local I, W = KoraInventory.internal, KoraInventory.waterDamage
local cfg = Config.kora_inventory.waterDamage
H.equal(cfg.enabled, false, 'water damage ships disabled')
H.equal(cfg.mode, 'flag', 'the default mode is flag')
H.equal(cfg.repairItem, 'electronickit', 'the default repair item is electronickit')
H.equal(cfg.items.radio.chance, 0.5, 'the radio defaults to a 50% chance')

local function fresh()
    W.reset()
    NOW = NOW + 100000
    playersItems[7] = {
        [1] = I.buildItem('phone', 1, 1, {}),
        [2] = I.buildItem('radio', 1, 2, {}),
        [3] = I.buildItem('sandwich', 2, 3, {}),
        [4] = I.buildItem('iphone', 1, 4, {}),
    }
    notified = {}
end
local function always(value) return function() return value end end

-- Disabled -------------------------------------------------------------------

fresh()
W.setRandom(always(0))
local ok, reason = W.report(7)
H.equal(ok, false, 'a disabled feature accepts nothing')
H.equal(reason, 'disabled', 'with the disabled reason')
H.equal(playersItems[7][1].info.waterDamaged, nil, 'a disabled feature never damages')

cfg.enabled = true

-- Rate limit -----------------------------------------------------------------

fresh()
W.setRandom(always(0.99))
ok = W.report(7)
H.ok(ok, 'the first report is accepted')
ok, reason = W.report(7)
H.equal(ok, false, 'a second report at once is refused')
H.equal(reason, 'rate limited', 'as rate limited')
NOW = NOW + 9999
ok = W.report(7)
H.equal(ok, false, 'still limited just under ten seconds later')
NOW = NOW + 1
ok = W.report(7)
H.ok(ok, 'accepted again after ten seconds')
H.ok(W.report(8) ~= nil, 'another player has their own limit')
H.equal(select(1, W.report(0)), false, 'an invalid source is refused')
H.equal(select(1, W.report('x')), false, 'a malformed source is refused')

-- Chance rolls with an injected RNG ----------------------------------------------

fresh()
W.setRandom(always(0.99))
W.report(7)
H.equal(playersItems[7][1].info.waterDamaged, true, 'chance 1.0 damages even at roll 0.99')
H.equal(playersItems[7][4].info.waterDamaged, true, 'every configured phone is rolled')
H.equal(playersItems[7][2].info.waterDamaged, nil, 'chance 0.5 survives a 0.99 roll')
H.equal(playersItems[7][3].info.waterDamaged, nil, 'an unconfigured item is never touched')

fresh()
W.setRandom(always(0.1))
W.report(7)
H.equal(playersItems[7][2].info.waterDamaged, true, 'chance 0.5 is damaged by a 0.1 roll')

fresh()
cfg.items.radio.chance = 0
W.setRandom(always(0))
W.report(7)
H.equal(playersItems[7][2].info.waterDamaged, nil, 'chance 0 never damages, whatever the roll')
cfg.items.radio.chance = 0.5

-- A roll is made once per configured stack, in slot order (deterministic).
fresh()
local rolls = 0
W.setRandom(function() rolls = rolls + 1; return 0.99 end)
W.report(7)
H.equal(rolls, 3, 'one roll per configured item stack (phone, radio, iphone)')

-- The inventory change is a real write: revision bumped, other slots untouched.
fresh()
local before = I.getRevision('player:7')
W.setRandom(always(0))
W.report(7)
H.ok(I.getRevision('player:7') > before, 'flagging bumps the player inventory revision')
H.equal(playersItems[7][3].amount, 2, 'other stacks keep their amount')

-- Flag mode: already flagged items are not rolled again ------------------------

fresh()
W.setRandom(always(0))
W.report(7)
NOW = NOW + 10000
rolls = 0
W.setRandom(function() rolls = rolls + 1; return 0 end)
W.report(7)
H.equal(rolls, 0, 'items already water damaged are not rolled again in flag mode')

-- Containers protect their contents -----------------------------------------------

fresh()
playersItems[7][5] = I.buildItem('backpack', 1, 5, {})
H.ok(KoraInventory.containers.openConfiguredItem(7, 5), 'a backpack opens (binds)')
local bagId = playersItems[7][5].info.containerId
H.ok(I.setInventoryItems('container:' .. bagId, { [1] = I.buildItem('phone', 1, 1, {}) }), 'a phone sits inside the bag')
I.close(7, 'test')
W.setRandom(always(0))
W.report(7)
H.equal(I.getInventory('container:' .. bagId).items[1].info.waterDamaged, nil, 'a phone inside a portable container is never damaged')
H.equal(playersItems[7][1].info.waterDamaged, true, 'while the pocket phone is')

-- Use is blocked until repaired ----------------------------------------------------

fresh()
local used = 0
KoraInventory.api.createUseable('phone', function() used = used + 1; return true end)
KoraInventory.api.createUseable('electronickit', function() used = used + 100; return true end)
H.ok(KoraInventory.api.useItem(7, 1), 'an undamaged phone is usable')
H.equal(used, 1, 'its handler ran')
W.setRandom(always(0))
W.report(7)
H.equal(playersItems[7][1].info.waterDamaged, true, 'the phone is now water damaged')
local useOK, useErr = KoraInventory.api.useItem(7, 1)
H.equal(useOK, false, 'a water damaged phone cannot be used')
H.equal(useErr, 'this item is water damaged', 'with the reason')
H.equal(used, 1, 'its handler did not run')
local told = false
for _, n in ipairs(notified) do if n.message == 'This item is water damaged.' then told = true end end
H.ok(told, 'the player is told the item is water damaged')

-- Disabled config ignores the flag (and nothing is damaged any more).
cfg.enabled = false
H.ok(KoraInventory.api.useItem(7, 1), 'with the feature off a flagged item is usable again')
cfg.enabled = true

-- View: badge + inspector row -------------------------------------------------------

local viewOK, payload = I.openSelf(7)
H.ok(viewOK, 'the own inventory opens')
local phone = payload.primary.items[1]
H.equal(phone.waterDamaged, true, 'the view carries the waterDamaged badge flag')
local rows = 0
for _, row in ipairs(phone.displayMeta) do
    if row.key == 'waterDamaged' then
        rows = rows + 1
        H.equal(row.label, 'Condition', 'the inspector row is labelled')
        H.equal(row.value, 'Water damaged', 'and states the condition')
    end
end
H.equal(rows, 1, 'exactly one inspector row (the raw metadata row is replaced)')
H.equal(payload.primary.items[3].waterDamaged, nil, 'other items have no badge')
-- A client-sent flag is never believed: the view recomputes it from metadata.
playersItems[7][3].waterDamaged = true
payload = select(2, I.openSelf(7))
H.equal(payload.primary.items[3].waterDamaged, nil, 'a stray waterDamaged field on a record is not echoed')
playersItems[7][3].waterDamaged = nil
I.close(7, 'test')

-- Repair ------------------------------------------------------------------------------

playersItems[7][6] = I.buildItem('electronickit', 3, 6, {})
used = 0
local repaired = KoraInventory.api.useItem(7, 6)
H.ok(repaired, 'using the repair item succeeds while something is damaged')
H.equal(used, 0, 'the repair item own handler did not run')
H.equal(playersItems[7][1].info.waterDamaged, nil, 'the first damaged item (lowest slot) is repaired')
H.equal(playersItems[7][2].info.waterDamaged, true, 'only one item is repaired per use')
H.equal(playersItems[7][4].info.waterDamaged, true, 'later slots stay damaged')
H.equal(playersItems[7][6].amount, 2, 'one repair item is consumed')
H.ok(KoraInventory.api.useItem(7, 1), 'the repaired phone works again')
H.ok(KoraInventory.api.useItem(7, 6), 'a second repair')
H.equal(playersItems[7][2].info.waterDamaged, nil, 'the next damaged item (slot 2) is repaired')
H.ok(KoraInventory.api.useItem(7, 6), 'a third repair')
H.equal(playersItems[7][4].info.waterDamaged, nil, 'the last damaged item is repaired')
H.equal(playersItems[7][6], nil, 'the last repair item is consumed and the slot freed')
playersItems[7][6] = I.buildItem('electronickit', 1, 6, {})
used = 0
KoraInventory.api.useItem(7, 6)
H.equal(used, 100, 'with nothing damaged the repair item behaves as it always did')
H.equal(playersItems[7][6].amount, 1, 'and nothing is consumed by the water-damage code')

-- Repair never works for free or on a stranger's slot.
fresh()
W.setRandom(always(0))
W.report(7)
local ghost = I.buildItem('electronickit', 1, 6, {})
H.equal(W.tryRepair(7, ghost), false, 'a repair item that is not really in the slot repairs nothing')
H.equal(playersItems[7][1].info.waterDamaged, true, 'so the damaged item stays damaged')
cfg.enabled = false
playersItems[7][6] = I.buildItem('electronickit', 1, 6, {})
H.equal(W.tryRepair(7, playersItems[7][6]), false, 'a disabled feature repairs nothing')
cfg.enabled = true

-- Convert -----------------------------------------------------------------------------

fresh()
cfg.mode, cfg.into = 'convert', 'garbage'
W.setRandom(always(0))
W.report(7)
local garbage, electronics = 0, 0
for _, item in pairs(playersItems[7]) do
    if item.name == 'garbage' then garbage = garbage + item.amount end
    if item.name == 'phone' or item.name == 'iphone' or item.name == 'radio' then electronics = electronics + 1 end
end
H.equal(garbage, 3, 'convert turns every damaged item into the configured item (stacking where it can)')
H.equal(electronics, 0, 'no damaged electronics remain')
H.equal(playersItems[7][3].name, 'sandwich', 'unlisted items stay')
fresh()
cfg.into = 'nonexistent_item'
W.report(7)
H.equal(playersItems[7][1].name, 'phone', 'an unknown convert target falls back to flagging, not deleting')
H.equal(playersItems[7][1].info.waterDamaged, true, 'the fallback flags the item')
cfg.into = nil
fresh()
W.report(7)
H.equal(playersItems[7][1].info.waterDamaged, true, 'a missing convert target also falls back to flagging')

-- Remove --------------------------------------------------------------------------------

fresh()
cfg.mode = 'remove'
W.setRandom(always(0))
W.report(7)
H.equal(playersItems[7][1], nil, 'remove deletes the phone')
H.equal(playersItems[7][4], nil, 'remove deletes every damaged item')
H.equal(playersItems[7][3].name, 'sandwich', 'unlisted items stay')

-- An unknown mode is treated as flag (never destructive by accident).
fresh()
cfg.mode = 'explode'
W.report(7)
H.equal(playersItems[7][1].name, 'phone', 'an unknown mode never destroys items')
H.equal(playersItems[7][1].info.waterDamaged, true, 'it flags instead')
cfg.mode = 'flag'

-- The network event is payload-free ------------------------------------------------------

H.ok(netEvents['kora_inventory:server:waterExposure'], 'the report event is registered')
fresh()
W.setRandom(always(0))
source = 7
netEvents['kora_inventory:server:waterExposure']({ slot = 2, item = 'sandwich', chance = 1, target = 8 }, 'garbage', 12)
H.equal(playersItems[7][1].info.waterDamaged, true, 'the event damages the SENDER items')
H.equal(playersItems[7][3].info.waterDamaged, nil, 'a slot or item named in the payload is ignored')
H.equal(playersItems[8][1], nil, 'a target named in the payload is ignored')
netEvents['kora_inventory:server:waterExposure']()
H.equal(select(1, W.report(7)), false, 'repeating the event inside ten seconds does nothing')

local clientSource = assert(io.open('client/water_damage.lua')):read('*a')
H.ok(clientSource:find('TriggerServerEvent%(EVENT%)'), 'the client sends the event with no arguments')
H.equal(clientSource:find('while true do Wait%(0%)'), nil, 'the client has no per-frame loop')

H.finish()
