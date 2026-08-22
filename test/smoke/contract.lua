local H = dofile('test/harness.lua')
local file = assert(io.open('server.lua', 'r'))
local source = file:read('*a')
file:close()

for _, exportName in ipairs({
    'getWeight', 'canCarry', 'addItem', 'removeItem', 'getItemByName',
    'getItemsByName', 'getItemBySlot', 'getItemCount', 'hasItem', 'getFreeSlot',
    'moveItem', 'clearInventory', 'setItems', 'createUseable', 'useItem',
    'stashGet', 'stashSet', 'stashOpen', 'dropCreate', 'dropTake',
}) do
    H.ok(source:find(exportName .. ' = ' .. exportName, 1, true), 'gateway export ' .. exportName)
end
H.ok(source:find("'qb%-inventory'"), 'qb compatibility identity')
H.ok(source:find("'ox_inventory'"), 'ox compatibility identity')
H.ok(source:find("'qbinventory:server:transfer'", 1, true), 'transfer transport')
H.ok(not source:find('SendNUIMessage', 1, true), 'server remains headless')
H.finish()
