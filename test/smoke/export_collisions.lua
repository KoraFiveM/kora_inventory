-- Regression guard for the export-name-collision bug class: this resource's
-- exports table is one flat namespace, so if two server_scripts register the
-- same export name with two different functions, the one that loads later
-- silently overwrites the earlier one for every OTHER resource that calls it
-- (this is exactly how server/compat/qb.lua's old GetInventory/CanAddItem
-- overwrote server.lua's native exports of the same name).
--
-- test/smoke/qb_compat.lua deliberately loads server/compat/qb.lua in
-- isolation with its own mock `exports`, so it can never see a collision with
-- server.lua. This test instead loads every server_scripts entry from
-- fxmanifest.lua, IN THE ORDER THEY APPEAR, into one SHARED mock `exports`
-- table -- the same flat namespace FXServer actually loads them into -- and
-- asserts no export name is ever registered twice with a differing function.
local H = dofile('test/harness.lua')

local function read(path)
    local file = assert(io.open(path, 'r'))
    local source = file:read('*a')
    file:close()
    return source
end

-- Discover server_scripts from fxmanifest.lua itself instead of hardcoding
-- the list a second time, so this test cannot silently drift out of sync
-- with the real load order.
local manifest = read('fxmanifest.lua')
local block = assert(manifest:match('server_scripts%s*{(.-)\n}'), 'fxmanifest.lua must declare server_scripts')
local serverScripts = {}
for path in block:gmatch("'([^']+)'") do serverScripts[#serverScripts + 1] = path end
H.ok(#serverScripts >= 8, 'fxmanifest server_scripts were discovered')

-- Shared-script prerequisites. Every server_scripts file below assumes
-- Config/QbInventory helpers and the Ammu-Nation shop config are already in
-- the VM, exactly as fxmanifest.lua's shared_scripts load first on a real
-- FXServer.
Config = { qbinventory = {} }
dofile('config.lua')
dofile('config/shops/ammunation.lua')
dofile('shared.lua')

-- A minimal QB (qblib/qbsql) surface. Only the entry points touched
-- unconditionally at module-load time need to exist here; everything else in
-- these files runs inside a function body and is never invoked by merely
-- loading the module.
QB = {
    resources = { serverRegistry = function() return { track = function() end, untrack = function() end } end },
    callback = { register = function() end },
    sql = {},
}

-- Cfx natives referenced at module-load time (not inside a function body) by
-- these server_scripts. CreateThread/RegisterCommand/AddEventHandler/
-- RegisterNetEvent are intentionally no-ops: none of these files run
-- business logic through them at load time, they only register callbacks.
GetCurrentResourceName = function() return 'qbinventory' end
GetInvokingResource = function() return nil end
CreateThread = function() end
RegisterCommand = function() end
AddEventHandler = function() end
RegisterNetEvent = function() end

-- The shared mock `exports` table under test. `exports(name, fn)` is the
-- registration form every server_scripts file above uses. `exports.res:Fn(...)`
-- is the rarer in-resource consumption form -- server/shops/ammunation.lua
-- calls `exports.qbinventory:RegisterShop(...)` at load time, which must
-- resolve to whatever server.lua registered moments earlier through the very
-- same table. An export that was never registered here (e.g. exports.qbcore,
-- which this test never loads) resolves to a no-op returning nil rather than
-- erroring, so an unrelated missing dependency can't hide a real collision.
local registeredBy = {} -- exportName -> { {file=, fn=}, ... } in registration order
local currentFile = '?'
local exportsProxy = setmetatable({}, {
    __call = function(_, name, fn)
        registeredBy[name] = registeredBy[name] or {}
        table.insert(registeredBy[name], { file = currentFile, fn = fn })
    end,
    __index = function(_, _resourceName)
        return setmetatable({}, {
            __index = function(_, exportName)
                return function(_, ...)
                    if _resourceName == 'qbcore' and exportName == 'allShared' then return {} end
                    local entries = registeredBy[exportName]
                    local fn = entries and entries[#entries].fn
                    if fn then return fn(...) end
                    return nil
                end
            end,
        })
    end,
})
exports = exportsProxy

for _, path in ipairs(serverScripts) do
    currentFile = path
    dofile(path)
end

local collisions = {}
for name, entries in pairs(registeredBy) do
    if #entries > 1 then
        local first = entries[1].fn
        for i = 2, #entries do
            if entries[i].fn ~= first then
                collisions[#collisions + 1] = ("%s: %s registered by '%s', silently overwritten by '%s'")
                    :format(name, name, entries[1].file, entries[i].file)
            end
        end
    end
end
table.sort(collisions)

H.equal(#collisions, 0, 'no export name is silently overwritten by a later server_scripts file'
    .. (collisions[1] and (' (first: ' .. collisions[1] .. ')') or ''))

-- Sanity check that this actually exercised real registrations rather than
-- passing vacuously because every dofile above failed silently.
local total = 0
for _ in pairs(registeredBy) do total = total + 1 end
H.ok(total > 20, 'the combined exports table captured every server_scripts export')

H.finish()
