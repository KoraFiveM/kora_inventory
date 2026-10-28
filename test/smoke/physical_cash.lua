local H = dofile('test/harness.lua')

local function read(path)
    local file = assert(io.open(path, 'r'))
    local source = file:read('*a')
    file:close()
    return source
end

local config = read('config.lua')
local server = read('server.lua')

H.ok(config:find('cash = {', 1, true), 'physical cash is an explicit inventory policy')
H.ok(config:find('asItem = false', config:find('cash = {', 1, true), true), 'physical cash defaults off')
H.ok(server:find("GetInvokingResource() ~= 'kora_core'", 1, true), 'only qbcore can mutate physical cash through bridge exports')
H.ok(server:find("return exports.kora_core:addMoney", 1, true), 'legacy AddItem cash routes through qbcore money authority')
H.ok(server:find("return exports.kora_core:removeMoney", 1, true), 'legacy RemoveItem cash routes through qbcore money authority')
H.ok(server:find("SetInventory is unavailable while cash is an item", 1, true), 'whole inventory replacements cannot mint or burn physical cash')
H.ok(server:find("keeps[cashPolicy().item] = true", 1, true), 'clear inventory cannot destroy physical cash')
H.ok(server:find("physical cash cannot be shop stock", 1, true), 'shops cannot mint physical cash')
H.ok(server:find("physicalCashTransfer = physicalCashTransfer", 1, true), 'qbcore has an atomic physical cash transfer path')
H.finish()
