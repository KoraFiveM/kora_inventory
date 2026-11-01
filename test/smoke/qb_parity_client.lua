local H = dofile('test/harness.lua')
local function read(path) local f = assert(io.open(path, 'r')); local s = f:read('*a'); f:close(); return s end
local client, compat, ui = read('client.lua'), read('client/compat.lua'), read('client/ui.lua')

local a = client:find('local function hasItem', 1, true)
local b = client:find('QbInventory.clientApi = {', 1, true)
local chunk = client:sub(a, b - 1) .. '\nreturn hasItem'
local items = {
    { name = 'water', amount = 3 }, { name = 'water', amount = 2 }, { name = 'Bread', amount = 1 },
}
exports = { kora_core = { getPlayerData = function() return { items = items } end } }
setmetatable(exports, { __index = exports })
local env = setmetatable({ exports = { kora_core = { getPlayerData = function() return { items = items } end } } }, { __index = _G })
local hasItem = assert(load(chunk, 'hasItem', 't', env))()

H.ok(hasItem('water'), 'string present')
H.ok(hasItem('water', 5), 'string amounts sum across slots')
H.ok(not hasItem('water', 6), 'string shortfall')
H.ok(not hasItem('nothing'), 'string absent')
H.ok(hasItem({ 'water', 'bread' }), 'array: every name present')
H.ok(not hasItem({ 'water', 'nothing' }), 'array: a missing name fails')
H.ok(not hasItem({ 'water', 'bread' }, 2), 'array with amount applies to every entry')
H.ok(hasItem({ water = 5, bread = 1 }), 'map: counts met')
H.ok(not hasItem({ water = 6 }), 'map: count not met is false, not always true')
H.ok(not hasItem({ water = 1, nothing = 1 }), 'map: a missing name fails')
H.ok(not hasItem({ water = 1 }, 6), 'map: explicit amount overrides per-name counts')
H.ok(not hasItem({}), 'empty table is false')

H.ok(compat:find("RegisterNetEvent('qb-inventory:client:ItemBox', legacyItemBox)", 1, true), 'stock ItemBox is forwarded')
H.ok(compat:find("RegisterNetEvent('inventory:client:ItemBox', legacyItemBox)", 1, true), 'legacy ItemBox alias is forwarded')
H.ok(compat:find('itemData.koraReceipt', 1, true), 'the inventory\'s own legacy copy is not re-rendered')
H.ok(ui:find("AddEventHandler('qbinventory:ui:legacyItemBox'", 1, true), 'UI bridge renders legacy item boxes')
H.ok(ui:find('policy.enabled ~= true', 1, true), 'legacy boxes obey the itemBoxes policy')
H.ok(ui:find("getShared('items', name)", 1, true), 'legacy box label and art come from the registry, not the payload')
H.ok(ui:find('takeSeen(seenReceipts.legacy, key)', 1, true) and ui:find('takeSeen(seenReceipts.native, key)', 1, true), 'native and legacy receipts de-duplicate each other')
H.ok(compat:find("RegisterNetEvent('qb-inventory:client:requiredItems', showRequiredItems)", 1, true), 'requiredItems shows a hint')
H.ok(compat:find('Kora.textui.show', 1, true) and compat:find('exports.kora_core:getShared', 1, true), 'hint text is built from registry labels')
H.ok(not compat:find('SendNUIMessage', 1, true), 'compat bridge still has no NUI authority')
H.finish()
