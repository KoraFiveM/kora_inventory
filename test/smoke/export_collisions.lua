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
-- Comment lines inside these blocks contain apostrophes ("client.lua's
-- validated transport"), which a bare '([^']+)' scan happily reads as quoted
-- paths. Skip comment lines before extracting.
local function pathsFrom(block)
    local paths = {}
    for line in block:gmatch('[^\n]+') do
        if not line:match('^%s*%-%-') then
            for path in line:gmatch("'([^']+)'") do paths[#paths + 1] = path end
        end
    end
    return paths
end

local block = assert(manifest:match('server_scripts%s*{(.-)\n}'), 'fxmanifest.lua must declare server_scripts')
local serverScripts = pathsFrom(block)
H.ok(#serverScripts >= 8, 'fxmanifest server_scripts were discovered')

-- Shared-script prerequisites. Every server_scripts file below assumes
-- Config/QbInventory helpers and every shop's config are already in the VM,
-- exactly as fxmanifest.lua's shared_scripts load first on a real FXServer.
--
-- Discovered from the manifest rather than listed here: each shop's server file
-- `assert`s its own config block at load time, so a newly added shop that this
-- list had not been updated for failed the whole test with an assertion from
-- inside the shop rather than anything to do with export collisions.
Config = { qbinventory = {} }

local sharedBlock = assert(manifest:match('shared_scripts%s*{(.-)\n}'), 'fxmanifest.lua must declare shared_scripts')
for _, path in ipairs(pathsFrom(sharedBlock)) do
    -- '@resource/file.lua' entries are other resources (qblib, qbsql); the QB
    -- surface they provide is mocked below.
    if path:sub(1, 1) ~= '@' then dofile(path) end
end

-- A minimal QB (qblib/qbsql) surface. Only the entry points touched
-- unconditionally at module-load time need to exist here; everything else in
-- these files runs inside a function body and is never invoked by merely
-- loading the module.
QB = {
    compat = { provideExport = function() end },
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

-- Dual-case pairing. Half this surface shipped with a lowercase alias and half
-- without, so a caller had to know which half a name fell in -- qbambulance
-- called `registerStash`, which only existed as `RegisterStash`, and got
-- "No such export" at boot. These pairs must stay reachable in BOTH cases and
-- must resolve to the SAME function, so an alias can never drift into a second
-- implementation.
--
-- This is an explicit list, not a mechanical case transform, because the
-- PascalCase half of the surface is mostly qb-inventory COMPAT aliases under
-- different names (setItems/SetInventory, stashGet/GetStashItems,
-- canCarry/CanAddItem) rather than case variants. Only genuine case pairs
-- belong here. Deliberately NOT paired: OpenInventory/CloseInventory, whose
-- lowercase forms are the distinct client-realm exports.
for _, pair in ipairs({
    'addItem/AddItem', 'removeItem/RemoveItem', 'getItemByName/GetItemByName',
    'getItemsByName/GetItemsByName', 'getItemBySlot/GetItemBySlot',
    'getItemCount/GetItemCount', 'hasItem/HasItem', 'getFreeSlot/GetFreeSlot',
    'clearInventory/ClearInventory', 'getInventory/GetInventory',
    'getFreeWeight/GetFreeWeight', 'registerStash/RegisterStash',
    'createTemporaryStash/CreateTemporaryStash', 'registerShop/RegisterShop',
    'buyItem/BuyItem', 'registerHook/RegisterHook', 'removeHooks/RemoveHooks',
    'getShopItems/GetShopItems', 'setShopItems/SetShopItems',
    'registerInspectionAccess/RegisterInspectionAccess',
    'removeInspectionAccess/RemoveInspectionAccess',
}) do
    local lower, upper = pair:match('^(.-)/(.+)$')
    local lowerEntries, upperEntries = registeredBy[lower], registeredBy[upper]
    H.ok(lowerEntries ~= nil, 'export ' .. lower .. ' is registered')
    H.ok(upperEntries ~= nil, 'export ' .. upper .. ' is registered')
    if lowerEntries and upperEntries then
        H.ok(lowerEntries[#lowerEntries].fn == upperEntries[#upperEntries].fn,
            'export ' .. pair .. ' resolve to the same function')
    end
end

-- --- client realm ---
--
-- The same flat-namespace hazard applies to client_scripts, and it BIT:
-- client/compat/ox.lua looped `exports(name, fn)` over its whole Ox table,
-- which includes openInventory/closeInventory. client.lua registers those
-- first, so the compat wrappers silently replaced them for every resource in
-- the server -- and those wrappers called exports.qbinventory:openInventory,
-- which then resolved back to themselves. Unbounded recursion on every
-- qbpolice/qbambulance/qbclothing/qblib-playground stash or shop open.
--
-- These client files touch NUI and LocalPlayer at load time, so they are read
-- statically rather than dofile'd. The invariant enforced is the same one the
-- server realm gets structurally from server/compat/providers.lua: a compat
-- module builds a table and its PROVIDER IDENTITY publishes it -- a compat
-- module never registers into qbinventory's own export table.
local clientBlock = assert(manifest:match('client_scripts%s*{(.-)\n}'), 'fxmanifest.lua must declare client_scripts')
local clientScripts = {}
for _, path in ipairs(pathsFrom(clientBlock)) do
    -- Imported dependency files execute in this resource's VM, but they do
    -- not belong to qbinventory's local export surface and cannot be opened
    -- relative to this repository by a plain-Lua test.
    if path:sub(1, 1) ~= '@' then clientScripts[#clientScripts + 1] = path end
end
H.ok(#clientScripts >= 5, 'fxmanifest client_scripts were discovered')

local ownerOfExport = {}
local clientProblems = {}
for _, path in ipairs(clientScripts) do
    local source = read(path)
    local isCompat = path:find('compat', 1, true) ~= nil

    -- Literal registrations: exports('name', fn)
    for name in source:gmatch("exports%(%s*'([%w_]+)'") do
        if ownerOfExport[name] and ownerOfExport[name] ~= path then
            clientProblems[#clientProblems + 1] =
                ("%s is registered by both '%s' and '%s'"):format(name, ownerOfExport[name], path)
        end
        ownerOfExport[name] = ownerOfExport[name] or path
    end

    -- Dynamic registrations: `exports(name, fn)` inside a loop. Unresolvable
    -- statically, so a compat module is simply not allowed to do it.
    if isCompat and source:find('exports%(%s*[%a_][%w_]*%s*,') then
        clientProblems[#clientProblems + 1] =
            ("%s registers exports dynamically into qbinventory's own table; publish under its provider identity instead"):format(path)
    end
end
table.sort(clientProblems)

H.equal(#clientProblems, 0, 'no client_scripts export is registered by two files'
    .. (clientProblems[1] and (' (first: ' .. clientProblems[1] .. ')') or ''))

-- The two names the recursion actually went through must stay owned by
-- client.lua, which is what every other resource calls.
H.equal(ownerOfExport['openInventory'], 'client.lua', 'client.lua owns the openInventory export')
H.equal(ownerOfExport['closeInventory'], 'client.lua', 'client.lua owns the closeInventory export')

H.finish()
