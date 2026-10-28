local H = dofile('test/harness.lua')

local handlers = {}
_G.QbInventory = { compat = { qb = { GetInventory = function() end }, ox = { GetInventory = function() end } } }
_G.AddEventHandler = function(name, handler) handlers[name] = handler end
_G.GetCurrentResourceName = function() return 'kora_inventory' end
_G.QB = { compat = { provideExport = function(identity, name, fn)
    AddEventHandler(('__cfx_export_%s_%s'):format(identity, name), function(setCallback) setCallback(fn) end)
end } }

_G.GetNumResources = function() return 1 end
_G.GetResourceByFindIndex = function() return 'kora_inventory' end
-- This is the bug regression: Cfx resolves the provided alias to us.
_G.GetResourceState = function(name)
    if name == 'qb-inventory' or name == 'ox_inventory' then return 'started' end
    return 'started'
end

dofile('server/compat/providers.lua')
H.ok(handlers['__cfx_export_qb-inventory_GetInventory'], 'qb alias export should register')
H.ok(handlers['__cfx_export_ox_inventory_GetInventory'], 'ox alias export should register')

_G.GetResourceByFindIndex = function() return 'qb-inventory' end
local ok, err = pcall(dofile, 'server/compat/providers.lua')
H.ok(not ok and tostring(err):find('provider conflict', 1, true), 'a real qb-inventory resource must still fail fast')

_G.GetResourceByFindIndex = function() return 'qb-weapons' end
ok, err = pcall(dofile, 'server/compat/providers.lua')
H.ok(not ok and tostring(err):find('provider conflict', 1, true), 'the retired qb-weapons controller cannot run beside its replacement')

H.finish()
