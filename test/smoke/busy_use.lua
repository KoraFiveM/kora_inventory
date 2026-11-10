-- Server guard: a slot whose useable handler is still running cannot be
-- dropped, given or moved (the use-then-drop item-retention exploit).
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

local buildItem = KoraInventory.internal.buildItem
playersItems[7] = {
    [1] = buildItem("bandage", 2, 1, {}),
    [2] = buildItem("map", 1, 2, {}),
}
local function reset()
    playersItems[7] = { [1] = buildItem("bandage", 2, 1, {}), [2] = buildItem("map", 1, 2, {}) }
end
local opened, payload = KoraInventory.internal.openSelf(7)
H.ok(opened, "inventory opens")
local intent = KoraCallbacks["kora_inventory:server:intent"]
local function req(action, p)
    return { token = payload.token, action = action, payload = p, primaryRevision = payload.primary.revision }
end

local results
KoraInventory.api.createUseable("bandage", function(src)
    results = {
        drop = { intent(src, req("drop", { slot = 1, amount = 1 })) },
        give = { intent(src, req("give", { slot = 1, amount = 1, target = 8 })) },
        reuse = { KoraInventory.api.useItem(src, 1) },
    }
    -- The handler itself consumes the item through the API: never blocked.
    results.remove = KoraInventory.api.removeItem(src, "bandage", 1, 1)
    return true
end)
KoraInventory.api.createUseable("map", function() return true end)

local ok = KoraInventory.api.useItem(7, 1)
H.ok(ok, "the use completes")
H.equal(results.drop[1], false, "dropping the slot mid-use is refused")
H.equal(results.drop[2], "item is currently being used", "the drop refusal says why")
H.equal(results.give[1], false, "giving the slot mid-use is refused")
H.equal(results.reuse[1], false, "a second use of the busy slot is refused")
H.ok(results.remove, "the handler can still consume its own item via removeItem")
H.ok(#NOTIFIED >= 1, "the player is notified")

-- Cleared once the handler returned: the (remaining) slot is free again.
local tr = KoraCallbacks["kora_inventory:server:transfer"]
local function move(from, to)
    local _, fresh = KoraInventory.internal.openSelf(7)
    payload = fresh
    return tr(7, { token = payload.token, fromInventory = payload.primary.key or payload.primary.id, toInventory = payload.primary.key or payload.primary.id,
        fromSlot = from, toSlot = to, amount = 1, fromRevision = payload.primary.revision, toRevision = payload.primary.revision })
end
reset()
local _, why = move(1, 5)
H.ok(why ~= "item is currently being used", "slot is not busy after the use finished")

-- A handler that errors still clears the lock.
KoraInventory.api.createUseable("map", function() error("boom") end)
reset()
KoraInventory.api.useItem(7, 2)
H.ok(not (select(2, move(2, 6)) == "item is currently being used"), "an erroring handler clears the busy lock")

-- Mid-use transfer (from and onto the busy slot) is refused.
local transferResults
KoraInventory.api.createUseable("map", function()
    transferResults = { { move(2, 6) }, { move(1, 2) } }
    return true
end)
reset()
KoraInventory.api.useItem(7, 2)
H.equal(transferResults[1][2], "item is currently being used", "moving the busy slot is refused")
H.equal(transferResults[2][2], "item is currently being used", "moving onto the busy slot is refused")

-- Config off restores the old behaviour.
Config.kora_inventory.blockWhileBusy = false
local offResults
KoraInventory.api.createUseable("map", function()
    offResults = { move(2, 6) }
    return true
end)
reset()
KoraInventory.api.useItem(7, 2)
H.ok(offResults[2] ~= "item is currently being used", "blockWhileBusy = false disables the guard")
Config.kora_inventory.blockWhileBusy = true

-- Timeout safety: a stuck entry expires.
local stuck
KoraInventory.api.createUseable("map", function()
    NOW = NOW + 31000
    stuck = { move(2, 6) }
    return true
end)
reset()
KoraInventory.api.useItem(7, 2)
H.ok(stuck[2] ~= "item is currently being used", "a busy entry expires after busyTimeout")

H.finish()
