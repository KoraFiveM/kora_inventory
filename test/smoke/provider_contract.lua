-- Provider-identity conformance against the pinned upstream contracts.
--
-- This used to grep the CONCATENATED SOURCE TEXT of the compat files for each
-- contract name, so a name that appeared only in a comment satisfied it and a
-- name present in the file but never placed on the compat table looked fine.
-- It was also missing from test/run.sh entirely, so it never ran -- which is
-- how `HasItem` stayed absent from the qb-inventory identity while the pinned
-- contract listed it, and how kora_ambulance's `registerStash` call reached a
-- production boot.
--
-- Instead, load every realm's scripts the way FXServer does and capture what
-- actually gets published: server/compat/providers.lua and client.lua both
-- expose a provider identity through __cfx_export_<identity>_<name> handlers,
-- so recording those gives the exact surface another resource can call.
local H = dofile('test/harness.lua')
local contract = dofile('test/contracts/upstream.lua')

local function read(path)
    local file = assert(io.open(path, 'r'), 'missing ' .. path)
    local source = file:read('*a')
    file:close()
    return source
end

local manifest = read('fxmanifest.lua')
local function pathsFrom(blockName)
    local block = assert(manifest:match(blockName .. '%s*{(.-)\n}'), 'fxmanifest.lua must declare ' .. blockName)
    local paths = {}
    for line in block:gmatch('[^\n]+') do
        if not line:match('^%s*%-%-') then
            for path in line:gmatch("'([^']+)'") do paths[#paths + 1] = path end
        end
    end
    return paths
end

-- realm -> identity -> { name -> fn }, from __cfx_export_<identity>_<name>.
--
-- The realms are kept SEPARATE on purpose. A server-side caller doing
-- exports['qb-inventory']:HasItem(src, items) is not served by client.lua
-- also publishing a client HasItem under the same identity, so letting one
-- realm satisfy the other's contract would hide exactly the gap this test
-- exists to find.
local published = { server = {}, client = {} }
local realm = 'server'
local function capture(eventName, handler)
    local identity, name = eventName:match('^__cfx_export_(.+)_([%w_]+)$')
    if not identity then return end
    local byIdentity = published[realm]
    byIdentity[identity] = byIdentity[identity] or {}
    -- The handler hands the real function back through a setCB callback.
    handler(function(fn) byIdentity[identity][name] = fn end)
end

-- shared prerequisites (fxmanifest shared_scripts)
--
-- Discovered from the manifest rather than listed here: each shop's server
-- file `assert`s its own config block at load time, so a newly added shop this
-- list had not been updated for failed the whole test with an assertion from
-- inside that shop rather than anything about the provider contract.
Config = { qbinventory = {} }
for _, path in ipairs(pathsFrom('shared_scripts')) do
    -- '@resource/file.lua' entries are other resources (kora_lib, kora_sql); the Kora
    -- surface they provide is mocked below.
    if path:sub(1, 1) ~= '@' then dofile(path) end
end

Kora = {
    compat = { provideExport = function(identity, name, fn)
        AddEventHandler(('__cfx_export_%s_%s'):format(identity, name), function(setCallback) setCallback(fn) end)
    end },
    resources = { serverRegistry = function() return { track = function() end, untrack = function() end } end },
    callback = { register = function() end, trigger = function() return nil end },
    notify = { send = function() end },
    progressbar = { start = function() end, cancel = function() end },
    sql = {},
}
-- Client files register zones/targets/keybinds at load time. None of that is
-- under test here; it only has to not error while the export surface is built.
Kora.interact = setmetatable({}, { __index = function() return function() return { remove = function() end } end end })
Kora.zones = setmetatable({}, { __index = function() return function() return { remove = function() end } end end })
Kora.target = setmetatable({}, { __index = function() return function() end end })
Kora.nui = setmetatable({}, { __index = function() return function() end end })
Kora.cache = setmetatable({}, { __index = function() return function() end end })
Kora.loops = setmetatable({}, { __index = function() return function() end end })
Kora.state = setmetatable({}, { __index = function() return function() end end })
Kora.entities = setmetatable({}, { __index = function() return function() end end })
Kora.anim = setmetatable({}, { __index = function() return function() end end })
Kora.blips = setmetatable({}, { __index = function() return function() end end })
Kora.theme = setmetatable({}, { __index = function() return function() end end })
Kora.keybind = { add = function() return { remove = function() return true end } end }
vector3 = function(x, y, z) return { x = x, y = y, z = z } end
QBTheme = { refresh = function() end, apply = function() return {} end }

GetCurrentResourceName = function() return 'kora_inventory' end
GetInvokingResource = function() return nil end
CreateThread = function() end
RegisterCommand = function() end
RegisterKeyMapping = function() end
RegisterNetEvent = function() end
RegisterNUICallback = function() end
SendNUIMessage = function() end
SetNuiFocus = function() end
TriggerEvent = function() end
TriggerServerEvent = function() end
IsPauseMenuActive = function() return false end
IsNuiFocused = function() return false end
ExecuteCommand = function() end
GetPlayerServerId = function() return 1 end
PlayerId = function() return 0 end
LocalPlayer = { state = setmetatable({}, { __index = function() return nil end, __newindex = function() end }) }
LocalPlayer.state.set = function() end
AddEventHandler = capture

local registered = {}
exports = setmetatable({}, {
    __call = function(_, name, fn) registered[name] = fn end,
    __index = function(_, resourceName)
        return setmetatable({}, {
            __index = function(_, exportName)
                return function(_, ...)
                    if resourceName == 'kora_core' and exportName == 'allShared' then return {} end
                    if resourceName == 'kora_core' and exportName == 'getPlayerData' then return {} end
                    if resourceName == 'kora_core' and exportName == 'getShared' then
                        local registry, name = ...
                        if registry == 'items' and name == 'water_bottle' then
                            return {
                                name = 'water_bottle', label = 'Water Bottle', weight = 500,
                                type = 'item', unique = false, useable = true,
                            }
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

realm = 'server'
for _, path in ipairs(pathsFrom('server_scripts')) do dofile(path) end
realm = 'client'
for _, path in ipairs(pathsFrom('client_scripts')) do
    if path:sub(1, 1) ~= '@' then dofile(path) end
end

-- Sanity: fail loudly rather than vacuously if the loads above did nothing.
local function size(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end
H.ok(size(published.server['qb-inventory']) > 20, 'the qb-inventory server identity published a real surface')
H.ok(size(published.server['ox_inventory']) > 20, 'the ox_inventory server identity published a real surface')
H.ok(size(published.client['ox_inventory']) > 20, 'the ox_inventory client identity published a real surface')

local function assertContract(whichRealm, identity, names, label)
    local surface = published[whichRealm][identity] or {}
    local missing = {}
    for _, name in ipairs(names) do
        if type(surface[name]) ~= 'function' then missing[#missing + 1] = name end
    end
    table.sort(missing)
    H.equal(#missing, 0, ('%s: every pinned export is callable on the %s %s identity%s')
        :format(label, identity, whichRealm, missing[1] and (' -- missing: ' .. table.concat(missing, ', ')) or ''))
end

assertContract('server', 'qb-inventory', contract.qbInventory.server, 'qb server')
assertContract('client', 'qb-inventory', contract.qbInventory.client, 'qb client')
assertContract('server', 'ox_inventory', contract.oxInventory.server, 'ox server')
assertContract('client', 'ox_inventory', contract.oxInventory.client, 'ox client')

-- kora_lib-playground initialises its shared locker at resource startup through
-- RegisterStash + SetStashItems. This regression test exercises that public
-- path end to end: stashSet is declared above setInventoryItems in server.lua,
-- so it must close over the forward-declared local instead of a nil global.
local stashKey = assert(registered.RegisterStash('smoke-stash', 'Smoke stash', 10, 10000, false))
local stored, storeErr = registered.SetStashItems(stashKey, {
    [1] = { name = 'water_bottle', amount = 1, slot = 1, info = {} },
})
H.ok(stored, 'SetStashItems writes a registered stash without a missing write funnel error: ' .. tostring(storeErr))
local items = registered.GetStashItems(stashKey)
H.equal(items[1].name, 'water_bottle', 'SetStashItems commits the supplied item')

H.finish()
