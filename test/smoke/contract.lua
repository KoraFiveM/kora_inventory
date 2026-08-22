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
H.ok(not source:find("provide 'qb-inventory'", 1, true), 'does not advertise incomplete qb provider identity')
H.ok(not source:find("provide 'ox_inventory'", 1, true), 'does not advertise incomplete ox provider identity')
H.ok(source:find("'qbinventory:server:transfer'", 1, true), 'transfer transport')
H.ok(source:find("'qbinventory:server:intent'", 1, true), 'restricted UI intent transport')
H.ok(source:find("shop items must be purchased", 1, true), 'shop cannot use generic transfer')
H.ok(not source:find("inventory:server:SetInventoryData", 1, true), 'no client-authorised full inventory replacement')
H.ok(not source:find('SendNUIMessage', 1, true), 'server remains headless')
H.finish()
