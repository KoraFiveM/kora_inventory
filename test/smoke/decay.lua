-- Item decay. Part 1 drives the pure rules in shared/decay.lua with explicit
-- settings and a fixed clock. Part 2 loads the real server.lua against a stash
-- (no FXServer) to cover stamping on add, oldest-wins stacking, pause/resume on
-- move, lazy expiry on view/move/use, the view fields and the sweep.
local H = dofile('test/harness.lua')

local DAY = 86400
local T0 = 1700000000

Config = { kora_inventory = {} }
dofile('config.lua')
local defaults = Config.kora_inventory.decay

-- ---------------------------------------------------------------- defaults --
H.equal(defaults.enabled, false, 'decay ships disabled so live servers do not lose food')
H.equal(defaults.items.sandwich.into, 'garbage', 'sandwich spoils into garbage')
H.equal(defaults.items.sandwich.lifetime, 172800, 'sandwich lasts two days')
H.equal(defaults.items.water_bottle.into, nil, 'water bottle is removed when spoiled')
H.equal(defaults.mergePolicy, 'oldest', 'merge policy defaults to oldest')
H.equal(defaults.sweepSeconds, 300, 'sweep defaults to five minutes')
for _, kind in ipairs({ 'stash', 'trunk', 'glovebox', 'container', 'drop' }) do
    H.equal(defaults.pauseIn[kind], false, 'storage pause is off by default for ' .. kind)
end

KoraInventory = nil
dofile('shared.lua')
-- shared.lua needs Kora.util.deepClone only when copying; keep a simple one here.
local function clone(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do out[clone(k)] = clone(x) end
    return out
end
Kora = { util = { deepClone = clone } }
dofile('shared/decay.lua')
local inv = KoraInventory
local D = inv.decay

local function cfg(extra)
    local c = {
        enabled = true, defaultAction = 'convert', mergePolicy = 'oldest', sweepSeconds = 300,
        items = {
            sandwich = { lifetime = 2 * DAY, into = 'garbage' },
            water_bottle = { lifetime = 7 * DAY },
            plain = { lifetime = 100, into = '' },
        },
        pauseIn = { stash = false, trunk = true, glovebox = false, container = true, drop = false },
    }
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
end

-- ------------------------------------------------------------------- rules --
do
    local c = cfg()
    local rule = D.rule('sandwich', nil, c)
    H.equal(rule.lifetime, 2 * DAY, 'config lifetime')
    H.equal(rule.action, 'convert', 'config entry with into converts')
    H.equal(rule.into, 'garbage', 'config into')
    H.equal(D.rule('SANDWICH', nil, c).into, 'garbage', 'item names are case-insensitive')
    H.equal(D.rule('water_bottle', nil, c).action, 'remove', 'no into removes')
    H.equal(D.rule('plain', nil, c).action, 'remove', 'empty into removes')
    H.equal(D.rule('rock', nil, c), nil, 'unlisted items do not decay')
    H.equal(D.rule('sandwich', nil, cfg({ enabled = false })), nil, 'disabled config yields no rules')
    H.equal(D.rule('sandwich', nil, nil), nil, 'missing config yields no rules')
    H.equal(D.rule('sandwich', nil, cfg({ defaultAction = 'remove' })).action, 'remove', "defaultAction 'remove' always removes")
    H.equal(D.rule('x', nil, cfg({ items = { x = { lifetime = 0 } } })), nil, 'zero lifetime is not a rule')
    H.equal(D.rule('x', nil, cfg({ items = { x = { lifetime = -5 } } })), nil, 'negative lifetime is not a rule')
    H.equal(D.rule('x', nil, cfg({ items = { x = { lifetime = 'soon' } } })), nil, 'non-numeric lifetime is not a rule')

    -- Definition-level rule, and config wins over it.
    local def = { name = 'apple', decay = { lifetime = 3600, into = 'apple_core' } }
    local fromDef = D.rule('apple', def, c)
    H.equal(fromDef.lifetime, 3600, 'definition-level rule is honoured')
    H.equal(fromDef.into, 'apple_core', 'definition-level into')
    local override = cfg({ items = { apple = { lifetime = 60 } } })
    H.equal(D.rule('apple', def, override).lifetime, 60, 'config entry wins over the definition')
    H.equal(D.rule('apple', def, override).action, 'remove', 'the whole config entry wins, including a missing into')
    H.equal(D.rule('apple', def, cfg({ items = { apple = false } })), nil, 'items[name] = false exempts a definition rule')
    H.equal(D.rule('apple', def, cfg({ enabled = false })), nil, 'disabled beats a definition rule')
    H.equal(D.rule('apple', { decay = 'junk' }, c), nil, 'malformed definition rule is ignored')
end

-- ------------------------------------------------------ stamp and remaining --
do
    local rule = D.rule('sandwich', nil, cfg())
    local item = { name = 'sandwich', amount = 1, info = {}, metadata = {} }
    H.ok(D.stampItem(item, rule, T0, false), 'an unstamped item gets stamped')
    H.equal(item.info.createdAt, T0, 'createdAt is the stamp time')
    H.equal(item.info.decayLifetime, 2 * DAY, 'lifetime snapshot is stored')
    H.equal(item.metadata.createdAt, T0, 'metadata mirror is kept in step')
    H.equal(D.stampItem(item, rule, T0 + 500, false), false, 'a stamped item is not restamped')
    H.equal(item.info.createdAt, T0, 'the original stamp survives')

    local st = D.status(item.info, rule, T0)
    H.equal(st.remaining, 2 * DAY, 'fresh item has its full lifetime left')
    H.equal(st.fraction, 1, 'fresh fraction is 1')
    H.equal(st.expired, false, 'fresh item is not expired')
    st = D.status(item.info, rule, T0 + DAY)
    H.equal(st.remaining, DAY, 'remaining after half the lifetime')
    H.equal(st.fraction, 0.5, 'fraction after half the lifetime')
    st = D.status(item.info, rule, T0 + 2 * DAY)
    H.equal(st.remaining, 0, 'remaining is zero at exactly the lifetime')
    H.equal(st.expired, true, 'expired at exactly the lifetime')
    st = D.status(item.info, rule, T0 + 5 * DAY)
    H.equal(st.remaining, 0, 'remaining never goes negative')
    H.equal(st.fraction, 0, 'fraction never goes negative')
    st = D.status(item.info, rule, T0 - 1000)
    H.equal(st.remaining, 2 * DAY, 'a clock set back does not make an item older than new')
    H.equal(st.fraction, 1, 'fraction never exceeds 1')

    -- Unstamped items are neither fresh nor expired: they are simply not evaluated.
    H.equal(D.status({}, rule, T0), nil, 'an unstamped item has no status (stamped on first sight, not spoiled)')
    H.equal(D.status({}, rule, T0 + 100 * DAY), nil, 'an unstamped item is never expired')
    H.equal(D.status({ createdAt = 'x' }, rule, T0), nil, 'a malformed stamp counts as unstamped')
    H.equal(D.status(nil, rule, T0), nil, 'nil info has no status')
    H.equal(D.status(item.info, nil, T0), nil, 'no rule, no status')

    -- Conversion decision.
    H.ok(D.status(item.info, rule, T0 + 3 * DAY).expired, 'expired sandwich is expired')
    H.equal(rule.action, 'convert', 'expired sandwich converts')
    H.equal(rule.into, 'garbage', 'into garbage')
    H.ok(not D.status(item.info, rule, T0 + DAY).expired, 'no decision before expiry')
    local water = D.rule('water_bottle', nil, cfg())
    H.ok(D.status({ createdAt = T0 }, water, T0 + 8 * DAY).expired, 'expired water bottle is expired')
    H.equal(water.action, 'remove', 'expired water bottle is removed')
    H.equal(water.into, nil, 'remove has no target')

    -- The stamped lifetime is a snapshot: later config edits do not revive/spoil it.
    local longer = { lifetime = 10 * DAY, action = 'remove' }
    H.equal(D.status(item.info, longer, T0).remaining, 2 * DAY, 'the stamped lifetime wins over a later rule change')
    -- ...but an item stamped by an older build without a snapshot uses the rule.
    H.equal(D.status({ createdAt = T0 }, longer, T0).remaining, 10 * DAY, 'no snapshot falls back to the rule lifetime')
    local filled = { name = 'sandwich', info = { createdAt = T0 } }
    D.stampItem(filled, rule, T0 + 10, false)
    H.equal(filled.info.decayLifetime, 2 * DAY, 'a missing snapshot is filled in without touching createdAt')
    H.equal(filled.info.createdAt, T0, 'createdAt untouched when only the snapshot is filled')
end

H.equal(D.fraction(50, 100), 0.5, 'fraction')
H.equal(D.fraction(-5, 100), 0, 'fraction clamps low')
H.equal(D.fraction(500, 100), 1, 'fraction clamps high')
H.equal(D.fraction(5, 0), 0, 'fraction with no lifetime is 0')
H.equal(D.fraction(0 / 0, 100), 0, 'fraction rejects NaN')

-- ------------------------------------------------------------------- merge --
do
    local rule = D.rule('sandwich', nil, cfg())
    local function stamped(at)
        local item = { name = 'sandwich', amount = 1, info = {}, metadata = {} }
        D.stampItem(item, rule, at, false)
        return item
    end
    local now = T0 + 100
    local old, young = stamped(T0), stamped(T0 + 50)
    H.ok(D.mergeItems(young, old, now, 'oldest'), 'merging an older stack into a younger one changes it')
    H.equal(young.info.createdAt, T0, 'the merged stack takes the OLDEST timestamp')
    H.equal(young.metadata.createdAt, T0, 'metadata mirror follows')
    local keep = stamped(T0)
    H.equal(D.mergeItems(keep, stamped(T0 + 50), now, 'oldest'), false, 'a younger member never freshens an older stack')
    H.equal(keep.info.createdAt, T0, 'older target keeps its stamp')
    local tie = stamped(T0)
    H.equal(D.mergeItems(tie, stamped(T0), now, 'oldest'), false, 'equal stamps change nothing')
    local separate = stamped(T0 + 50)
    H.equal(D.mergeItems(separate, old, now, 'separate'), false, "policy 'separate' never rewrites a stamp")
    H.equal(separate.info.createdAt, T0 + 50, "policy 'separate' leaves the stamp alone")

    -- An unstamped side adopts the stamped one (stamped on first sight, no retroactive spoiling).
    local bare = { name = 'sandwich', info = {}, metadata = {} }
    H.ok(D.mergeItems(bare, old, now, 'oldest'), 'an unstamped target adopts the stamped stack')
    H.equal(bare.info.createdAt, T0, 'adopted stamp')
    local target = stamped(T0)
    H.equal(D.mergeItems(target, { name = 'sandwich', info = {} }, now, 'oldest'), false, 'an unstamped incoming stack changes nothing')

    -- Oldest means least life left: compare remaining, not raw age.
    local shortLived = { name = 's', info = { createdAt = T0 + 10, decayLifetime = 100 }, metadata = {} }
    local longLived = { name = 's', info = { createdAt = T0, decayLifetime = 10 * DAY }, metadata = {} }
    D.mergeItems(longLived, shortLived, T0 + 20, 'oldest')
    H.equal(longLived.info.decayLifetime, 100, 'the member with the least life left wins the merge')

    -- Stack comparison: the stamps are ignored under 'oldest', kept under 'separate'.
    local a, b = { createdAt = T0, decayLifetime = 10, quality = 5 }, { createdAt = T0 + 99, decayLifetime = 10, quality = 5 }
    H.ok(inv.sameInfo(a, b), "the shipped default ('oldest') ignores stamps even while decay is off")
    Config.kora_inventory.decay = cfg()
    H.ok(inv.sameInfo(a, b), "'oldest': stacks differing only by stamps still match")
    H.equal(inv.sameInfo(a, { createdAt = T0, quality = 6 }), false, 'real metadata differences still split stacks')
    H.ok(inv.sameInfo({ createdAt = T0 }, {}), "'oldest': a stamped and an unstamped stack match")
    Config.kora_inventory.decay = cfg({ mergePolicy = 'separate' })
    H.equal(inv.sameInfo(a, b), false, "'separate': different stamps do not stack")
    H.ok(inv.sameInfo(a, inv.copy(a)), "'separate': identical stamps do stack")
    Config.kora_inventory.decay = defaults
end

-- ------------------------------------------------------------- pause/resume --
do
    local c = cfg()
    local rule = D.rule('sandwich', nil, c)
    H.ok(D.paused(c, 'trunk'), 'pauseIn.trunk is honoured')
    H.equal(D.paused(c, 'stash'), false, 'pauseIn.stash false')
    H.equal(D.paused(c, 'player'), false, 'player inventories never pause')
    H.equal(D.paused(c, 'shop'), false, 'unknown types never pause')
    H.equal(D.paused({}, 'trunk'), false, 'missing pauseIn never pauses')

    local item = { name = 'sandwich', amount = 1, info = {}, metadata = {} }
    D.stampItem(item, rule, T0, false)
    -- One hour in a player's pocket, then into the trunk, six hours, then back.
    H.ok(D.placeItem(item, true, T0 + 3600), 'moving into a paused inventory starts the pause')
    H.equal(item.info.decayPausedAt, T0 + 3600, 'pause start is recorded')
    H.equal(D.status(item.info, rule, T0 + 3600).remaining, 2 * DAY - 3600, 'one hour counted before the pause')
    H.equal(D.status(item.info, rule, T0 + 3600 + 6 * 3600).remaining, 2 * DAY - 3600, 'six paused hours do not count')
    H.equal(D.placeItem(item, true, T0 + 7200), false, 'moving within a paused inventory keeps the original pause start')
    H.equal(item.info.decayPausedAt, T0 + 3600, 'pause start is unchanged')
    H.ok(D.placeItem(item, false, T0 + 3600 + 6 * 3600), 'moving out resumes')
    H.equal(item.info.decayPausedAt, nil, 'pause marker cleared')
    H.equal(item.info.createdAt, T0 + 6 * 3600, 'createdAt shifted by the paused time')
    H.equal(item.metadata.decayPausedAt, nil, 'metadata mirror cleared')
    H.equal(D.status(item.info, rule, T0 + 3600 + 6 * 3600).remaining, 2 * DAY - 3600, 'remaining is exactly what it was when it went in')
    H.equal(D.status(item.info, rule, T0 + 3600 + 6 * 3600 + 3600).remaining, 2 * DAY - 7200, 'and ticks down again afterwards')
    H.equal(D.placeItem(item, false, T0 + 99999), false, 'resuming an item that is not paused does nothing')

    -- A paused item never expires, however long it stays.
    local frozen = { name = 'sandwich', info = { createdAt = T0, decayLifetime = 100, decayPausedAt = T0 + 50 }, metadata = {} }
    H.equal(D.status(frozen.info, rule, T0 + 1e9).expired, false, 'a paused item does not expire')
    H.ok(D.status(frozen.info, rule, T0 + 1e9).paused, 'and reports itself paused')
    -- First sight inside a paused inventory starts frozen.
    local fresh = { name = 'sandwich', info = {}, metadata = {} }
    D.stampItem(fresh, rule, T0, true)
    H.equal(fresh.info.decayPausedAt, T0, 'an item first seen in paused storage starts paused')
    H.equal(D.enterItem({ info = {} }, T0), false, 'an unstamped item cannot be paused')
    -- Merging two stacks inside paused storage keeps the older one frozen as-is.
    local x = { name = 's', info = { createdAt = T0, decayLifetime = 1000, decayPausedAt = T0 + 400 }, metadata = {} }
    local y = { name = 's', info = { createdAt = T0 + 100, decayLifetime = 1000, decayPausedAt = T0 + 300 }, metadata = {} }
    D.mergeItems(y, x, T0 + 500, 'oldest')
    H.equal(y.info.decayPausedAt, T0 + 400, 'merge in paused storage carries the older member pause marker')
    H.equal(y.info.createdAt, T0, 'and its stamp')
end

-- ---------------------------------------------------------------- misc math --
H.equal(D.format(4800), '1h 20m', 'format 1h 20m')
H.equal(D.format(2700), '45m', 'format minutes')
H.equal(D.format(30), '30s', 'format seconds')
H.equal(D.format(2 * DAY + 4 * 3600 + 59), '2d 4h', 'format keeps two units')
H.equal(D.format(0), '0s', 'format zero')
H.equal(D.format(-5), '0s', 'format negative')
H.equal(D.format(3600), '1h', 'format exact hour')
H.equal(D.sweepSeconds(cfg()), 300, 'sweep interval')
H.equal(D.sweepSeconds(cfg({ sweepSeconds = 0 })), 0, 'sweep off at 0')
H.equal(D.sweepSeconds(cfg({ sweepSeconds = 5 })), 30, 'sweep interval has a floor')
H.equal(D.sweepSeconds(cfg({ enabled = false })), 0, 'no sweep while disabled')
H.equal(D.mergePolicy({ mergePolicy = 'separate' }), 'separate', 'merge policy separate')
H.equal(D.mergePolicy({ mergePolicy = 'bogus' }), 'oldest', 'unknown merge policy falls back to oldest')
local view = D.viewField({ createdAt = T0, decayLifetime = 100 }, { lifetime = 100 }, T0 + 25)
H.equal(view.remaining, 75, 'view field remaining')
H.equal(view.fraction, 0.75, 'view field fraction')
H.equal(D.viewField({}, { lifetime = 100 }, T0), nil, 'no view field for an unstamped item')
local stripped = D.strip({ createdAt = 1, decayLifetime = 2, decayPausedAt = 3, quality = 4 })
H.equal(stripped.quality, 4, 'strip keeps metadata')
H.equal(stripped.createdAt, nil, 'strip drops the stamp')
local shop = { name = 'sandwich', info = { createdAt = 1, decayLifetime = 2, keep = true }, metadata = { createdAt = 1 } }
H.ok(D.unstampItem(shop), 'shop stock can be unstamped')
H.equal(shop.info.createdAt, nil, 'unstamped info')
H.equal(shop.metadata.createdAt, nil, 'unstamped metadata')
H.equal(shop.info.keep, true, 'other metadata kept')

-- ------------------------------------------------- Part 2: server integration --
local callbacks, events = {}, {}
Kora.resources = { serverRegistry = function() return { track = function() end, untrack = function() end } end }
Kora.callback = { register = function(name, fn) callbacks[name] = fn end }
Kora.sql = {}
Kora.logging = { warn = function() end, error = function(_, msg) error(msg) end, info = function() end, debug = function() end }
Kora.lang = function(key) return key end
GetCurrentResourceName = function() return 'kora_inventory' end
GetInvokingResource = function() return nil end
CreateThread = function() end
Wait = function() end
GetPlayers = function() return {} end
RegisterCommand = function() end
AddEventHandler = function() end
RegisterNetEvent = function() end
local receipts = {}
TriggerClientEvent = function(event, _, payload)
    if event == 'kora_inventory:client:itemBox' then receipts[#receipts + 1] = payload end
end
TriggerEvent = function(name, ...) events[#events + 1] = { name = name, args = { ... } } end
local clock = 12345
GetGameTimer = function() return clock end

local ITEMS = {
    sandwich = { name = 'sandwich', label = 'Sandwich', weight = 100, type = 'item', unique = false, useable = true },
    garbage = { name = 'garbage', label = 'Garbage', weight = 10, type = 'item', unique = false },
    water_bottle = { name = 'water_bottle', label = 'Water', weight = 500, type = 'item', unique = false },
    rock = { name = 'rock', label = 'Rock', weight = 100, type = 'item', unique = false },
    apple = { name = 'apple', label = 'Apple', weight = 50, type = 'item', unique = false, decay = { lifetime = 1000 } },
}
local registered = {}
local player = { name = 'Test', items = {} }
exports = setmetatable({}, {
    __call = function(_, name, fn) registered[name] = fn end,
    __index = function(_, resourceName)
        return setmetatable({}, {
            __index = function(_, exportName)
                return function(_, ...)
                    if resourceName == 'kora_core' then
                        if exportName == 'allShared' then return {} end
                        if exportName == 'getPlayerData' then
                            local _, path = ...
                            return path and player.items or player
                        end
                        if exportName == 'setPath' then
                            local _, path, value = ...
                            player.items[path[2]] = value
                            return true
                        end
                        if exportName == 'getShared' then
                            local registry, itemName = ...
                            return registry == 'items' and ITEMS[itemName] or nil
                        end
                    end
                    local fn = registered[exportName]
                    if fn then return fn(...) end
                    return nil
                end
            end,
        })
    end,
})

-- The real clock is only read through os.time(); freeze it for determinism.
local realTime = os.time
local now = T0
os.time = function(t) if t then return realTime(t) end return now end

Config.kora_inventory.decay = cfg()
Config.kora_inventory.decay.items.apple = nil

dofile('server/persistence.lua')
dofile('server.lua')
dofile('server/decay.lua')

local I = KoraInventory.internal
local ENABLED = Config.kora_inventory.decay
I.createSecondary('stash', 'cellar', { label = 'Cellar', slots = 10, maxWeight = 1000000 })
I.createSecondary('stash', 'fridge', { label = 'Fridge', slots = 10, maxWeight = 1000000 })
I.createSecondary('trunk', 'abc123', { label = 'Trunk', slots = 10, maxWeight = 1000000 })
local cellar, fridge, trunk = I.key('stash', 'cellar'), I.key('stash', 'fridge'), I.key('trunk', 'abc123')
local function items(key) return I.getInventory(key).items end

-- Stamp on add.
H.ok(I.addTo(cellar, 'sandwich', 2, 1, {}, 'seed'), 'add a sandwich')
H.equal(items(cellar)[1].info.createdAt, T0, 'a decaying item is stamped when it is added')
H.equal(items(cellar)[1].info.decayLifetime, 2 * DAY, 'with its lifetime snapshot')
H.ok(I.addTo(cellar, 'rock', 1, 2, {}, 'seed'), 'add a non-decaying item')
H.equal(items(cellar)[2].info.createdAt, nil, 'items without a rule are not stamped')

-- Stacking: a younger sandwich added later merges into the older stack and keeps its age.
now = T0 + 3600
H.ok(I.addTo(cellar, 'sandwich', 3, nil, {}, 'seed'), 'add more sandwiches an hour later')
H.equal(items(cellar)[1].amount, 5, 'newer sandwiches still stack onto the older stack')
H.equal(items(cellar)[1].info.createdAt, T0, 'the stack keeps the OLDEST timestamp')
H.equal(items(cellar)[3], nil, 'no second stack was created')

-- Definition-level rule.
Config.kora_inventory.decay.items.apple = nil
H.ok(I.addTo(cellar, 'apple', 1, 4, {}, 'seed'), 'add an item with a definition-level rule')
H.equal(items(cellar)[4].info.decayLifetime, 1000, 'definition-level rule stamps the item')

-- Disabled: nothing is stamped or spoiled.
Config.kora_inventory.decay = cfg({ enabled = false })
H.ok(I.addTo(cellar, 'water_bottle', 1, 5, {}, 'seed'), 'add while disabled')
H.equal(items(cellar)[5].info.createdAt, nil, 'nothing is stamped while decay is off')
now = T0 + 10 * DAY
H.ok(I.view(cellar), 'view while disabled')
H.equal(items(cellar)[1].name, 'sandwich', 'nothing spoils while decay is off')
H.equal(I.view(cellar).items[1].decay, nil, 'no decay view field while off')
Config.kora_inventory.decay = ENABLED
now = T0 + 3600

-- View fields.
local seen = I.view(cellar).items
H.equal(seen[1].decay.remaining, 2 * DAY - 3600, 'view carries remaining seconds')
H.ok(math.abs(seen[1].decay.fraction - (2 * DAY - 3600) / (2 * DAY)) < 1e-9, 'view carries the fraction')
H.equal(seen[2].decay, nil, 'non-decaying items have no decay field')
local row
for _, entry in ipairs(seen[1].displayMeta) do
    if entry.key == 'decayRemaining' then row = entry end
    H.ok(entry.key ~= 'createdAt' and entry.key ~= 'decayLifetime' and entry.key ~= 'decayPausedAt', 'stamps never appear as metadata rows')
end
H.ok(row and row.value == '1d 23h', 'the inspector row shows the remaining time')
H.equal(items(cellar)[1].decay, nil, 'the view field is never stored on the real item')
Config.kora_inventory.decay.showInInspector = false
H.equal(#I.view(cellar).items[1].displayMeta, 0, 'showInInspector = false removes the row')
H.ok(I.view(cellar).items[1].decay, 'but the slot field is still sent')
Config.kora_inventory.decay.showOnSlot = false
H.equal(I.view(cellar).items[1].decay, nil, 'both presentation flags off: no field at all')
Config.kora_inventory.decay.showInInspector, Config.kora_inventory.decay.showOnSlot = true, true

-- Pause: a trunk freezes time; leaving it resumes with the time shifted.
local opened, session = I.open(1, cellar)
H.ok(opened, 'open the cellar')
local function move(from, to, fromSlot, toSlot, amount)
    return callbacks['kora_inventory:server:transfer'](1, {
        token = session.token, fromInventory = from, toInventory = to,
        fromSlot = fromSlot, toSlot = toSlot, amount = amount,
    })
end
-- The session only covers the player and the cellar; use a second stash session
-- for the pause test by moving within it and re-opening.
Config.kora_inventory.decay = cfg({ pauseIn = { stash = true } })
I.createSecondary('stash', 'cold', { label = 'Cold store', slots = 10, maxWeight = 1000000 })
local cold = I.key('stash', 'cold')
now = T0 + 7200
H.ok(I.addTo(cold, 'sandwich', 1, 1, {}, 'seed'), 'add a sandwich to paused storage')
H.equal(items(cold)[1].info.decayPausedAt, T0 + 7200, 'it enters paused')
now = T0 + 7200 + 9 * 3600
H.equal(I.view(cold).items[1].decay.remaining, 2 * DAY, 'nine hours in the cold store cost nothing')
H.equal(items(cold)[1].amount, 1, 'and it did not spoil')
-- Move it out to the unpaused cellar (stash pause is on for BOTH stashes in this
-- config, so flip it off to model "out of the fridge").
Config.kora_inventory.decay = cfg()
now = T0 + 7200 + 9 * 3600
local removedOK, _, taken = I.removeFrom(cold, 1, 1)
H.ok(removedOK, 'take it out of the cold store')
H.ok(I.addTo(cellar, 'sandwich', 1, 6, taken.info, 'transfer', true), 'put it in a normal stash')
H.equal(items(cellar)[6].info.decayPausedAt, nil, 'the pause marker is cleared on the way out')
H.equal(I.view(cellar).items[6].decay.remaining, 2 * DAY, 'it still has all its life')
now = now + 3600
H.equal(I.view(cellar).items[6].decay.remaining, 2 * DAY - 3600, 'and ticks down again')

-- Lazy expiry on view: converts keep slot and amount.
now = T0 + 2 * DAY + 1
local v = I.view(cellar)
H.equal(items(cellar)[1].name, 'garbage', 'an expired sandwich stack converts to garbage in place')
H.equal(items(cellar)[1].amount, 5, 'conversion keeps the amount')
H.equal(v.items[1].name, 'garbage', 'the returned view already shows the converted item')
H.equal(items(cellar)[1].info.createdAt, nil, 'the converted item is new: it carries no stamp from the sandwich (garbage has no rule)')
H.equal(items(cellar)[2].name, 'rock', 'non-decaying items are untouched')
local auditLog
for _, e in ipairs(events) do
    if e.name == 'kora_inventory:server:itemDecayed' then auditLog = e.args[2] end
end
H.equal(auditLog and auditLog.action, 'convert', 'a decay event is emitted with the action')
H.equal(auditLog and auditLog.into, 'garbage', 'and the target item')

-- Removal (no into) through the same funnel.
now = T0 + 20 * DAY
I.view(cellar)
H.equal(items(cellar)[5], nil, 'an expired water bottle is removed')

-- Moves and use of a spoiled item are refused and processed.
Config.kora_inventory.decay = cfg()
now = T0 + 30 * DAY
I.addTo(cellar, 'sandwich', 1, 7, {}, 'seed', true)
H.equal(items(cellar)[7].info.createdAt, now, 'fresh stamp')
now = now + 3 * DAY
H.ok(I.getInventory(cellar), 'sanity')
local guarded = KoraInventory.decayRuntime.guard(cellar, 7, 1)
H.ok(guarded, 'guard reports a spoiled item')
H.equal(items(cellar)[7].name, 'garbage', 'and converts it')
H.equal(KoraInventory.decayRuntime.guard(cellar, 7, 1), false, 'a converted item is no longer spoiled')
H.equal(KoraInventory.decayRuntime.guard(cellar, 2, 1), false, 'a non-decaying item is never guarded')
H.equal(KoraInventory.decayRuntime.guard(cellar, 99, 1), false, 'an empty slot is not guarded')

-- Unstamped items already in an inventory are stamped on first sight, not spoiled.
now = T0 + 100 * DAY
I.getInventory(cellar).items[8] = { slot = 8, name = 'sandwich', amount = 1, info = {}, metadata = {}, type = 'item' }
I.view(cellar)
H.equal(items(cellar)[8].name, 'sandwich', 'a legacy unstamped item does not spoil retroactively')
H.equal(items(cellar)[8].info.createdAt, now, 'it is stamped on first sight')
H.equal(items(cellar)[8].info.decayLifetime, 2 * DAY, 'with its lifetime')

-- Shop stock never ages and purchases start fresh.
I.createSecondary('shop', 'deli', { label = 'Deli', slots = 5, maxWeight = 1000000 })
Config.kora_inventory.decay = ENABLED
now = T0 + 200 * DAY
local deli = I.key('shop', 'deli')
I.getInventory(deli).items[1] = { slot = 1, name = 'sandwich', amount = 5, info = { createdAt = T0 }, metadata = { createdAt = T0 }, type = 'item', price = 3 }
I.view(deli)
H.equal(I.getInventory(deli).items[1].name, 'sandwich', 'shop stock is never spoiled by a view')
H.equal(I.view(deli).items[1].decay, nil, 'and carries no decay view field')

-- ---------------------------------------------- player inventory (kora_core) --
Config.kora_inventory.decay = ENABLED
now = T0 + 300 * DAY
local me = I.key('player', 1)
H.ok(I.addTo(me, 'sandwich', 4, 1, {}, 'seed'), 'add a sandwich stack to a player')
H.equal(player.items[1].info.createdAt, now, 'player items are stamped through the kora_core write path')
local revision = I.getRevision(me)
H.ok(I.addTo(me, 'sandwich', 2, nil, {}, 'seed'), 'add more later')
now = now + 100
H.equal(player.items[1].amount, 6, 'a younger sandwich stacks onto the player stack')
H.equal(player.items[1].info.createdAt, T0 + 300 * DAY, 'and the stack keeps the oldest stamp')
-- A legacy item that arrived without a stamp is stamped silently (no revision bump).
player.items[3] = { slot = 3, name = 'water_bottle', amount = 1, info = {}, metadata = {}, type = 'item' }
local before = I.getRevision(me)
I.view(me)
H.equal(player.items[3].info.createdAt, now, 'legacy player item stamped on first sight')
H.equal(I.getRevision(me), before, 'stamping does not bump the revision')
-- Spoil: converts in place, bumps once, tells the owner with the normal receipts.
now = T0 + 300 * DAY + 2 * DAY + 1
local receiptsBefore = #receipts
local seenView = I.view(me)
H.equal(player.items[1].name, 'garbage', 'an expired player stack converts to garbage')
H.equal(player.items[1].amount, 6, 'keeping slot and amount')
H.equal(seenView.items[1].name, 'garbage', 'the view already shows the converted item')
H.ok(I.getRevision(me) > before, 'the spoil bumps the revision')
H.equal(#receipts - receiptsBefore, 2, 'the owner gets a removal and an addition receipt')
H.equal(receipts[#receipts].action, 'add', 'the replacement is announced as an addition')
H.equal(player.items[3].name, 'water_bottle', 'the water bottle (7 days) has not spoiled yet')

-- Busy slots are never pulled out from under a running use handler.
player.items[4] = { slot = 4, name = 'sandwich', amount = 1, info = { createdAt = T0, decayLifetime = 10 }, metadata = {}, type = 'item' }
H.equal(KoraInventory.decayRuntime.guard(me, 4, 1), true, 'guard flags an expired item even when nothing else changed')

-- The sweep visits online players only.
local online = { '1' }
GetPlayers = function() return online end
player.items[5] = { slot = 5, name = 'water_bottle', amount = 1, info = { createdAt = T0, decayLifetime = 10 }, metadata = {}, type = 'item' }
H.equal(KoraInventory.decayRuntime.sweep(), 1, 'the sweep visits each online player')
H.equal(player.items[5], nil, 'and spoils what expired while nobody looked (removed, no into)')
online = {}
player.items[6] = { slot = 6, name = 'water_bottle', amount = 1, info = { createdAt = T0, decayLifetime = 10 }, metadata = {}, type = 'item' }
H.equal(KoraInventory.decayRuntime.sweep(), 0, 'a sweep with nobody online visits no inventory')
H.ok(player.items[6], 'offline inventories are not touched by the sweep')
Config.kora_inventory.decay = cfg({ enabled = false })
online = { '1' }
H.equal(KoraInventory.decayRuntime.sweep(), 0, 'a disabled config sweeps nothing')
H.ok(player.items[6], 'and spoils nothing')

-- The browser gets its presentation flags through the NUI config push, and the
-- strings through the locale push.
local ui = assert(io.open('client/ui.lua', 'r')):read('*a')
H.ok(ui:find('decay = decayPresentation(),', 1, true), 'decay presentation flags are pushed on every config push')
H.ok(ui:find("'decay_expires_in', 'decay_spoiled'", 1, true), 'decay strings are in the UI locale push')
local locale = assert(io.open('locales/en.lua', 'r')):read('*a')
H.ok(locale:find("decay_expires_in = 'Expires in %{time}'", 1, true), 'English UI string exists')
H.ok(locale:find("decay_expires = 'Expires in'", 1, true), 'English inspector label exists')

H.finish()
