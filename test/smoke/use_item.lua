-- Coverage for the native `preventClose`/`useTime` item fields and the
-- server-authoritative half of the use-item flow: buildItem() must derive
-- both canonically, a legacy `shouldClose = false` item must translate to an
-- implicit preventClose, intentUse() must report preventClose back to the
-- client so it knows whether to close the panel, and a whole-inventory
-- replacement must not let a caller forge either field onto a stored item.
local H = dofile('test/harness.lua')

NOTIFIED = {}
Config = { kora_inventory = {} }
dofile('config.lua')
dofile('config/shops/ammunation.lua')
dofile('shared.lua')

local KoraCallbacks = {}
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
    callback = { register = function(name, fn) KoraCallbacks[name] = fn end },
    sql = {},
    notify = { send = function(_, payload) NOTIFIED[#NOTIFIED + 1] = payload end },
    lang = function(key) return key end,
}
GetCurrentResourceName = function() return 'kora_inventory' end
GetInvokingResource = function() return nil end
CreateThread = function() end
RegisterCommand = function() end
AddEventHandler = function() end
RegisterNetEvent = function() end
TriggerClientEvent = function() end
TriggerEvent = function() end
NOW = 12345
GetGameTimer = function() return NOW end

local ITEMS = {
    bandage = { name = 'bandage', label = 'Bandage', weight = 100, useable = true },
    map = { name = 'map', label = 'Map', weight = 10, useable = true, preventClose = true },
    -- Legacy item definition: no native preventClose, but the qb-core
    -- `shouldClose = false` convention meant "leave the inventory open".
    oldflare = { name = 'oldflare', label = 'Old Flare', weight = 50, useable = true, shouldClose = false },
    potion = { name = 'potion', label = 'Potion', weight = 20, useable = true, useTime = 2500.9 },
}
local WEAPONS = {
    weapon_pistol = { name = 'weapon_pistol', label = 'Pistol', type = 'weapon', useable = false, weight = 1000 },
}

local playersData = { [7] = { citizenid = 'CID-7' } }
-- Populated below, once buildItem is available, exactly the way every real
-- player item is created (addPlayer/addTo/setItems all route through it) --
-- a hand-authored raw item table would skip the preventClose/useTime
-- derivation entirely and defeat the point of this test.
local playersItems = { [7] = {} }
playersMetadata = { [7] = {} }

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
                            if registry == 'weapons' then return WEAPONS[itemName] end
                            return registry == 'items' and ITEMS[itemName] or nil
                        end
                        if exportName == 'getPlayerData' then
                            local src, fields = ...
                            if fields and fields[1] == 'items' then return playersItems[src] end
                            if fields and fields[1] == 'metadata' then return playersMetadata[src] end
                            return playersData[src]
                        end
                        if exportName == 'setPath' then
                            local src, path, value = ...
                            if path[1] ~= 'items' then return false, 'unsupported path' end
                            playersItems[src] = playersItems[src] or {}
                            if path[2] then playersItems[src][path[2]] = value
                            else playersItems[src] = value end
                            return true
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

-- buildItem derivation

local buildItem = KoraInventory.internal.buildItem

local bandage = buildItem('bandage', 1, 1, {})
H.equal(bandage.preventClose, false, 'default item closes the inventory after use')
H.equal(bandage.useTime, 0, 'default item has no use time')

local map = buildItem('map', 1, 2, {})
H.equal(map.preventClose, true, 'a native preventClose = true item is honoured')

local oldflare = buildItem('oldflare', 1, 3, {})
H.equal(oldflare.preventClose, true, 'legacy shouldClose = false implies preventClose = true')
H.equal(oldflare.shouldClose, false, 'shouldClose itself is left untouched for qb-core compat parity')

local potion = buildItem('potion', 1, 4, {})
H.equal(potion.useTime, 2500, 'useTime is floored to a whole millisecond count')

playersItems[7] = {
    [1] = buildItem('bandage', 3, 1, {}),
    [2] = buildItem('map', 1, 2, {}),
    [3] = buildItem('oldflare', 1, 3, {}),
    [4] = buildItem('potion', 1, 4, {}),
    -- Simulate a legacy record that did not persist the current useable flag.
    [5] = { name = 'weapon_pistol', amount = 1, slot = 5, useable = false, info = {} },
}

-- intentUse response signals whether the client should close the panel

local ok, payload = KoraInventory.internal.openSelf(7)
H.ok(ok, 'own inventory opens')
H.ok(payload.primary.items[5].useable, 'the current weapon definition restores the Use action in the inventory view')

KoraInventory.api.createUseable('bandage', function(src)
    -- Useables are expected to mutate inventories through the public API.
    -- This must not be rejected by a use-intent lock.
    return KoraInventory.api.addItem(src, 'potion', 1)
end)
KoraInventory.api.createUseable('map', function() return true end)
KoraInventory.api.createUseable('oldflare', function() return true end)
KoraInventory.api.createUseable('potion', function() return true end)

local intent = KoraCallbacks['kora_inventory:server:intent']
H.ok(type(intent) == 'function', 'the restricted UI intent callback is registered')

local useOK, useResult = intent(7, {
    token = payload.token, action = 'use',
    payload = { slot = 1 }, primaryRevision = payload.primary.revision,
})
H.ok(useOK, 'using a default item succeeds')
H.equal(useResult.preventClose, false, 'a default item tells the client to close the panel')
H.equal(playersItems[7][4].name, 'potion', 'a useable can mutate the player inventory through AddItem')

local reopened, refreshed = KoraInventory.internal.openSelf(7)
H.ok(reopened, 'a fresh session opens after the useable mutation')
payload = refreshed
local revision = payload.primary.revision
local mapOK, mapResult = intent(7, {
    token = payload.token, action = 'use',
    payload = { slot = 2 }, primaryRevision = revision,
})
H.ok(mapOK, 'using a preventClose item succeeds')
H.equal(mapResult.preventClose, true, 'a preventClose item tells the client to keep the panel open')

local flareOK, flareResult = intent(7, {
    token = payload.token, action = 'use',
    payload = { slot = 3 }, primaryRevision = revision,
})
H.ok(flareOK, 'using a legacy shouldClose = false item succeeds')
H.equal(flareResult.preventClose, true, 'legacy shouldClose = false keeps the panel open through intentUse too')

-- setItems cannot forge preventClose/useTime onto a stored item

local setOK = KoraInventory.api.setItems(7, {
    [4] = { name = 'potion', amount = 1, slot = 4, preventClose = true, useTime = 999999 },
})
H.ok(setOK, 'setItems accepts a validated replacement')
H.equal(playersItems[7][4].preventClose, false, 'a caller cannot forge preventClose through setItems')
H.equal(playersItems[7][4].useTime, 2500, 'a caller cannot forge useTime through setItems -- the real item useTime wins')

-- downed / dead players cannot open or use items (server-enforced)

local function useSlot2() return KoraInventory.api.useItem(7, 4) end

playersMetadata[7] = { inlaststand = true }
local downedUse, downedErr = useSlot2()
H.equal(downedUse, false, 'a player in last stand cannot use items')
H.ok(downedErr:find('downed', 1, true), 'the refusal says why')
H.equal(#NOTIFIED, 1, 'the blocked attempt notifies once')
useSlot2()
H.equal(#NOTIFIED, 1, 'repeated attempts inside the cooldown do not spam')
NOW = NOW + 5000
useSlot2()
H.equal(#NOTIFIED, 2, 'the notify fires again after the cooldown')
H.equal(KoraInventory.internal.openSelf ~= nil and select(1, KoraCallbacks['kora_inventory:server:open'](7, 'player', 7)), false,
    'a downed player cannot open an inventory')
local downedIntent = intent(7, {
    token = payload.token, action = 'use',
    payload = { slot = 2 }, primaryRevision = revision,
})
H.equal(downedIntent, false, 'the NUI use intent is refused while downed')

playersMetadata[7] = { isdead = true }
H.equal((useSlot2()), false, 'a dead player cannot use items')

Config.kora_inventory.downedAllowedItems = { "POTION" }
H.ok((useSlot2()), 'an allow-listed item stays usable while downed')
Config.kora_inventory.downedAllowedItems = {}

Config.kora_inventory.blockWhenDowned = false
H.ok((useSlot2()), 'blockWhenDowned = false restores the old behaviour')
Config.kora_inventory.blockWhenDowned = true

playersMetadata[7] = { isdead = false, inlaststand = false }
H.ok((useSlot2()), 'a standing player can use items again')

-- cuffed players cannot open or use items either (server-enforced; kora_police
-- sets the ishandcuffed metadata)

NOTIFIED = {}
NOW = NOW + 5000
playersMetadata[7] = { ishandcuffed = true }
local cuffedUse, cuffedErr = useSlot2()
H.equal(cuffedUse, false, 'a cuffed player cannot use items')
H.ok(cuffedErr:find('cuffed', 1, true), 'the refusal says why')
H.equal(#NOTIFIED, 1, 'the blocked attempt notifies once')
useSlot2()
H.equal(#NOTIFIED, 1, 'repeated attempts inside the cooldown do not spam')
H.equal(select(1, KoraCallbacks['kora_inventory:server:open'](7, 'player', 7)), false, 'a cuffed player cannot open an inventory')
local cuffedIntent = intent(7, {
    token = payload.token, action = 'use',
    payload = { slot = 2 }, primaryRevision = payload.primary.revision,
})
H.equal(cuffedIntent, false, 'a request on a session opened before the cuff is refused and closes it')

Config.kora_inventory.blockWhenCuffed = false
H.ok((useSlot2()), 'blockWhenCuffed = false restores the old behaviour')
Config.kora_inventory.blockWhenCuffed = true

playersMetadata[7] = {}
H.ok((useSlot2()), 'an uncuffed player can use items again')
H.ok(KoraInventory.internal.openSelf(7), 'and open their inventory again')

H.finish()
