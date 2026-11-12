-- Restored shops against the real server.lua + persistence.lua (framework and
-- SQL transport stubbed): the rendered `items` and the sold-from `stock` are one
-- table after a restart, a purchase is visible in the view, and `weightLimit`
-- decides whether SetShopItems may exceed maxWeight.
local H = dofile('test/harness.lua')
Config = {}
dofile('config.lua')
dofile('shared.lua')
local rows, threads, callbacks, registered = {}, {}, {}, {}
local function noop() end
GetCurrentResourceName = function() return 'kora_inventory' end
GetInvokingResource = function() return nil end
GetGameTimer = function() return 1000 end
GetPlayers = function() return { '7' } end
GetPlayerPed = function(source) return source end
GetEntityCoords = function() return { x = 0, y = 0, z = 0 } end
GetPlayerRoutingBucket = function() return 0 end
CreateThread = function(callback) threads[#threads + 1] = callback end
Wait, RegisterCommand, TriggerClientEvent, SetTimeout = noop, noop, noop, noop
local handlers = {}
AddEventHandler = function(name, callback) handlers[name] = callback end
RegisterNetEvent = AddEventHandler
TriggerEvent = function(name, ...) if handlers[name] then handlers[name](...) end end
local encoded, nextJson = {}, 0
json = {
    encode = function(value)
        nextJson = nextJson + 1
        encoded[tostring(nextJson)] = KoraInventory.copy(value)
        return tostring(nextJson)
    end,
    decode = function(token) return KoraInventory.copy(encoded[token]) end,
}
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
    resources = { serverRegistry = function() return { track = noop, untrack = noop } end },
    callback = { register = function(name, callback) callbacks[name] = callback end },
    distance = { player = function() return true end },
    sql = {
        ready = function() return true end,
        ensureTables = function() return {} end,
        query = function(_, params)
            if #params == 0 then return rows end
            for _, row in ipairs(rows) do
                if row.inventory_type == params[1] and row.inventory_id == params[2] then return { row } end
            end
            return {}
        end,
        execute = function() return true end,
        upsert = function() return true end,
    },
}
local definitions = { wood = { name = 'wood', label = 'Wood', weight = 100 } }
local money, playerItems = 1000, {}
exports = setmetatable({}, {
    __call = function(_, name, callback) registered[name] = callback end,
    __index = function(_, resource)
        return setmetatable({}, { __index = function(_, name)
            return function(_, ...)
                if resource == 'kora_core' then
                    local source, field = ...
                    if name == 'getShared' then return definitions[field] end
                    if name == 'allShared' then return {} end
                    if name == 'getMoney' then return money end
                    if name == 'removeMoney' then
                        local amount = select(3, ...)
                        if money < amount then return false, 'insufficient funds' end
                        money = money - amount
                        return true
                    end
                    if name == 'addMoney' then money = money + select(3, ...) return true end
                    if name == 'getPlayerData' then
                        local data = { citizenid = 'CID7', items = playerItems, metadata = {}, job = { name = 'civ', grade = { level = 0 } } }
                        if field then return data[field] end
                        return data
                    end
                    if name == 'setPath' then
                        local _, path, value = ...
                        if path == 'items' then playerItems = value end
                        return true
                    end
                    return nil
                end
                return registered[name] and registered[name](...)
            end
        end })
    end,
})

-- The durable row as an earlier build left it: `items` still holds the opening
-- seed (10) while `properties.stock` was lowered by purchases (4).
rows[#rows + 1] = {
    inventory_type = 'shop', inventory_id = 'guns', label = 'Guns', slots = 4, max_weight = 500, revision = 3,
    items = { [1] = { name = 'wood', amount = 10, price = 5 } },
    properties = { stock = { [1] = { name = 'wood', amount = 4, price = 5 } } },
}
rows[#rows + 1] = {
    inventory_type = 'shop', inventory_id = 'catalogue', label = 'Catalogue', slots = 4, max_weight = 500, revision = 1,
    items = { [1] = { name = 'wood', amount = 2, price = 5 } },
    properties = { stock = { [1] = { name = 'wood', amount = 2, price = 5 } } },
}

dofile('server/persistence.lua')
dofile('server.lua')
local api, internal, persistence = KoraInventory.api, KoraInventory.internal, KoraInventory.persistence
local seed = { { name = 'wood', amount = 10, price = 5 } }
H.ok(api.RegisterShop('guns', { label = 'Guns', slots = 4, maxWeight = 500, inventory = seed }))
H.ok(api.RegisterShop('catalogue', { label = 'Catalogue', slots = 4, maxWeight = 500, weightLimit = false, inventory = seed }))
threads[1]() -- persistence bootstrap: migrate and restore every stored row

local guns = internal.getInventory('shop:guns')
H.equal(guns.items, guns.stock, 'a restored shop renders the same table it sells from')
H.equal(guns.items[1].amount, 4, 'the persisted stock wins over the stale items snapshot')
H.equal(internal.view(guns.key).items[1].amount, 4, 'the panel shows the real stock after a restart')
H.equal(persistence.load('shop', 'guns').items[1].amount, 4, 'on-demand loads unify the two tables as well')

-- weightLimit: 10 wood = 1000 g against a 500 g maxWeight.
local full = { [1] = { name = 'wood', amount = 10, price = 5 } }
local ok, why = api.SetShopItems('guns', full)
H.equal(ok, false, 'a default shop is still weight-capped (player-stocked shelves rely on it)')
H.equal(why, 'over weight')
H.equal(guns.stock[1].amount, 4, 'a refused write leaves the shelf untouched')
H.ok(api.SetShopItems('catalogue', full), 'a weightLimit = false shop restocks past maxWeight')
local catalogue = internal.getInventory('shop:catalogue')
H.equal(catalogue.items[1].amount, 10)
H.equal(catalogue.items, catalogue.stock, 'SetShopItems keeps items and stock as one table')
H.equal(catalogue.items[1].price, 5, 'restocked rows keep their price')
H.equal(catalogue.weightLimit, false, 'the policy survives restoration (it is re-applied from registration)')
H.equal(guns.weightLimit, true, 'weightLimit defaults to true')
H.ok(api.RegisterShop('catalogue', { label = 'Catalogue', slots = 4, maxWeight = 500, inventory = seed }))
H.equal(api.SetShopItems('catalogue', { [1] = { name = 'wood', amount = 11, price = 5 } }), false,
    're-registering without the option restores the cap')

-- A purchase lowers what the panel shows (it used to bounce back to the seed).
local bought, buyErr = api.BuyItem(7, 'guns', 1, 1)
if bought then
    H.equal(guns.stock[1].amount, 3, 'the purchase lowers stock')
    H.equal(internal.view(guns.key).items[1].amount, 3, 'and the panel shows it')
else
    -- Keep the reason visible if the purchase stub drifts from server.lua.
    error('purchase failed in fixture: ' .. tostring(buyErr))
end
H.finish()
