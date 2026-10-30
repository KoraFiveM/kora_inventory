local H = dofile('test/harness.lua')
local file = assert(io.open('client/compat.lua', 'r'))
local source = file:read('*a')
file:close()

H.ok(source:find("'qbinventory:ui:sessionOpened'", 1, true), 'busy state follows opened session')
H.ok(source:find("'qbinventory:ui:sessionClosed'", 1, true), 'busy state follows closed session')
H.ok(source:find("LocalPlayer.state:set('inv_busy'", 1, true), 'uses LocalPlayer inv_busy state')
H.ok(source:find("'qbinventory:client:useStarted'", 1, true), 'clears inv_busy while a close-on-use handler runs')
H.ok(source:find("'qbinventory:client:useRejected'", 1, true), 'restores inv_busy when a use is rejected')
H.ok(source:find("'qb-inventory:client:openInventory'", 1, true), 'bridges legacy open event')
H.ok(source:find("'qb-inventory:client:closeInv'", 1, true), 'bridges legacy close event')
H.ok(source:find("'qb-inventory:client:updateInventory'", 1, true), 'bridges legacy update event')
H.ok(source:find("'qb-inventory:client:ItemBox'", 1, true), 'legacy item boxes are intercepted by inventory presentation policy')
H.ok(source:find("RegisterCommand('inventory'", 1, true), 'inventory command')
H.ok(source:find('inventoryApi.getCurrentSession()', 1, true) and source:find('inventoryApi.closeInventory()', 1, true),
    'inventory command toggles an active qbinventory session closed')
H.ok(source:find('QB.zones.isCreatorActive()', 1, true), 'TAB defers to an in-progress zone creator session instead of opening alongside it')
H.ok(source:find('QB.placement.isActive()', 1, true), 'TAB defers to an in-progress entity placement session through kora_lib export proxy')
H.ok(source:find("RegisterCommand('closeInv'", 1, true), 'close command')
H.ok(source:find('QB.keybind.add({', 1, true) and source:find("name = 'openInv'", 1, true),
    'legacy TAB mapping uses QB.keybind')
H.ok(source:find("inventoryApi.openInventory(typeName, id)", 1, true), 'legacy targets route through validated open API')
H.ok(source:find('refreshActiveSession()', 1, true), 'updates request an authoritative refresh')
-- The server emits the legacy qb-inventory:client:updateInventory after every
-- committed change so third-party scripts hear about it. If this bridge
-- re-opened the session in response, the player's own UI would be closed and
-- reissued on every single item change.
H.ok(source:find('return inventoryApi.getCurrentSession() ~= nil', 1, true),
    'a legacy update push never re-opens an active session (feedback-loop guard)')
H.ok(not source:find('SendNUIMessage', 1, true), 'compat bridge has no NUI authority')
H.ok(not source:find('SetNuiFocus', 1, true), 'compat bridge has no focus authority')
H.ok(not source:find('other.inventory', 1, true), 'does not trust legacy item lists')
H.ok(not source:find('GetVehicle', 1, true), 'does not discover vehicles client-side')
H.finish()
