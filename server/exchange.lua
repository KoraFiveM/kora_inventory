-- Server-only item/cash/reputation exchanges. Domain resources validate the
-- gameplay; inventory owns planning, capacity, the durable player fence and
-- one atomic receipt. A failed/unknown commit never permits a second payout.
local inventory, internal = KoraInventory, KoraInventory.internal
local busy = {}
local prefix = 'exchange:'

local function caller()
    local name = GetInvokingResource()
    if name and #name <= 64 and not name:find(':', 1, true) and Config.kora_inventory.exchangeCallers[name] == true then return name end
end

local function integer(value, min, max)
    return type(value) == 'number' and value == value and value % 1 == 0 and value >= min and value <= max
end

local function canonical(value, depth)
    if depth > 12 then error('Exchange metadata is too deep.') end
    if type(value) ~= 'table' then
        if type(value) ~= 'string' and type(value) ~= 'boolean' and type(value) ~= 'number' then error('Invalid exchange metadata.') end
        if type(value) == 'number' and (value ~= value or math.abs(value) == math.huge) then error('Invalid metadata number.') end
        return json.encode(value)
    end
    local keys, parts = {}, {}
    for key in pairs(value) do
        if type(key) ~= 'string' and type(key) ~= 'number' then error('Invalid metadata key.') end
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a,b) return type(a) .. tostring(a) < type(b) .. tostring(b) end)
    for _, key in ipairs(keys) do parts[#parts + 1] = json.encode(type(key) .. ':' .. tostring(key)) .. ':' .. canonical(value[key], depth + 1) end
    return '{' .. table.concat(parts, ',') .. '}'
end

local function entries(input, output)
    if input == nil then return {} end
    if type(input) ~= 'table' or #input > 32 then return nil end
    local result, count = {}, 0
    for index, entry in pairs(input) do
        if not integer(index, 1, #input) or type(entry) ~= 'table' or type(entry.name) ~= 'string'
            or #entry.name < 1 or #entry.name > 100 or not integer(entry.amount, 1, 1000000000)
            or entry.info ~= nil and (not output or type(entry.info) ~= 'table') then return nil end
        for key in pairs(entry) do if key ~= 'name' and key ~= 'amount' and key ~= 'info' then return nil end end
        result[index] = { name = entry.name:lower(), amount = entry.amount, info = output and inventory.copy(entry.info or {}) or nil }
        count = count + 1
    end
    return count == #input and result or nil
end

local function request(value)
    if type(value) ~= 'table' or type(value.citizenid) ~= 'string' or #value.citizenid < 1 or #value.citizenid > 50 then return nil end
    local allowed = { citizenid = true, take = true, give = true, cash = true, dealerRep = true, reason = true }
    for key in pairs(value) do if not allowed[key] then return nil end end
    local take, give = entries(value.take, false), entries(value.give, true)
    local cash, rep = value.cash or 0, value.dealerRep or 0
    if not take or not give or not integer(cash, 0, 1000000000) or not integer(rep, -1000000, 1000000)
        or value.reason ~= nil and (type(value.reason) ~= 'string' or #value.reason > 120) then return nil end
    if #take == 0 and #give == 0 and cash == 0 and rep == 0 then return nil end
    return { citizenid = value.citizenid, take = take, give = give, cash = cash, dealerRep = rep, reason = value.reason or 'Domain exchange' }
end

local function keyValid(key) return type(key) == 'string' and #key > 0 and #key <= 128 end
local function identity(provider, key) return prefix .. provider .. ':' .. key end
local function decode(value)
    local ok, result = pcall(json.decode, value or '')
    return ok and type(result) == 'table' and result or nil
end

local function tokens()
    return exports.kora_core:getPlayerColumnOperations()
end

local function findToken(operation)
    for _, row in ipairs(tokens()) do if row.operationKey == operation then return row.token end end
end

-- Join an earlier worker before the locking read; read-primary is necessary
-- here because replica lag must never look like a rolled-back operation.
local function reconcile(provider, key, fingerprint)
    local operation = identity(provider, key)
    local settled, waitError = Kora.sql.awaitCheckedOperation('kora_inventory:' .. operation, fingerprint)
    if not settled then return nil, 'pending', waitError end
    if settled.active and settled.result and settled.result.code == 'indeterminate' then
        return nil, 'pending', 'An earlier exchange worker must settle before receipt reconciliation.'
    end
    local result, readError = Kora.sql.transactionChecked({ {
        query = 'SELECT * FROM `kora_inventory_player_exchanges` WHERE `provider`=? AND `operation_key`=? FOR UPDATE',
        values = { provider, key },
    } })
    if not result or not result.success then return nil, 'pending', readError or 'Exchange receipt is unavailable.' end
    local row = result.results[1][1]
    if row and (row.provider ~= provider or row.operation_key ~= key or fingerprint and row.request ~= fingerprint) then
        return nil, 'conflict', 'Exchange key has different terms or recipient.'
    end
    local token = findToken(operation)
    if not row then
        if token then
            local released, err = exports.kora_core:abortPlayerColumnOperation(token)
            if not released then return nil, 'pending', err end
        end
        return nil, 'not_found'
    end
    local receipt, values = decode(row.receipt), decode(row.player_values)
    if not receipt or not values or receipt.citizenid ~= row.citizenid then return nil, 'pending', 'Exchange receipt requires repair.' end
    if token then
        -- Sparse JSON inventory slot maps must be numeric when republished.
        local items = inventory.persistence.normaliseItems(values.inventory)
        if not items then return nil, 'pending', 'Exchange inventory receipt requires repair.' end
        values.inventory = items
        local finished, err = exports.kora_core:finishPlayerColumnOperation(token, { [row.citizenid] = values })
        if not finished then return nil, 'pending', err end
    end
    return receipt
end

local function plan(data, terms)
    local draft = { items = inventory.copy(data.items or {}), slots = Config.kora_inventory.playerSlots, maxWeight = Config.kora_inventory.playerMaxWeight }
    local physical = exports.kora_core:isPhysicalCash('cash')
    local cash = Config.kora_inventory.cash
    if physical and (not cash or not cash.asItem or cash.account ~= 'cash' or not internal.itemDef(cash.item)) then return nil, 'Physical cash policy is unavailable.' end
    for _, entry in ipairs(terms.take) do
        if physical and entry.name == cash.item then return nil, 'Use the cash field for physical currency.' end
        local remaining = entry.amount
        for slot = 1, draft.slots do
            local item = draft.items[slot]
            if item and item.name == entry.name then
                local amount = math.min(item.amount, remaining)
                item.amount, remaining = item.amount - amount, remaining - amount
                if item.amount == 0 then draft.items[slot] = nil end
                if remaining == 0 then break end
            end
        end
        if remaining > 0 then return nil, 'Insufficient exchange items.' end
    end
    for _, entry in ipairs(terms.give) do
        local def = internal.itemDef(entry.name)
        if not def or def.type == 'weapon' or physical and entry.name == cash.item then return nil, 'Unsupported exchange item.' end
        local added, err = internal.addSecondary(draft, entry.name, entry.amount, nil, entry.info)
        if not added then return nil, err end
    end
    local money = inventory.copy(data.money or {})
    if terms.cash > 0 then
        if exports.kora_core:getTransactionTax(terms.cash, 'cash', 'add') > 0 then return nil, 'Durable exchanges require transaction tax to be disabled for cash rewards.' end
        if physical then
            if money.cash ~= 0 then return nil, 'Physical cash migration is incomplete.' end
            local added, err = internal.addSecondary(draft, cash.item, terms.cash, nil, {})
            if not added then return nil, err end
        else
            if not integer(money.cash or 0, 0, 9007199254740991 - terms.cash) then return nil, 'Invalid cash balance.' end
            money.cash = (money.cash or 0) + terms.cash
        end
    end
    local metadata = inventory.copy(data.metadata or {})
    if terms.dealerRep ~= 0 then
        if metadata.rep ~= nil and type(metadata.rep) ~= 'table' then return nil, 'Invalid reputation data.' end
        metadata.rep = metadata.rep or {}
        local current = metadata.rep.dealer or 0
        if not integer(current, 0, 9007199254740991 - math.max(terms.dealerRep, 0)) then return nil, 'Invalid dealer reputation.' end
        metadata.rep.dealer = math.max(0, current + terms.dealerRep)
    end
    return { inventory = draft.items, money = money, metadata = metadata }
end

local function execute(provider, source, key, terms, fingerprint)
    local existing, code, err = reconcile(provider, key, fingerprint)
    if existing or code ~= 'not_found' then return existing, code, err end
    if not inventory.persistence.getStatus().ready then return nil, 'unavailable', 'Inventory storage is not ready.' end
    local data = exports.kora_core:getPlayerData(source)
    if not data or data.citizenid ~= terms.citizenid then return nil, 'rejected', 'The exchange recipient is not this character.' end
    local operation = identity(provider, key)
    local token, lockCode, lockError = exports.kora_core:beginPlayerColumnOperation(operation, { terms.citizenid }, { 'inventory', 'money', 'metadata' })
    if not token then return nil, lockCode, lockError end
    local function reject(message)
        local released, releaseError = exports.kora_core:abortPlayerColumnOperation(token)
        return nil, released and 'rejected' or 'pending', releaseError or message
    end
    data = exports.kora_core:getPlayerData(source)
    if not data or data.citizenid ~= terms.citizenid then return reject('The exchange recipient changed.') end
    local values, planError = plan(data, terms)
    if not values then return reject(planError) end
    local receipt = { provider = provider, operationKey = key, citizenid = terms.citizenid,
        cash = terms.cash, dealerRep = terms.dealerRep, request = fingerprint, completedAt = os.time() }
    local result, commitError = Kora.sql.transactionChecked({
        { query = [[INSERT INTO `kora_inventory_player_exchanges`
            (`provider`,`operation_key`,`citizenid`,`request`,`player_values`,`receipt`) VALUES (?,?,?,?,?,?)]],
            values = { provider, key, terms.citizenid, fingerprint, json.encode(values), json.encode(receipt) }, expectedRows = 1 },
        { query = 'UPDATE `players` SET `inventory`=?,`money`=?,`metadata`=? WHERE `citizenid`=? AND `deleted_at` IS NULL',
            values = { json.encode(values.inventory), json.encode(values.money), json.encode(values.metadata), terms.citizenid }, expectedRows = 1, failureCode = 'conflict' },
    }, { key = 'kora_inventory:' .. operation, fingerprint = fingerprint, citizenids = { terms.citizenid } })
    if not result or result.code == 'indeterminate' then return nil, 'pending', commitError or 'Exchange outcome needs reconciliation. Retry the same key.' end
    if not result.success then
        local found, foundCode, foundError = reconcile(provider, key, fingerprint)
        if found or foundCode ~= 'not_found' then return found, foundCode, foundError end
        return nil, result.code or 'rejected', result.message or 'Exchange was rolled back.'
    end
    return reconcile(provider, key, fingerprint)
end

local function guarded(provider, key, handler)
    local operation = identity(provider, key)
    if busy[operation] then return nil, 'pending', 'Exchange is already running.' end
    busy[operation] = true
    local result = table.pack(pcall(handler))
    busy[operation] = nil
    if not result[1] then return nil, 'pending', 'Exchange needs durable reconciliation.' end
    return table.unpack(result, 2, result.n)
end

exports('ExecutePlayerExchange', function(source, key, input)
    local provider = caller()
    if not provider or not keyValid(key) or not integer(source, 1, 65535) then return nil, 'rejected', 'Invalid or unauthorized exchange.' end
    local valid, terms = pcall(request, input)
    if not valid or not terms then return nil, 'rejected', 'Invalid exchange request.' end
    local encoded, fingerprint = pcall(canonical, terms, 0)
    if not encoded or #fingerprint > 65536 then return nil, 'rejected', 'Invalid or oversized exchange request.' end
    return guarded(provider, key, function()
        local result = table.pack(internal.lock({ internal.playerKey(source) }, function() return execute(provider, source, key, terms, fingerprint) end))
        if result[1] == false then return nil, 'pending', result[2] end
        return table.unpack(result, 1, result.n)
    end)
end)

exports('GetPlayerExchange', function(key)
    local provider = caller()
    if not provider or not keyValid(key) then return nil, 'rejected', 'Invalid or unauthorized exchange.' end
    return guarded(provider, key, function() return reconcile(provider, key) end)
end)

-- Recover the existing core-owned fences even when the gameplay provider has
-- stopped or the recipient is offline. Receipts survive both resource restarts.
CreateThread(function()
    while true do
        if inventory.persistence.getStatus().ready then
            pcall(function()
                for _, operation in ipairs(tokens()) do
                    local provider, key = operation.operationKey:match('^exchange:([^:]+):(.+)$')
                    if provider and not operation.preparing then guarded(provider, key, function() return reconcile(provider, key) end) end
                end
            end)
        end
        Wait(30000)
    end
end)
