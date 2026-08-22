local H = dofile('test/harness.lua')

local config = assert(io.open('config.lua', 'r')):read('*a')
local server = assert(io.open('server.lua', 'r')):read('*a')

H.ok(config:find('itemBoxes = {', 1, true), 'item receipt policy is part of qbinventory config')
H.ok(config:find('enabled = true', config:find('itemBoxes = {', 1, true), true), 'item receipt policy has a server-owner switch')
H.ok(server:find("emit(src, 'qbinventory:client:itemBox'", 1, true), 'receipts originate from qbinventory authority')
H.ok(server:find("showItemBox(src, name, amount, 'add')", 1, true), 'public AddItem automatically owns its receipt')
H.ok(server:find("showItemBox(src, currentItem.name, count, 'purchase')", 1, true), 'shop purchases automatically own their receipt')
H.ok(server:find('local def = itemDef(name)', server:find('local function showItemBox', 1, true), true), 'receipt display data is resolved from canonical item definitions')
H.finish()
