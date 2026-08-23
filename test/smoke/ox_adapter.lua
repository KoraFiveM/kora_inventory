-- Contract coverage for the isolated Ox server adapter. This remains static
-- because the real authority depends on Cfx/qbcore exports; runtime behaviour
-- is covered when the adapter is enabled as part of provider conformance.
local H = dofile('test/harness.lua')
local file = assert(io.open('server/compat/ox.lua', 'r'))
local source = file:read('*a')
file:close()

local authorityFile = assert(io.open('server.lua', 'r'))
local authoritySource = authorityFile:read('*a')
authorityFile:close()

H.ok(source:find("I.compat.ox = Ox", 1, true), 'adapter is namespaced and does not replace authority')
H.ok(not source:find("exports('", 1, true), 'adapter registers no premature Cfx exports')
H.ok(not source:find("provide 'ox_inventory'", 1, true), 'adapter does not advertise an incomplete provider')
H.ok(source:find('core.resolveInventory', 1, true), 'lookup delegates to trusted authority seam')
H.ok(source:find('core.lock({ key }', 1, true), 'mutations acquire deterministic authority locks')
H.ok(source:find('core.setInventoryItems', 1, true), 'item mutations use qbcore-aware write funnel')
H.ok(source:find('function Ox.Search', 1, true), 'metadata-aware Search adapter exists')
H.ok(source:find('function Ox.GetItem', 1, true), 'GetItem adapter exists')
H.ok(source:find('function Ox.GetInventoryItems', 1, true), 'GetInventoryItems adapter exists')
H.ok(source:find('function Ox.CanCarryItem', 1, true), 'CanCarryItem adapter exists')
H.ok(source:find('function Ox.SetMetadata', 1, true), 'SetMetadata adapter exists')
H.ok(source:find('function Ox.SetDurability', 1, true), 'SetDurability adapter exists')
H.ok(source:find('function Ox.SetSlotCount', 1, true), 'SetSlotCount adapter exists')
H.ok(source:find('function Ox.SetMaxWeight', 1, true), 'SetMaxWeight adapter exists')
H.ok(source:find('metadata_weight_not_supported', 1, true), 'unsupported custom metadata weight is explicit')
H.ok(source:find('player_inventory_dimensions_are_configured_by_qbcore', 1, true), 'player dimension ownership is explicit')
-- AddItem/RemoveItem no longer duplicate the shop read-only guard themselves --
-- it's enforced once, for every write path, inside the authority's addTo/removeFrom
-- (server.lua), which AddItem/RemoveItem reach via core.addTo/core.removeFrom.
H.ok(source:find('core.addTo(currentKey', 1, true), 'AddItem writes through the shared authority write funnel')
H.ok(source:find('core.removeFrom(currentKey', 1, true), 'RemoveItem writes through the shared authority write funnel')
H.ok(authoritySource:find("if inv.type == 'shop' then return false, 'shop inventory is read only' end", 1, true), 'addTo rejects writes into shop stock for every caller, including the ox adapter')
H.ok(authoritySource:find("if inv.type == 'shop' then return false, 'shop items must be purchased' end", 1, true), 'removeFrom rejects taking shop stock for every caller, including the ox adapter')
for _, name in ipairs({
    'GetContainerFromSlot', 'RemoveInventory', 'UpdateVehicle', 'SwapSlots',
    'CanSwapItem', 'CustomDrop', 'CreateDropFromPlayer', 'ConfiscateInventory',
    'ReturnInventory', 'ClearInventory', 'RegisterStash', 'CreateTemporaryStash',
    'InspectInventory', 'RegisterShop', 'registerHook', 'removeHooks', 'Items',
    'ItemList', 'setPlayerInventory', 'forceOpenInventory',
}) do
    H.ok(source:find('function Ox.' .. name, 1, true) or source:find('Ox.' .. name .. ' =', 1, true), 'Ox adapter exposes ' .. name)
end
H.finish()
