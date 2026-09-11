-- Coverage for the native `preventClose`/`useTime` item fields and the
-- server-authoritative half of the use-item flow: buildItem() must derive
-- both canonically, a legacy `shouldClose = false` item must translate to an
-- implicit preventClose, intentUse() must report preventClose back to the
-- client so it knows whether to close the panel, and a whole-inventory
-- replacement must not let a caller forge either field onto a stored item.
local H = dofile('test/harness.lua')

Config = { qbinventory = {} }
dofile('config.lua')
dofile('config/shops/ammunation.lua')
dofile('shared.lua')

local QBCallbacks = {}
QB = {
    resources = { serverRegistry = function() return { track = function() end, untrack = function() end } end },
    callback = { register = function(name, fn) QBCallbacks[name] = fn end },
    sql = {},
}
GetCurrentResourceName = function() return 'qbinventory' end
GetInvokingResource = function() return nil end
CreateThread = function() end
RegisterCommand = function() end
AddEventHandler = function() end
RegisterNetEvent = function() end
TriggerClientEvent = function() end
TriggerEvent = function() end
GetGameTimer = function() return 12345 end

local ITEMS = {
    bandage = { name = 'bandage', label = 'Bandage', weight = 100, useable = true },
    map = { name = 'map', label = 'Map', weight = 10, useable = true, preventClose = true },
    -- Legacy item definition: no native preventClose, but the qb-core
    -- `shouldClose = false` convention meant "leave the inventory open".
    oldflare = { name = 'oldflare', label = 'Old Flare', weight = 50, useable = true, shouldClose = false },
    potion = { name = 'potion', label = 'Potion', weight = 20, useable = true, useTime = 2500.9 },
}

local playersData = { [7] = { citizenid = 'CID-7' } }
-- Populated below, once buildItem is available, exactly the way every real
-- player item is created (addPlayer/addTo/setItems all route through it) --
-- a hand-authored raw item table would skip the preventClose/useTime
-- derivation entirely and defeat the point of this test.
local playersItems = { [7] = {} }

local registered = {}
exports = setmetatable({}, {
    __call = function(_, name, fn) registered[name] = fn end,
    __index = function(_, resourceName)
        return setmetatable({}, {
            __index = function(_, exportName)
                return function(_, ...)
                    if resourceName == 'qbcore' then
                        if exportName == 'allShared' then return {} end
                        if exportName == 'getShared' then
                            local registry, itemName = ...
                            return registry == 'items' and ITEMS[itemName] or nil
                        end
                        if exportName == 'getPlayerData' then
                            local src, fields = ...
                            if fields and fields[1] == 'items' then return playersItems[src] end
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

-- buildItem derivation ------------------------------------------------------

local buildItem = QbInventory.internal.buildItem

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
}

-- intentUse response signals whether the client should close the panel -----

local ok, payload = QbInventory.internal.openSelf(7)
H.ok(ok, 'own inventory opens')

QbInventory.api.createUseable('bandage', function() return true end)
QbInventory.api.createUseable('map', function() return true end)
QbInventory.api.createUseable('oldflare', function() return true end)
QbInventory.api.createUseable('potion', function() return true end)

local intent = QBCallbacks['qbinventory:server:intent']
H.ok(type(intent) == 'function', 'the restricted UI intent callback is registered')

local useOK, useResult = intent(7, {
    token = payload.token, action = 'use',
    payload = { slot = 1 }, primaryRevision = payload.primary.revision,
})
H.ok(useOK, 'using a default item succeeds')
H.equal(useResult.preventClose, false, 'a default item tells the client to close the panel')

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

-- setItems cannot forge preventClose/useTime onto a stored item ------------

local setOK = QbInventory.api.setItems(7, {
    [4] = { name = 'potion', amount = 1, slot = 4, preventClose = true, useTime = 999999 },
})
H.ok(setOK, 'setItems accepts a validated replacement')
H.equal(playersItems[7][4].preventClose, false, 'a caller cannot forge preventClose through setItems')
H.equal(playersItems[7][4].useTime, 2500, 'a caller cannot forge useTime through setItems -- the real item useTime wins')

H.finish()
