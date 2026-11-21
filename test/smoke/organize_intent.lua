-- The `organize` intent end to end: the real server.lua intent callback against
-- a stash. Covers the validation it shares with moves (session, revisions,
-- access) plus its own gates (enabled, mode, shop, cooldown) and the commit.
local H = dofile('test/harness.lua')

Config = { kora_inventory = {} }
dofile('config.lua')
dofile('config/shops/ammunation.lua')
dofile('shared.lua')
dofile('shared/organize.lua')

local callbacks = {}
Kora = {
    util = { deepClone = function(value)
        local seen = {}
        local function clone(v)
            if type(v) ~= "table" then return v end
            if seen[v] then return seen[v] end
            local copy = {}
            seen[v] = copy
            for k, vv in pairs(v) do copy[clone(k)] = clone(vv) end
            return copy
        end
        return clone(value)
    end },
    resources = { serverRegistry = function() return { track = function() end, untrack = function() end } end },
    callback = { register = function(name, fn) callbacks[name] = fn end },
    sql = {},
    logging = setmetatable({}, { __index = function() return function(_, _, details) if details and details.error then io.stderr:write(tostring(details.error), '\n') end end end }),
}
GetCurrentResourceName = function() return 'kora_inventory' end
GetInvokingResource = function() return nil end
CreateThread = function() end
RegisterCommand = function() end
AddEventHandler = function() end
RegisterNetEvent = function() end
TriggerClientEvent = function() end
TriggerEvent = function() end
local clock = 1000
GetGameTimer = function() return clock end

local ITEMS = {
    water_bottle = { name = 'water_bottle', label = 'Water', weight = 500, type = 'item', unique = false },
    bread = { name = 'bread', label = 'Bread', weight = 100, type = 'item', unique = false },
    bandage = { name = 'bandage', label = 'Bandage', weight = 50, type = 'item', unique = false, useable = true },
    weapon_bat = { name = 'weapon_bat', label = 'Bat', weight = 800, type = 'weapon', unique = true },
}

local registered = {}
exports = setmetatable({}, {
    __call = function(_, name, fn) registered[name] = fn end,
    __index = function(_, resourceName)
        return setmetatable({}, {
            __index = function(_, exportName)
                return function(_, ...)
                    if resourceName == 'kora_core' then
                        if exportName == 'allShared' then return {} end
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


dofile('server/persistence.lua')
dofile('server.lua')

local internal = KoraInventory.internal
local config = Config.kora_inventory
internal.createSecondary('stash', 'org-test', { label = 'Stash', slots = 12, maxWeight = 1000000 })
internal.createSecondary('shop', 'org-shop', { label = 'Shop', slots = 6, maxWeight = 1000000 })
local stashKey = internal.key('stash', 'org-test')
local src = 1
local intent = callbacks['kora_inventory:server:intent']
local opened, session = internal.open(src, stashKey)
H.ok(opened, 'sanity: a session on the stash opened')

local function inv() return internal.getInventory(stashKey) end
local function revision() return internal.getInventory(stashKey).revision or 0 end
local function totals()
    local out = {}
    for _, item in pairs(inv().items) do out[item.name] = (out[item.name] or 0) + item.amount end
    return out
end
local function count()
    local n = 0
    for _ in pairs(inv().items) do n = n + 1 end
    return n
end
local function organize(mode, overrides)
    clock = clock + 5000 -- clear the cooldown unless a test wants it
    local request = {
        token = session.token, action = 'organize',
        payload = { inventory = stashKey, mode = mode },
        primaryRevision = nil, secondaryRevision = revision(),
    }
    for key, value in pairs(overrides or {}) do request[key] = value end
    return intent(src, request)
end

local function seed()
    for slot = 1, 12 do inv().items[slot] = nil end
    internal.addTo(stashKey, 'water_bottle', 3, 4, { quality = 80 }, 'seed', true)
    internal.addTo(stashKey, 'water_bottle', 2, 9, { quality = 80 }, 'seed', true)
    internal.addTo(stashKey, 'water_bottle', 7, 6, { quality = 20 }, 'seed', true)
    internal.addTo(stashKey, 'bread', 1, 11, {}, 'seed', true)
    internal.addTo(stashKey, 'bandage', 2, 2, {}, 'seed', true)
    internal.addTo(stashKey, 'weapon_bat', 1, 12, {}, 'seed', true)
end
seed()
local before = totals()
local weightBefore = KoraInventory.totalWeight(inv().items)

-- Stack: merges same-metadata stacks, never different metadata, keeps totals.
local ok, result = organize('stack')
H.ok(ok, 'stack succeeds: ' .. tostring(result))
local after = totals()
for name, amount in pairs(before) do H.equal(after[name], amount, 'stack keeps total of ' .. name) end
H.equal(inv().items[4].amount, 5, 'matching water merged into the lowest slot')
H.equal(inv().items[6].amount, 7, 'water with different metadata stays apart')
H.equal(inv().items[9], nil, 'merged slot cleared')
H.equal(KoraInventory.totalWeight(inv().items), weightBefore, 'weight never changes')
H.ok(result.changed, 'reply says something changed')

-- Sort: category, then label.
ok, result = organize('sort')
H.ok(ok, 'sort succeeds: ' .. tostring(result))
H.equal(inv().items[1].name, 'weapon_bat', 'weapons first')
H.equal(inv().items[2].name, 'bandage', 'then useables')
H.equal(inv().items[3].name, 'bread', 'then the rest by label')
H.equal(inv().items[4].name, 'water_bottle', 'then water')
H.equal(count(), 5, 'sort kept every stack')
for name, amount in pairs(before) do H.equal(totals()[name], amount, 'sort keeps total of ' .. name) end
for slot, item in pairs(inv().items) do H.equal(item.slot, slot, 'slot field matches slot ' .. slot) end

-- Revision bumps, and a second sort is a no-op that keeps the revision.
local rev = revision()
ok, result = organize('sort')
H.ok(ok, 'sorting a sorted stash succeeds')
H.equal(result.changed, false, 'and reports no change')
H.equal(revision(), rev, 'without bumping the revision')

-- Validation shared with moves.
local stale
ok, stale = organize('sort', { secondaryRevision = revision() - 1 })
H.equal(ok, false, 'a stale revision is refused')
ok = organize('sort', { payload = { inventory = stashKey, mode = 'sort', secondaryRevision = revision() + 5 } })
H.equal(ok, false, 'a stale payload revision is refused')
ok = organize('sort', { token = 'wrong' })
H.equal(ok, false, 'a wrong token is refused')
ok = organize('sort', { payload = { inventory = 'stash:not-mine', mode = 'sort' } })
H.equal(ok, false, 'an inventory outside the session is refused')
ok = organize('shuffle')
H.equal(ok, false, 'an unknown mode is refused')
ok = organize('sort', { payload = 'sort' })
H.equal(ok, false, 'a malformed payload is refused')
ok = intent(99, { token = session.token, action = 'organize', payload = { inventory = stashKey, mode = 'sort' } })
H.equal(ok, false, 'another player cannot use this session')

-- Config gates are read at call time.
seed()
config.organize.stack = false
ok = organize('stack')
H.equal(ok, false, 'stack refused while organize.stack is off')
config.organize.stack = true
config.organize.enabled = false
ok = organize('sort')
H.equal(ok, false, 'everything refused while organize.enabled is off')
config.organize.enabled = true
H.equal(count(), 6, 'a refused organize changes nothing')

-- Cooldown.
config.organize.cooldownMs = 1000
clock = clock + 5000
ok = intent(src, { token = session.token, action = 'organize', payload = { inventory = stashKey, mode = 'stack' }, secondaryRevision = revision() })
H.ok(ok, 'first organize passes')
clock = clock + 400
ok, result = intent(src, { token = session.token, action = 'organize', payload = { inventory = stashKey, mode = 'sort' }, secondaryRevision = revision() })
H.equal(ok, false, 'a second organize inside the cooldown is refused')
clock = clock + 700
ok = intent(src, { token = session.token, action = 'organize', payload = { inventory = stashKey, mode = 'sort' }, secondaryRevision = revision() })
H.ok(ok, 'and passes once the cooldown has elapsed')

-- Shops cannot be organized.
local shopKey = internal.key('shop', 'org-shop')
local shopOpened, shopSession = internal.open(src, shopKey)
H.ok(shopOpened, 'sanity: a shop session opened')
if shopOpened then
    clock = clock + 5000
    ok, result = intent(src, { token = shopSession.token, action = 'organize', payload = { inventory = shopKey, mode = 'sort' } })
    H.equal(ok, false, 'a shop is refused')
    H.equal(result, 'shop inventories cannot be organized', 'for the right reason')
end

H.finish()
