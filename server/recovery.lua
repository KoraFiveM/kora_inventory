-- Inventory and core commit both sides with the receipt before publishing items.
local inventory, core = KoraInventory, KoraInventory.internal
local persistence = inventory.persistence

local function receipt(provider, operationKey)
    local result, err = Kora.sql.transactionChecked({ {
        query = 'SELECT * FROM `kora_inventory_recovery_operations` WHERE `provider`=? AND `operation_key`=? FOR UPDATE',
        values = { provider, operationKey },
    } })
    if not result or not result.success then return nil, err or result and result.message or 'Recovery storage is unavailable.' end
    return result.results[1][1] or false
end

local function activeToken(operation)
    local rows, err = exports.kora_core:getPlayerColumnOperations()
    if type(rows) ~= 'table' then return false, err or 'Player recovery locks are unavailable.' end
    for _, row in ipairs(rows) do
        if row.operationKey == operation then return row.token end
    end
end

local function finish(inv, row, token)
    local decoded, outcome = pcall(json.decode, row.receipt)
    local revision = tonumber(row.source_revision)
    if not decoded or type(outcome) ~= 'table' or not revision then return false, 'The recovery receipt requires repair.' end
    if token then
        local items = persistence.normaliseItems(row.destination_items)
        if not items then return false, 'The recovery receipt requires repair.' end
        local finished, err = exports.kora_core:finishPlayerColumnOperation(token, { [row.citizenid] = { inventory = items } })
        if not finished then return false, err end
    end
    if token or inv.durablePending then
        -- A restored stash may already contain later deposits. Only publish the
        -- source transition when this VM still holds its pre-commit revision.
        if inv.revision < revision then
            inv.items, inv.revision = {}, revision
            persistence.committed(inv)
            core.broadcast(inv.key)
        end
        inv.durablePending = nil
    end
    return true, outcome
end

local function claim(source, id, operationKey)
    local provider = GetInvokingResource() or GetCurrentResourceName()
    if type(id) ~= 'string' or type(operationKey) ~= 'string' or #operationKey < 1 or #operationKey > 128 then return false, 'Invalid recovery request.' end
    if not persistence.getStatus().ready or Config.kora_inventory.persistence.enabled == false then return false, 'Inventory persistence is unavailable.' end
    local _, inv = core.resolveInventory('stash:' .. id)
    local data = exports.kora_core:getPlayerData(source)
    if not inv or inv.policyOwner ~= provider or not data or type(data.citizenid) ~= 'string' then return false, 'Recovery is unavailable.' end
    local cid, operation = data.citizenid, 'recovery:' .. provider .. ':' .. operationKey
    local context = { key = 'kora_inventory:' .. provider .. ':' .. operationKey,
        fingerprint = json.encode({ provider, operationKey, id, cid }), citizenids = { cid } }
    return core.lock({ inv.key, core.playerKey(source) }, function()
        return persistence.withLock(inv.type, inv.id, function()
            local token, tokenErr = activeToken(operation)
            if token == false then return false, tokenErr end
            if token then
                inv.durablePending = true
                -- A provider reload can precede its old SQL worker acquiring
                -- the receipt lock. Join that worker before inspecting intent.
                local joined, joinErr = Kora.sql.awaitCheckedOperation(context.key, context.fingerprint)
                if not joined or joined.result and joined.result.code == 'indeterminate' then return false, joinErr or 'Recovery outcome is pending. Retry the same claim.' end
            end
            local row, lookupErr = receipt(provider, operationKey)
            if row == nil then return false, lookupErr end
            if row and (row.provider ~= provider or row.operation_key ~= operationKey or row.stash_id ~= id or row.citizenid ~= cid) then return false, 'Recovery key has different arguments.' end
            if row and row.status == 'complete' then return finish(inv, row, token) end
            if row and row.status ~= 'pending' then return false, 'The recovery receipt requires repair.' end
            if token then
                local aborted, err = exports.kora_core:abortPlayerColumnOperation(token)
                if not aborted then return false, err end
            end
            inv.durablePending = nil
            -- Recovery is a trusted provider operation that must remain usable
            -- after the recipient loses access to the original physical space.
            local accessInventory = inventory.copy(inv)
            accessInventory.coords, accessInventory.bucket = nil, nil
            local allowed, accessErr = core.canAccess(source, accessInventory, { recovery = true }, true)
            if not allowed then return false, accessErr end
            if not next(inv.items) then return false, 'Recovery storage is empty.' end
            local locked, code, lockErr = exports.kora_core:beginPlayerColumnOperation(operation, { cid }, { 'inventory' })
            if not locked then return false, lockErr or code end
            local function reject(message)
                local released, releaseErr = exports.kora_core:abortPlayerColumnOperation(locked)
                if not released then inv.durablePending = true; return false, releaseErr or 'Recovery lock release is pending. Retry the same claim.' end
                return false, message
            end
            data = exports.kora_core:getPlayerData(source)
            if not data or data.citizenid ~= cid then return reject('Your character changed. Try again.') end
            local destination = { items = inventory.copy(data.items or {}), slots = Config.kora_inventory.playerSlots, maxWeight = Config.kora_inventory.playerMaxWeight }
            local count = 0
            for _, item in pairs(inv.items) do
                local added, addErr = core.addSecondary(destination, item.name, item.amount, nil, item.info or item.metadata)
                if not added then return reject(addErr) end
                count = count + item.amount
            end
            local saved, saveErr = persistence.save(inv)
            if not saved then return reject(saveErr) end
            if not row then
                local created, createErr = Kora.sql.execute('INSERT IGNORE INTO `kora_inventory_recovery_operations` (`provider`,`operation_key`,`stash_id`,`citizenid`) VALUES (?,?,?,?)', { provider, operationKey, id, cid })
                if not created then return reject(createErr or 'Recovery intent could not be saved.') end
            end
            local revision = inv.revision + 1
            local outcome = { operationKey = operationKey, stashId = id, citizenid = cid, amount = count, completedAt = os.time() }
            local encodedItems, encodedReceipt = json.encode(destination.items), json.encode(outcome)
            inv.durablePending = true
            local result, transactionErr = Kora.sql.transactionChecked({
                { query = 'SELECT `operation_key` FROM `kora_inventory_recovery_operations` WHERE `provider`=? AND `operation_key`=? AND `stash_id`=? AND `citizenid`=? AND `status`=\'pending\' FOR UPDATE',
                    values = { provider, operationKey, id, cid }, expectedRows = 1, failureCode = 'conflict' },
                { query = 'UPDATE `kora_inventory_inventories` SET `items`=?,`revision`=? WHERE `inventory_type`=\'stash\' AND `inventory_id`=? AND `revision`=?',
                    values = { '{}', revision, id, inv.revision }, expectedRows = 1, failureCode = 'conflict' },
                { query = 'UPDATE `players` SET `inventory`=? WHERE `citizenid`=? AND `deleted_at` IS NULL',
                    values = { encodedItems, cid }, expectedRows = 1, failureCode = 'conflict' },
                { query = 'UPDATE `kora_inventory_recovery_operations` SET `status`=\'complete\',`destination_items`=?,`source_revision`=?,`receipt`=? WHERE `provider`=? AND `operation_key`=? AND `status`=\'pending\'',
                    values = { encodedItems, revision, encodedReceipt, provider, operationKey }, expectedRows = 1, failureCode = 'conflict' },
            }, context)
            if not result or result.code == 'indeterminate' then return false, transactionErr or 'Recovery outcome is pending. Retry the same claim.' end
            if not result.success then inv.durablePending = nil; return reject(result.message or 'Recovery could not be saved.') end
            return finish(inv, { citizenid = cid, destination_items = encodedItems, source_revision = revision, receipt = encodedReceipt }, locked)
        end)
    end)
end

exports('ClaimStash', claim)
exports('claimStash', claim)
