local H = dofile('test/harness.lua')

local config = assert(io.open('config.lua', 'r')):read('*a')
local server = assert(io.open('server.lua', 'r')):read('*a')
local compactServer = server:gsub('%s+', ' ')

H.ok(config:find('itemBoxes = {', 1, true), 'item receipt policy is part of qbinventory config')
H.ok(config:find('enabled = true', config:find('itemBoxes = {', 1, true), true), 'item receipt policy has a server-owner switch')
H.ok(server:find("TriggerClientEvent('qbinventory:client:itemBox', src", 1, true), 'receipts originate from qbinventory authority')
H.ok(server:find("showItemBox(src, name, amount, 'add', added)", 1, true), 'public AddItem automatically owns its receipt')
H.ok(server:find("showItemBox(src, currentItem.name, count, 'purchase', addedItem)", 1, true), 'shop purchases automatically own their receipt')
H.ok(server:find("showItemBox(src, name, amount, 'remove', removed)", 1, true), 'public RemoveItem automatically owns its receipt')
H.ok(server:find("showItemBox(src, policy.item, part.amount, 'remove', part.item)", 1, true), 'physical cash debits own a receipt, mirroring credits')
H.ok(server:find("showItemBox(src, item.name, 1, 'use', item)", 1, true), 'a successful useable use owns its receipt')

local boxes = config:find('itemBoxes = {', 1, true)
for _, switch in ipairs({ 'showAdditions', 'showPurchases', 'showRemovals', 'showUses' }) do
    H.ok(config:find(switch, boxes, true), ('item receipt policy exposes %s'):format(switch))
    H.ok(compactServer:find(('policy.%s ~= true then return end'):format(switch), 1, true),
        ('%s gates its own receipt action server-side'):format(switch))
end
-- A consuming useable already draws a removal receipt through RemoveItem, so
-- the use receipt must stay opt-in or one action shows two boxes.
H.ok(config:find('showUses = false', boxes, true), 'use receipts are opt-in by default')
H.ok(server:find('local def = itemDef(name)', server:find('local function showItemBox', 1, true), true), 'receipt display data is resolved from canonical item definitions')

Config = { qbinventory = {} }
dofile('config.lua')
dofile('shared.lua')
QB = {
    resources = { serverRegistry = function() return { track = function() end, untrack = function() end } end },
    callback = { register = function() end },
}
GetCurrentResourceName = function() return 'qbinventory' end
GetInvokingResource = function() return nil end
GetGameTimer = function() return 100 end
CreateThread = function() end
RegisterCommand = function() end
AddEventHandler = function() end
RegisterNetEvent = function() end
TriggerEvent = function() end
local receipts, legacyReceipts = {}, {}
TriggerClientEvent = function(event, _, payload)
    if event == 'qbinventory:client:itemBox' then receipts[#receipts + 1] = payload end
    if event == 'qb-inventory:client:ItemBox' then legacyReceipts[#legacyReceipts + 1] = payload end
end
local player = { name = 'Test', items = {} }
local definition = { name = 'card', label = 'Card', image = 'card.png', weight = 10, description = 'Base card' }
exports = setmetatable({ qbcore = {
    allShared = function() return {} end,
    getShared = function(_, registry, name) return registry == 'items' and name == 'card' and definition or nil end,
    getPlayerData = function(_, _, path) return path and player.items or player end,
    setPath = function(_, _, path, value) player.items[path[2]] = value; return true end,
} }, { __call = function() end })
dofile('server.lua')
local api, internal = QbInventory.api, QbInventory.internal

for _, info in ipairs({
    {},
    { image = 'charizard.png' },
    { imageUrl = 'https://example.com/charizard.png' },
    { label = 'Charizard', image = 'charizard.png', weight = 1000, description = 'This is a Charizard!' },
    { image = 'pikachu.png', imageUrl = 'https://example.com/charizard.png', show = false },
}) do
    local added = table.pack(api.AddItem(1, 'card', 2, 1, info))
    H.equal(added[1], true, 'add succeeds')
    H.equal(added.n, 2, 'AddItem retains its return contract')
    local grid = internal.view('player:1').items[1]
    local receipt = receipts[#receipts]
    for _, field in ipairs({ 'label', 'image', 'imageUrl', 'imageOverride' }) do
        H.equal(receipt[field], grid[field], 'add receipt matches effective grid ' .. field)
    end
    H.equal(receipt.image, info.image or definition.image, 'effective filename')
    H.equal(receipt.imageUrl, info.imageUrl, 'effective URL')
    H.equal(grid.label, info.label or definition.label, 'label override is preserved')
    H.equal(grid.weight, info.weight or definition.weight, 'weight override is preserved')
    H.equal(grid.description, info.description or definition.description, 'description override is preserved')
    H.equal(legacyReceipts[#legacyReceipts], receipt, 'legacy event carries the same resolved receipt')
    H.ok(api.RemoveItem(1, 'card', 2, 1), 'remove succeeds, including the last item in a slot')
    local removed = receipts[#receipts]
    H.equal(removed.action, 'remove', 'remove action')
    H.equal(removed.amount, 2, 'removed quantity')
    for _, field in ipairs({ 'label', 'image', 'imageUrl', 'imageOverride' }) do
        H.equal(removed[field], grid[field], 'remove receipt retains the instance ' .. field)
    end
end

H.ok(api.AddItem(1, 'card', 1, 1, { image = 'charizard.png' }), 'first card instance')
H.ok(api.AddItem(1, 'card', 2, 2, { image = 'pikachu.png' }), 'second card instance')
H.ok(api.AddItem(1, 'card', 1, 2, { image = 'other.png' }), 'explicit-slot stack follows existing behaviour')
H.equal(receipts[#receipts].image, 'pikachu.png', 'receipt uses the committed stack, not supplied metadata')
H.ok(api.RemoveItem(1, 'card', 2), 'remove spans differently styled cards')
H.equal(receipts[#receipts - 1].image, 'charizard.png', 'first removed stack uses its own artwork')
H.equal(receipts[#receipts].image, 'pikachu.png', 'second removed stack uses its own artwork')
H.equal(player.items[2].amount, 2, 'partial removal preserves the remaining stack')
local before = #receipts
H.equal(api.RemoveItem(1, 'card', 100), false, 'insufficient removal fails')
H.equal(#receipts, before, 'failed removal produces no receipt')

player.items = {}
definition.unique = true
H.ok(api.AddItem(1, 'card', 2, nil, { image = 'charizard.png' }), 'unique multi-item grant')
H.equal(receipts[#receipts].image, 'charizard.png', 'unique grants retain instance artwork')
definition.unique = false
player.items = {}
H.ok(api.AddItem(1, 'card', 1, 1, {
    label = 'Charizard', image = 'charizard.png', weight = 0, description = 'Custom',
    quality = 50, owner = 'Mustache Dom', show = false,
    check = { name = 'weapon_id', date = 'tuesday', price = 300, show = true,
        nested = { active = false, show = true } },
    check2 = { name = 'hidden' },
    check3 = { name = 'hidden', show = false },
}), 'seed visible and hidden metadata')
local item = internal.view('player:1').items[1]
local metadata = {}
for _, entry in ipairs(item.displayMeta) do
    H.equal(type(entry.value) == 'table', false, 'containers are never JSON metadata')
    metadata[entry.key] = entry.value
end
H.equal(#item.displayMeta, 6, 'only visible scalar metadata is listed')
H.equal(metadata.name, 'weapon_id', 'visible children are flattened')
H.equal(metadata.date, 'tuesday', 'date child')
H.equal(metadata.price, 300, 'numeric child')
H.equal(metadata.active, false, 'nested visible containers preserve false values')
H.equal(metadata.quality, 50, 'normal scalar metadata')
H.equal(metadata.owner, 'Mustache Dom', 'normal text metadata')
H.equal(item.weight, 0, 'zero weight override survives flattening')
H.equal(player.items[1].info.check.show, true, 'rendering does not mutate stored metadata')

player.items = {}
definition.imageUrl = 'https://example.com/base.png'
H.ok(api.AddItem(1, 'card', 1, 1, {}), 'base definition with remote artwork')
H.equal(receipts[#receipts].imageUrl, definition.imageUrl, 'normal receipt falls back to the base URL')
H.ok(api.RemoveItem(1, 'card', 1), 'remove base remote item without explicit slot')
H.equal(receipts[#receipts].imageUrl, definition.imageUrl, 'removal falls back to the base URL')
H.ok(api.AddItem(1, 'card', 1, 1, { image = 'charizard.png' }), 'metadata filename over a base URL')
H.equal(receipts[#receipts].imageUrl, nil, 'metadata filename suppresses base URL in receipts')
H.equal(internal.view('player:1').items[1].imageUrl, nil, 'grid has the same filename priority')
H.ok(api.RemoveItem(1, 'card', 1), 'remove the overridden remote item')
H.equal(receipts[#receipts].imageUrl, nil, 'removal preserves filename priority over the base URL')
H.finish()
