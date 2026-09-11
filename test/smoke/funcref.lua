-- Regression guard for the cross-resource callback bug class.
--
-- FXServer's exports boundary does not hand a function argument across as a
-- plain Lua function -- it arrives as a TABLE with a __call metamethod. Every
-- registration API here used to gate on `type(x) == 'function'`, so every
-- createUseable/registerInspectionAccess/registerHook call made from another
-- resource failed its own assert at boot ("name and handler are required",
-- "inspection callback is required"). qbpolice, qbambulance and qbdrugs all
-- started with their useable items silently unregistered.
--
-- These tests call the real registration exports with the funcref SHAPE, which
-- is the thing the old check rejected. A plain function is also asserted so a
-- fix that only accepts tables would fail too.
local H = dofile('test/harness.lua')

-- Shared-script prerequisites, mirroring fxmanifest.lua's load order.
Config = { qbinventory = {} }
dofile('config.lua')
dofile('config/shops/ammunation.lua')
dofile('shared.lua')

QB = {
    resources = { serverRegistry = function() return { track = function() end, untrack = function() end } end },
    callback = { register = function() end },
    sql = {},
}
GetCurrentResourceName = function() return 'qbinventory' end
GetInvokingResource = function() return 'qbpolice' end
CreateThread = function() end
RegisterCommand = function() end
AddEventHandler = function() end
RegisterNetEvent = function() end

local registered = {}
exports = setmetatable({}, {
    __call = function(_, name, fn) registered[name] = fn end,
    __index = function(_, resourceName)
        return setmetatable({}, {
            __index = function(_, exportName)
                return function(_, ...)
                    if resourceName == 'qbcore' and exportName == 'allShared' then return {} end
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

-- A cross-resource callback as FXServer actually delivers it: callable, but
-- type() reports 'table', not 'function'.
local function funcref(fn)
    return setmetatable({}, { __call = function(_, ...) return fn(...) end })
end

H.ok(QbInventory.isCallable(funcref(function() end)), 'a __call table is recognised as callable')
H.ok(QbInventory.isCallable(function() end), 'a plain function is still recognised as callable')
H.ok(not QbInventory.isCallable({}), 'a bare table is not callable')
H.ok(not QbInventory.isCallable('handler'), 'a string is not callable')
H.ok(not QbInventory.isCallable(nil), 'nil is not callable')

-- createUseable: the qbpolice/qbambulance/qbdrugs boot failure.
local calls = 0
local handler = funcref(function() calls = calls + 1 end)
local ok, err = pcall(registered.createUseable, 'handcuffs', handler)
H.ok(ok, 'createUseable accepts a cross-resource funcref (' .. tostring(err) .. ')')
H.ok(QbInventory.internal.hasUseable('handcuffs'), 'the funcref handler is actually registered as useable')
-- useItem invokes handlers through pcall(handler, src, item); a __call table
-- must survive that, otherwise registration would succeed but using the item
-- would fail at runtime instead of at boot.
H.ok(select(1, pcall(handler, 1, {})) and calls == 1, 'the registered funcref handler is invocable')

H.ok(pcall(registered.createUseable, 'radio', function() end), 'createUseable still accepts a plain function')
H.ok(not pcall(registered.createUseable, 'nohandler', {}), 'createUseable still rejects a non-callable handler')
H.ok(not pcall(registered.createUseable, 42, function() end), 'createUseable still rejects a non-string name')

-- registerInspectionAccess: the qbpolice/server/seize.lua boot failure.
local id = registered.registerInspectionAccess(funcref(function() return true end))
H.ok(type(id) == 'number', 'registerInspectionAccess accepts a cross-resource funcref')
H.ok(not pcall(registered.registerInspectionAccess, {}), 'registerInspectionAccess still rejects a non-callable')

-- registerHook: same seam, not yet reached at boot but the identical defect.
local hookId = registered.registerHook('swapItems', funcref(function() return true end))
H.ok(type(hookId) == 'number', 'registerHook accepts a cross-resource funcref')
H.ok(not pcall(registered.registerHook, 'swapItems', {}), 'registerHook still rejects a non-callable')
H.ok(not pcall(registered.registerHook, 42, function() end), 'registerHook still rejects a non-string event')

H.finish()
