local H = dofile('test/harness.lua')

local config = assert(io.open('config.lua', 'r')):read('*a')
local server = assert(io.open('server.lua', 'r')):read('*a')

H.ok(config:find('itemBoxes = {', 1, true), 'item receipt policy is part of qbinventory config')
H.ok(config:find('enabled = true', config:find('itemBoxes = {', 1, true), true), 'item receipt policy has a server-owner switch')
H.ok(server:find("emit(src, 'qbinventory:client:itemBox'", 1, true), 'receipts originate from qbinventory authority')
H.ok(server:find("showItemBox(src, name, amount, 'add')", 1, true), 'public AddItem automatically owns its receipt')
H.ok(server:find("showItemBox(src, currentItem.name, count, 'purchase')", 1, true), 'shop purchases automatically own their receipt')
H.ok(server:find("showItemBox(src, name, amount, 'remove')", 1, true), 'public RemoveItem automatically owns its receipt')
H.ok(server:find("showItemBox(src, policy.item, amount, 'remove')", 1, true), 'physical cash debits own a receipt, mirroring credits')
H.ok(server:find("showItemBox(src, item.name, 1, 'use')", 1, true), 'a successful useable use owns its receipt')

local boxes = config:find('itemBoxes = {', 1, true)
for _, switch in ipairs({ 'showAdditions', 'showPurchases', 'showRemovals', 'showUses' }) do
    H.ok(config:find(switch, boxes, true), ('item receipt policy exposes %s'):format(switch))
    H.ok(server:find(('policy.%s ~= true then return end'):format(switch), 1, true),
        ('%s gates its own receipt action server-side'):format(switch))
end
-- A consuming useable already draws a removal receipt through RemoveItem, so
-- the use receipt must stay opt-in or one action shows two boxes.
H.ok(config:find('showUses = false', boxes, true), 'use receipts are opt-in by default')
H.ok(server:find('local def = itemDef(name)', server:find('local function showItemBox', 1, true), true), 'receipt display data is resolved from canonical item definitions')
H.finish()
