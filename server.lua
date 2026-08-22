-- qbinventory server authority. Player item writes intentionally go through
-- qbcore:setPath, preserving its dirty-column persistence and delta replication.

local C = Config.qbinventory
local I = QbInventory
local resource = GetCurrentResourceName()

local inventories, sessions, hooks, audit = {}, {}, {}, {}
local locks, nextHookId, nextDropId = {}, 1, 1
local ownPlayerWrites = {}

local function now() return GetGameTimer() end
local function key(kind, id) return ('%s:%s'):format(kind, tostring(id)) end
local function playerKey(src) return key('player', src) end
local function itemDef(name)
    local item = type(name) == 'string' and name:lower() or name
    return exports.qbcore:getShared('items', item) or exports.qbcore:getShared('weapons', item)
end
local function playerData(src) return exports.qbcore:getPlayerData(src) end
local function playerItems(src) return exports.qbcore:getPlayerData(src, { 'items' }) or {} end
local function emit(src, name, ...) TriggerClientEvent(name, src, ...) end

-- qbcore emits its inventory-change event synchronously from setPath. Mark
-- qbinventory-originated writes so the listener below does not produce partial
-- live patches or double-bump a transaction's revision.
local function playerSetPath(src, path, value)
    ownPlayerWrites[src] = (ownPlayerWrites[src] or 0) + 1
    local results = table.pack(exports.qbcore:setPath(src, path, value))
    ownPlayerWrites[src] = ownPlayerWrites[src] - 1
    if ownPlayerWrites[src] == 0 then ownPlayerWrites[src] = nil end
    return table.unpack(results, 1, results.n)
end

local function recordAudit(action, src, details)
    audit[#audit + 1] = { at = os.time(), action = action, source = src, details = I.copy(details or {}) }
    if #audit > C.auditLimit then table.remove(audit, 1) end
    TriggerEvent('qbinventory:server:audit', action, src, details)
end

local function buildItem(name, amount, slot, metadata)
    local def = itemDef(name)
    if not def then return nil, 'unknown item' end
    return {
        slot = slot, name = def.name or tostring(name):lower(), amount = amount, info = I.copy(metadata or {}),
        metadata = I.copy(metadata or {}), type = def.type or 'item', unique = def.unique or false,
        useable = def.useable or false, image = def.image, label = def.label or name,
        weight = def.weight or 0, shouldClose = def.shouldClose, description = def.description,
        created = os.time(),
    }
end

local function secondary(kind, id, opts)
    local k = key(kind, id)
    local inv = inventories[k]
    if inv then return inv end
    opts = opts or {}
    -- Hydrate qbinventory-owned storage only after the persistence bootstrap
    -- has completed. Player inventories are intentionally never read here.
    local persistence = I.persistence
    if persistence and persistence.getStatus and persistence.getStatus().ready then
        local restored, restoreErr = persistence.load(kind, id)
        if restored then
            restored.key = k
            -- Registration-time policy (especially a non-serialisable access
            -- callback) is authoritative over persisted descriptive state.
            for _, field in ipairs({ 'label', 'coords', 'distance', 'groups', 'owner', 'access', 'prices', 'currency' }) do
                if opts[field] ~= nil then restored[field] = I.copy(opts[field]) end
            end
            if opts.slots ~= nil then restored.slots = math.floor(tonumber(opts.slots) or restored.slots) end
            if opts.maxWeight ~= nil or opts.maxweight ~= nil then restored.maxWeight = tonumber(opts.maxWeight or opts.maxweight) or restored.maxWeight end
            inventories[k] = restored
            return restored, true
        elseif restoreErr then
            print(('^3[qbinventory]^7 could not restore %s: %s'):format(k, tostring(restoreErr)))
        end
    end
    inv = {
        key = k, id = id, type = kind, label = opts.label or tostring(id),
        slots = math.floor(tonumber(opts.slots) or C.defaultSlots),
        maxWeight = tonumber(opts.maxWeight or opts.maxweight) or C.defaultMaxWeight,
        items = I.copy(opts.items or {}), revision = 0, coords = opts.coords,
        distance = tonumber(opts.distance) or C.interactionDistance, groups = opts.groups,
        owner = opts.owner, temporary = opts.temporary == true, stock = opts.stock,
        prices = opts.prices, currency = opts.currency or 'money', access = opts.access,
    }
    inventories[k] = inv
    if persistence and persistence.markDirty then persistence.markDirty(inv) end
    return inv
end

local function getInventory(k)
    if type(k) ~= 'string' then return nil end
    local src = tonumber(k:match('^player:(%d+)$'))
    if src then
        local data = playerData(src)
        if not data then return nil end
        return {
            key = k, id = src, type = 'player', label = data.name or ('Player %d'):format(src),
            slots = C.playerSlots, maxWeight = C.playerMaxWeight, items = playerItems(src),
            revision = (inventories[k] and inventories[k].revision) or 0, source = src,
        }
    end
    return inventories[k]
end

local function revision(k)
    local inv = inventories[k]
    if not inv then inv = { key = k, revision = 0 }; inventories[k] = inv end
    return inv.revision or 0
end

local function bump(k)
    local inv = inventories[k]
    if not inv then inv = { key = k, revision = 0 }; inventories[k] = inv end
    inv.revision = (inv.revision or 0) + 1
    if inv.type and inv.type ~= 'player' and I.persistence and I.persistence.markDirty then
        I.persistence.markDirty(inv)
    end
    return inv.revision
end

local function groupAllowed(src, groups)
    if not groups then return true end
    local data = playerData(src)
    if not data then return false end
    local job, gang = data.job or {}, data.gang or {}
    for group, minimum in pairs(groups) do
        if group == job.name or group == gang.name then
            local grade = (job.name == group and job.grade or gang.grade) or {}
            local level = tonumber(grade.level) or 0
            if minimum == nil or level >= tonumber(minimum) then return true end
        end
    end
    return false
end

local function sameBucket(src, target)
    return not C.requireSameBucket or GetPlayerRoutingBucket(src) == GetPlayerRoutingBucket(target)
end

local function canAccess(src, inv)
    if not inv then return false, 'inventory not found' end
    if inv.type == 'player' then
        if inv.source == src then return true end
        if not sameBucket(src, inv.source) then return false, 'different routing bucket' end
        if not QB.distance.player(src, GetEntityCoords(GetPlayerPed(inv.source)), C.interactionDistance) then
            return false, 'too far away'
        end
        return true
    end
    if inv.owner then
        local data = playerData(src)
        if not data or (inv.owner ~= src and inv.owner ~= data.citizenid) then return false, 'not owner' end
    end
    if not groupAllowed(src, inv.groups) then return false, 'not authorised' end
    if inv.access then
        local ok, allowed = pcall(inv.access, src, inv)
        if not ok or not allowed then return false, 'access denied' end
    end
    if inv.coords and not QB.distance.player(src, inv.coords, inv.distance) then return false, 'too far away' end
    return true
end

local function view(k)
    local inv = getInventory(k)
    if not inv then return nil end
    return {
        id = inv.id, key = inv.key, type = inv.type, label = inv.label, slots = inv.slots,
        maxWeight = inv.maxWeight, weight = I.totalWeight(inv.items), revision = revision(k),
        items = I.copy(inv.items), stock = inv.stock and I.copy(inv.stock) or nil,
    }
end

local function patchView(k)
    return { key = k, revision = revision(k), inventory = view(k) }
end

local function broadcast(k)
    local update = patchView(k)
    for src, session in pairs(sessions) do
        if session.primary == k or session.secondary == k then
            emit(src, 'qbinventory:client:sessionPatched', session.token, update)
        end
    end
end

local function lock(keys, fn)
    table.sort(keys)
    for _, k in ipairs(keys) do if locks[k] then return false, 'inventory busy' end end
    for _, k in ipairs(keys) do locks[k] = true end
    local result = table.pack(xpcall(fn, debug.traceback))
    for _, k in ipairs(keys) do locks[k] = nil end
    if not result[1] then print(('^1[qbinventory]^7 transaction failed: %s'):format(result[2])); return false, 'transaction failed' end
    return table.unpack(result, 2, result.n)
end

local function addSecondary(inv, name, amount, slot, metadata)
    local item, err = buildItem(name, amount, slot, metadata)
    if not item then return false, err end
    local currentWeight = I.totalWeight(inv.items)
    if currentWeight + I.itemWeight(item) > inv.maxWeight then return false, 'over weight' end
    if item.unique and amount > 1 then
        local placed = {}
        for _ = 1, amount do
            local free = I.firstFreeSlot(inv.items, inv.slots)
            if not free then
                for _, used in ipairs(placed) do inv.items[used] = nil end
                return false, 'no free slot'
            end
            local one = I.copy(item); one.amount = 1; one.slot = free; inv.items[free] = one; placed[#placed + 1] = free
        end
        return true, placed[1]
    end
    local stack = slot and inv.items[slot] and inv.items[slot].name == name and slot or I.stackSlot(inv.items, item)
    if stack then
        inv.items[stack].amount = inv.items[stack].amount + amount
        return true, stack
    end
    slot = slot or I.firstFreeSlot(inv.items, inv.slots)
    if not slot or inv.items[slot] then return false, 'no free slot' end
    item.slot = slot
    inv.items[slot] = item
    return true, slot
end

local function removeSecondary(inv, slot, amount)
    local item = inv.items[slot]
    if not item then return false, 'empty slot' end
    amount = I.amount(amount, item.amount)
    if not amount or amount > item.amount then return false, 'not enough of item' end
    local removed = I.copy(item)
    removed.amount = amount
    if amount == item.amount then inv.items[slot] = nil else item.amount = item.amount - amount end
    return true, removed
end

local function addPlayer(src, name, amount, slot, metadata, reason)
    local items = playerItems(src)
    local item, err = buildItem(name, amount, slot, metadata)
    if not item then return false, err end
    if I.totalWeight(items) + I.itemWeight(item) > C.playerMaxWeight then return false, 'over weight' end
    if item.unique and amount > 1 then
        local placed = {}
        for _ = 1, amount do
            local free = I.firstFreeSlot(items, C.playerSlots)
            if not free then
                for _, used in ipairs(placed) do playerSetPath(src, { 'items', used }, nil) end
                return false, 'no free slot'
            end
            local one = I.copy(item); one.amount = 1; one.slot = free
            local ok, err = playerSetPath(src, { 'items', free }, one)
            if not ok then
                for _, used in ipairs(placed) do playerSetPath(src, { 'items', used }, nil) end
                return false, err
            end
            items[free] = one; placed[#placed + 1] = free
        end
        return true
    end
    local stack = slot and items[slot] and items[slot].name == name and slot or I.stackSlot(items, item)
    if stack then
        local nextItem = I.copy(items[stack]); nextItem.amount = nextItem.amount + amount
        return playerSetPath(src, { 'items', stack }, nextItem)
    end
    slot = slot or I.firstFreeSlot(items, C.playerSlots)
    if not slot or items[slot] then return false, 'no free slot' end
    item.slot = slot
    return playerSetPath(src, { 'items', slot }, item)
end

local function removePlayer(src, slot, amount)
    local items = playerItems(src)
    local item = items[slot]
    if not item then return false, 'empty slot' end
    amount = I.amount(amount, item.amount)
    if not amount or amount > item.amount then return false, 'not enough of item' end
    local removed = I.copy(item); removed.amount = amount
    if amount == item.amount then
        local ok, err = playerSetPath(src, { 'items', slot }, nil)
        return ok, err, removed
    end
    local nextItem = I.copy(item); nextItem.amount = nextItem.amount - amount
    local ok, err = playerSetPath(src, { 'items', slot }, nextItem)
    return ok, err, removed
end

local function addTo(k, name, amount, slot, metadata, reason)
    local inv = getInventory(k)
    if not inv then return false, 'inventory not found' end
    if inv.type == 'player' then return addPlayer(inv.source, name, amount, slot, metadata, reason) end
    return addSecondary(inv, name, amount, slot, metadata)
end

local function removeFrom(k, slot, amount)
    local inv = getInventory(k)
    if not inv then return false, 'inventory not found' end
    if inv.type == 'player' then return removePlayer(inv.source, slot, amount) end
    return removeSecondary(inv, slot, amount)
end

local function runHooks(name, src, payload)
    for _, hook in pairs(hooks[name] or {}) do
        local filter = hook.options or {}
        local match = (not filter.itemFilter or filter.itemFilter[payload.itemName])
            and (not filter.inventoryFilter or filter.inventoryFilter[payload.fromInventory] or filter.inventoryFilter[payload.toInventory])
            and (not filter.typeFilter or filter.typeFilter[payload.fromType] or filter.typeFilter[payload.toType])
        if match then
            local ok, result = pcall(hook.callback, payload)
            if not ok then print(('^3[qbinventory]^7 hook %d failed: %s'):format(hook.id, result))
            elseif result == false then return false, 'action denied by hook'
            elseif type(result) == 'table' then payload.metadata = result end
        end
    end
    return true
end

local function close(src, reason)
    local session = sessions[src]
    if not session then return false end
    sessions[src] = nil
    emit(src, 'qbinventory:client:sessionClosed', session.token, reason or 'closed')
    TriggerEvent('qbinventory:server:sessionClosed', src, session, reason or 'closed')
    return true
end

local function open(src, secondaryKey, opts)
    close(src, 'replaced')
    local primary = playerKey(src)
    local second = getInventory(secondaryKey)
    if not second then return false, 'inventory not found' end
    local ok, err = canAccess(src, second)
    if not ok then return false, err end
    local hookOK, hookErr = runHooks('openInventory', src, { inventoryId = secondaryKey, inventoryType = second.type })
    if not hookOK then return false, hookErr end
    local token = ('%s:%d:%d'):format(src, now(), math.random(100000, 999999))
    sessions[src] = { token = token, primary = primary, secondary = secondaryKey, expires = now() + C.sessionTtl }
    local payload = { token = token, primary = view(primary), secondary = view(secondaryKey), expires = sessions[src].expires }
    emit(src, 'qbinventory:client:sessionOpened', payload)
    TriggerEvent('qbinventory:server:sessionOpened', src, payload)
    return true, payload
end

-- A player opening their own inventory is a one-panel session. Treating the
-- primary player view as its own secondary would render it twice and would
-- accidentally make self-transfers look like cross-inventory operations.
local function openSelf(src)
    close(src, 'replaced')
    local primary = playerKey(src)
    if not getInventory(primary) then return false, 'player inventory not found' end
    local token = ('%s:%d:%d'):format(src, now(), math.random(100000, 999999))
    sessions[src] = { token = token, primary = primary, secondary = nil, expires = now() + C.sessionTtl }
    local payload = { token = token, primary = view(primary), secondary = nil, expires = sessions[src].expires }
    emit(src, 'qbinventory:client:sessionOpened', payload)
    TriggerEvent('qbinventory:server:sessionOpened', src, payload)
    return true, payload
end

local function validSession(src, token, fromKey, toKey, expectedFrom, expectedTo)
    local session = sessions[src]
    if not session or token ~= session.token then return nil, 'invalid session' end
    if now() > session.expires then close(src, 'expired'); return nil, 'session expired' end
    if (fromKey ~= session.primary and fromKey ~= session.secondary) or (toKey ~= session.primary and toKey ~= session.secondary) then
        return nil, 'inventory not in session'
    end
    local from, to = getInventory(fromKey), getInventory(toKey)
    local ok, err = canAccess(src, from); if not ok then close(src, err); return nil, err end
    ok, err = canAccess(src, to); if not ok then close(src, err); return nil, err end
    if expectedFrom ~= nil and tonumber(expectedFrom) ~= revision(fromKey) then return nil, 'stale source inventory' end
    if expectedTo ~= nil and tonumber(expectedTo) ~= revision(toKey) then return nil, 'stale target inventory' end
    return session, from, to
end

local function transfer(src, request)
    if type(request) ~= 'table' then return false, 'invalid request' end
    local fromKey, toKey = request.fromInventory, request.toInventory
    local _, from, to = validSession(src, request.token, fromKey, toKey, request.fromRevision, request.toRevision)
    if not from then return false, to end
    if from.type == 'shop' then return false, 'shop items must be purchased' end
    if to.type == 'shop' then return false, 'shop inventory is read only' end
    local fromSlot, toSlot = math.floor(tonumber(request.fromSlot) or 0), tonumber(request.toSlot)
    local item = from.items[fromSlot]
    local amount = I.amount(request.amount, item and item.amount)
    if not item or not amount or amount > item.amount then return false, 'invalid item amount' end
    if toSlot then toSlot = math.floor(toSlot); if toSlot < 1 or toSlot > to.slots then return false, 'invalid target slot' end end
    local payload = { action = 'swapItems', fromInventory = fromKey, toInventory = toKey, fromType = from.type,
        toType = to.type, fromSlot = fromSlot, toSlot = toSlot, itemName = item.name, count = amount, metadata = I.copy(item.info) }
    local hookOK, hookErr = runHooks('swapItems', src, payload)
    if not hookOK then recordAudit('transfer-rejected', src, { reason = hookErr, item = item.name }); return false, hookErr end
    return lock({ fromKey, toKey }, function()
        -- Revalidate inside the critical section; every external request carries revisions.
        local session, currentFrom, currentTo = validSession(src, request.token, fromKey, toKey, request.fromRevision, request.toRevision)
        if not session then return false, 'stale session' end
        local currentItem = currentFrom.items[fromSlot]
        if not currentItem then return false, 'source item changed' end
        if fromKey == toKey and toSlot == fromSlot then return true end
        local target = toSlot and currentTo.items[toSlot] or nil
        local stacks = target and target.name == currentItem.name and not target.unique and not currentItem.unique
            and I.sameInfo(target.info, currentItem.info)

        -- An occupied non-stack target is a true slot swap. Partial amounts
        -- cannot replace an unrelated occupied slot, and each side must still
        -- respect its own weight cap after the exchange.
        if target and not stacks then
            if amount ~= currentItem.amount then return false, 'cannot partially swap occupied slots' end
            if fromKey ~= toKey then
                local fromWeight = I.totalWeight(currentFrom.items) - I.itemWeight(currentItem) + I.itemWeight(target)
                local toWeight = I.totalWeight(currentTo.items) - I.itemWeight(target) + I.itemWeight(currentItem)
                if fromWeight > currentFrom.maxWeight or toWeight > currentTo.maxWeight then return false, 'over weight' end
            end
            local sourceOK, sourceErr, sourceItem = removeFrom(fromKey, fromSlot, currentItem.amount)
            if not sourceOK then return false, sourceErr end
            local targetOK, targetErr, targetItem = removeFrom(toKey, toSlot, target.amount)
            if not targetOK then
                addTo(fromKey, sourceItem.name, sourceItem.amount, fromSlot, sourceItem.info, 'swap-rollback')
                return false, targetErr
            end
            local placeSource, placeSourceErr = addTo(toKey, sourceItem.name, sourceItem.amount, toSlot, sourceItem.info, 'swap')
            if not placeSource then
                addTo(toKey, targetItem.name, targetItem.amount, toSlot, targetItem.info, 'swap-rollback')
                addTo(fromKey, sourceItem.name, sourceItem.amount, fromSlot, sourceItem.info, 'swap-rollback')
                return false, placeSourceErr
            end
            local placeTarget, placeTargetErr = addTo(fromKey, targetItem.name, targetItem.amount, fromSlot, targetItem.info, 'swap')
            if not placeTarget then
                removeFrom(toKey, toSlot, sourceItem.amount)
                addTo(toKey, targetItem.name, targetItem.amount, toSlot, targetItem.info, 'swap-rollback')
                addTo(fromKey, sourceItem.name, sourceItem.amount, fromSlot, sourceItem.info, 'swap-rollback')
                return false, placeTargetErr
            end
            bump(fromKey); if toKey ~= fromKey then bump(toKey) end
            broadcast(fromKey); if toKey ~= fromKey then broadcast(toKey) end
            recordAudit('swap', src, { from = fromKey, to = toKey, source = sourceItem.name, target = targetItem.name })
            TriggerEvent('qbinventory:server:itemsMoved', src, payload)
            return true, { fromRevision = revision(fromKey), toRevision = revision(toKey) }
        end
        local removedOK, removedErr, removed = removeFrom(fromKey, fromSlot, amount)
        if not removedOK then return false, removedErr end
        local addedOK, addedErr = addTo(toKey, removed.name, amount, toSlot, payload.metadata, 'transfer')
        if not addedOK then
            addTo(fromKey, removed.name, amount, fromSlot, removed.info, 'transfer-rollback')
            return false, addedErr
        end
        bump(fromKey); if toKey ~= fromKey then bump(toKey) end
        broadcast(fromKey); if toKey ~= fromKey then broadcast(toKey) end
        recordAudit('transfer', src, { from = fromKey, to = toKey, item = removed.name, amount = amount })
        TriggerEvent('qbinventory:server:itemsMoved', src, payload)
        return true, { fromRevision = revision(fromKey), toRevision = revision(toKey) }
    end)
end

-- UI actions are intentionally narrower than arbitrary exports. Each one
-- starts from the current server-issued session, derives every inventory key
-- from it, and checks the revision supplied by the client mirror.
local function intentUse(src, request)
    local session = sessions[src]
    if not session or type(request.payload) ~= 'table' then return false, 'invalid session action' end
    if request.payload.inventory and request.payload.inventory ~= session.primary then return false, 'items can only be used from your inventory' end
    local _, primary = validSession(src, request.token, session.primary, session.primary, request.primaryRevision, request.primaryRevision)
    if not primary then return false, 'stale inventory' end
    local slot = math.floor(tonumber(request.payload.slot) or 0)
    if slot < 1 or not primary.items[slot] then return false, 'invalid item slot' end
    local ok, err = useItem(src, slot)
    if not ok then return false, err or 'item cannot be used' end
    recordAudit('use', src, { item = primary.items[slot].name, slot = slot })
    return true
end

local function intentDrop(src, request)
    local session = sessions[src]
    if not session or type(request.payload) ~= 'table' then return false, 'invalid session action' end
    if request.payload.inventory and request.payload.inventory ~= session.primary then return false, 'items can only be dropped from your inventory' end
    local _, primary = validSession(src, request.token, session.primary, session.primary, request.primaryRevision, request.primaryRevision)
    if not primary then return false, 'stale inventory' end
    local slot = math.floor(tonumber(request.payload.slot) or 0)
    local item = primary.items[slot]
    local amount = I.amount(request.payload.amount, item and item.amount)
    if not item or not amount or amount > item.amount then return false, 'invalid item amount' end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false, 'player entity unavailable' end

    return lock({ session.primary }, function()
        local current = getInventory(session.primary)
        if not current or revision(session.primary) ~= tonumber(request.primaryRevision) then return false, 'stale inventory' end
        local removedOK, removedErr, removed = removePlayer(src, slot, amount)
        if not removedOK then return false, removedErr end
        removed.slot = 1
        local id = dropCreate(GetEntityCoords(ped), { [1] = removed })
        bump(session.primary)
        broadcast(session.primary)
        recordAudit('drop', src, { id = id, item = removed.name, amount = amount })
        return true, id
    end)
end

local function intentBuy(src, request)
    local session = sessions[src]
    if not session or type(request.payload) ~= 'table' then return false, 'invalid session action' end
    local shopKey = request.payload.inventory or request.payload.shopInventory or session.secondary
    if shopKey ~= session.secondary then return false, 'shop is not in this session' end
    local _, shop, player = validSession(src, request.token, shopKey, session.primary, request.secondaryRevision, request.primaryRevision)
    if not shop then return false, player end
    if shop.type ~= 'shop' then return false, 'secondary inventory is not a shop' end
    local slot = math.floor(tonumber(request.payload.slot) or 0)
    local count = I.amount(request.payload.amount, 1)
    local item = (shop.stock or shop.items)[slot]
    if not item or not count or item.amount < count then return false, 'out of stock' end
    local price = tonumber(item.price or (shop.prices and shop.prices[item.name])) or 0
    local hookOK, hookErr = runHooks('buyItem', src, { shopId = shop.id, itemName = item.name, count = count, totalPrice = price * count })
    if not hookOK then return false, hookErr end

    return lock({ shopKey, session.primary }, function()
        local _, currentShop, currentPlayer = validSession(src, request.token, shopKey, session.primary, request.secondaryRevision, request.primaryRevision)
        if not currentShop then return false, currentPlayer end
        local currentItem = (currentShop.stock or currentShop.items)[slot]
        if not currentItem or currentItem.amount < count then return false, 'out of stock' end
        if price > 0 then
            local paid, payErr = exports.qbcore:removeMoney(src, currentShop.currency == 'money' and 'cash' or currentShop.currency, price * count, 'qbinventory-shop')
            if not paid then return false, payErr end
        end
        local added, addErr = addPlayer(src, currentItem.name, count, nil, currentItem.info, 'purchase')
        if not added then
            if price > 0 then exports.qbcore:addMoney(src, currentShop.currency == 'money' and 'cash' or currentShop.currency, price * count, 'qbinventory-refund') end
            return false, addErr
        end
        currentItem.amount = currentItem.amount - count
        if currentItem.amount == 0 then currentShop.items[slot] = nil; if currentShop.stock then currentShop.stock[slot] = nil end end
        bump(shopKey); bump(session.primary)
        broadcast(shopKey); broadcast(session.primary)
        recordAudit('purchase', src, { shop = currentShop.id, item = currentItem.name, amount = count, price = price * count })
        return true
    end)
end

local function handleIntent(src, request)
    if type(request) ~= 'table' or type(request.action) ~= 'string' or type(request.token) ~= 'string' then return false, 'invalid request' end
    if request.action == 'use' then return intentUse(src, request) end
    if request.action == 'drop' then return intentDrop(src, request) end
    if request.action == 'buy' then return intentBuy(src, request) end
    return false, 'unsupported intent'
end

-- Public headless core -------------------------------------------------------

function getWeight(src)
    local inv = getInventory(playerKey(src)); return inv and I.totalWeight(inv.items) or 0, C.playerMaxWeight
end
function canCarry(src, name, amount)
    local def = itemDef(name); amount = I.amount(amount, 1)
    if not def or not amount then return false, 'unknown item' end
    local inv = getInventory(playerKey(src)); if not inv then return false, 'no such player' end
    local item = buildItem(name, amount, nil, {})
    if I.totalWeight(inv.items) + I.itemWeight(item) > inv.maxWeight then return false, 'over weight' end
    if def.unique then
        local free = 0
        for slot = 1, inv.slots do if not inv.items[slot] then free = free + 1 end end
        if free < amount then return false, 'no free slot' end
    elseif not I.stackSlot(inv.items, item) then
        if not I.firstFreeSlot(inv.items, inv.slots) then return false, 'no free slot' end
    end
    return true
end
function addItem(src, name, amount, slot, info, reason)
    local ok, err = canCarry(src, name, amount); if not ok then return false, err end
    local done, why = addPlayer(src, name, I.amount(amount, 1), slot, info, reason)
    if done then bump(playerKey(src)); broadcast(playerKey(src)); recordAudit('add', src, { item = name, amount = amount, reason = reason }) end
    return done, why
end
function removeItem(src, name, amount, slot, reason)
    local items = playerItems(src); amount = I.amount(amount, 1); if not amount then return false, 'invalid amount' end
    if slot then
        if not items[slot] or items[slot].name ~= name then return false, 'item not in slot' end
        local ok, err = removePlayer(src, slot, amount); if ok then bump(playerKey(src)); broadcast(playerKey(src)) end; return ok, err
    end
    local remaining, planned = amount, {}
    for s = 1, C.playerSlots do local item = items[s]; if item and item.name == name then planned[#planned + 1] = { slot = s, amount = math.min(remaining, item.amount) }; remaining = remaining - item.amount; if remaining <= 0 then break end end end
    if remaining > 0 then return false, 'not enough of item' end
    for _, part in ipairs(planned) do removePlayer(src, part.slot, part.amount) end
    bump(playerKey(src)); broadcast(playerKey(src)); recordAudit('remove', src, { item = name, amount = amount, reason = reason })
    return true
end
local function itemNameKey(name) return type(name) == 'string' and name:lower() or nil end
function getItemByName(src, name)
    local wanted = itemNameKey(name)
    if not wanted then return nil end
    for _, item in pairs(playerItems(src)) do if itemNameKey(item.name) == wanted then return item end end
end
function getItemsByName(src, name)
    local wanted, out = itemNameKey(name), {}
    if not wanted then return out end
    for _, item in pairs(playerItems(src)) do if itemNameKey(item.name) == wanted then out[#out + 1] = item end end
    return out
end
function getItemBySlot(src, slot) return playerItems(src)[slot] end
function getItemCount(src, names)
    local wanted, total = {}, 0
    if type(names) == 'string' then wanted[itemNameKey(names)] = true
    elseif type(names) == 'table' then
        for _, name in pairs(names) do
            local key = itemNameKey(name)
            if key then wanted[key] = true end
        end
    else return 0 end
    for _, item in pairs(playerItems(src)) do if wanted[itemNameKey(item.name)] then total = total + (tonumber(item.amount) or 0) end end
    return total
end
function hasItem(src, names, amount)
    if type(names) ~= 'table' then return getItemCount(src, names) >= (tonumber(amount) or 1) end
    local counts = {}
    for _, item in pairs(playerItems(src)) do
        local name = itemNameKey(item.name)
        counts[name] = (counts[name] or 0) + (tonumber(item.amount) or 0)
    end
    local isArray = #names > 0
    for key, value in pairs(names) do
        local name = itemNameKey(isArray and value or key)
        local required = isArray and (tonumber(amount) or 1) or (tonumber(value) or 1)
        if not name or (counts[name] or 0) < required then return false end
    end
    return true
end
function getFreeSlot(src) return I.firstFreeSlot(playerItems(src), C.playerSlots) end
function moveItem(src, fromSlot, toSlot, amount)
    local from = getItemBySlot(src, fromSlot); if not from then return false, 'empty source slot' end
    toSlot = math.floor(tonumber(toSlot) or 0)
    amount = I.amount(amount, from.amount)
    if toSlot < 1 or toSlot > C.playerSlots or not amount or amount > from.amount then return false, 'invalid move' end
    if fromSlot == toSlot then return true end
    local target = getItemBySlot(src, toSlot)
    if target and (target.name ~= from.name or target.unique or from.unique or not I.sameInfo(target.info, from.info)) then
        return false, 'destination occupied'
    end
    return lock({ playerKey(src) }, function()
        local removed, removeErr, moved = removePlayer(src, fromSlot, amount)
        if not removed then return false, removeErr end
        local added, addErr = addPlayer(src, moved.name, amount, toSlot, moved.info, 'move')
        if not added then addPlayer(src, moved.name, amount, fromSlot, moved.info, 'move-rollback'); return false, addErr end
        bump(playerKey(src)); broadcast(playerKey(src)); recordAudit('move', src, { fromSlot = fromSlot, toSlot = toSlot, amount = amount })
        return true
    end)
end
function clearInventory(src, keep)
    local keeps = {}
    if type(keep) == 'string' then keeps[itemNameKey(keep)] = true
    elseif type(keep) == 'table' then
        for key, value in pairs(keep) do keeps[itemNameKey(type(key) == 'number' and value or key)] = true end
    end
    for slot, item in pairs(playerItems(src)) do if not keeps[itemNameKey(item.name)] then playerSetPath(src, { 'items', slot }, nil) end end
    bump(playerKey(src)); broadcast(playerKey(src)); return true
end
function setItems(src, newItems)
    if type(newItems) ~= 'table' then return false, 'items must be a table' end
    local checked = {}
    for slot, item in pairs(newItems) do
        slot = tonumber(slot); local amount = item and I.amount(item.amount, 1)
        if not slot or slot < 1 or slot > C.playerSlots or not item or not itemDef(item.name) or not amount then return false, 'invalid item table' end
        local built = buildItem(item.name, amount, slot, item.info or item.metadata); checked[slot] = built
    end
    playerSetPath(src, { 'items' }, checked); bump(playerKey(src)); broadcast(playerKey(src)); return true
end

local useables, useableOwners = {}, QB.resources.serverRegistry(function(name) useables[name] = nil end)
function createUseable(name, handler)
    assert(type(name) == 'string' and type(handler) == 'function', 'name and handler are required')
    local owner = GetInvokingResource() or resource; useables[name] = handler; useableOwners.track(owner, name)
end
function useItem(src, slotOrName)
    local item = type(slotOrName) == 'number' and getItemBySlot(src, slotOrName) or getItemByName(src, slotOrName)
    if not item then return false, 'item not found' end
    local allowed, err = runHooks('usingItem', src, { itemName = item.name, item = I.copy(item), inventoryId = playerKey(src), inventoryType = 'player' })
    if not allowed then return false, err end
    local handler = useables[item.name]
    if handler then local ok, result = pcall(handler, src, I.copy(item)); if not ok then return false, result end; TriggerEvent('qbinventory:server:usedItem', src, item.name, item); return result ~= false end
    TriggerEvent('QBCore:Server:UseItem', src, item); return false, 'no useable registered'
end

function stashGet(identifier) local inv = secondary('stash', identifier); return I.copy(inv.items) end
function stashSet(identifier, items) local inv = secondary('stash', identifier); inv.items = I.copy(items or {}); bump(inv.key); broadcast(inv.key); return true end
function stashOpen(src, identifier, opts) local inv = secondary('stash', identifier, opts); return open(src, inv.key, opts) end
function dropCreate(coords, items)
    local id = nextDropId; nextDropId = nextDropId + 1
    local inv = secondary('drop', id, { label = 'Ground drop', coords = coords, distance = C.dropDistance, slots = C.defaultSlots, items = items, temporary = true })
    TriggerClientEvent('qbinventory:client:dropCreated', -1, id, coords); return id
end
function dropTake(src, id, slot, amount)
    local inv = getInventory(key('drop', id)); if not inv then return false, 'no such drop' end
    local ok, payload = open(src, inv.key); if not ok then return false, payload end
    local s = sessions[src]
    local result, err = transfer(src, { token = s.token, fromInventory = inv.key, toInventory = playerKey(src), fromSlot = slot, amount = amount, fromRevision = revision(inv.key), toRevision = revision(playerKey(src)) })
    if result and not next(inv.items) then
        if I.persistence and I.persistence.delete then I.persistence.delete(inv.type, inv.id) end
        inventories[inv.key] = nil
        TriggerClientEvent('qbinventory:client:dropRemoved', -1, id)
        close(src, 'drop empty')
    end
    return result, err
end

-- Ox-style inventory constructors and shops.
function registerStash(id, label, slots, maxWeight, owner, groups, coords)
    local inv = secondary('stash', id, { label = label, slots = slots, maxWeight = maxWeight, owner = owner, groups = groups, coords = coords }); return inv.key
end
function createTemporaryStash(properties) properties = properties or {}; properties.temporary = true; local inv = secondary('temporary', properties.id or ('tmp-%d'):format(now()), properties); return inv.key end
function registerShop(id, data)
    data = data or {}
    local inv, restored = secondary('shop', id, data)
    if not restored then
        inv.stock = I.copy(data.inventory or data.items or {})
        inv.items = inv.stock -- a shop is rendered as an inventory; stock is its authoritative slot table.
    else
        inv.stock = inv.stock or inv.items
    end
    inv.prices = data.prices or inv.prices or {}
    if I.persistence and I.persistence.markDirty then I.persistence.markDirty(inv) end
    return inv.key
end
function openInventory(src, invType, data)
    local k
    if invType == 'player' then
        local target = tonumber(data) or src
        if target == src then return openSelf(src) end
        k = playerKey(target)
    elseif type(data) == 'table' and data.key then k = data.key
    else k = key(invType, type(data) == 'table' and data.id or data) end
    return open(src, k, type(data) == 'table' and data or nil)
end
function closeInventory(src) return close(src, 'requested') end
function openQbInventory(src, identifier, opts)
    if type(opts) == 'table' and opts.type then return openInventory(src, opts.type, opts) end
    return stashOpen(src, identifier, opts)
end

function buyItem(src, shopId, slot, count)
    local shop = getInventory(key('shop', shopId)); if not shop then return false, 'shop not found' end
    local ok, opened = open(src, shop.key); if not ok then return false, opened end
    local item = (shop.stock or shop.items)[slot]; count = I.amount(count, 1)
    if not item or not count or item.amount < count then return false, 'out of stock' end
    local price = tonumber(item.price or (shop.prices and shop.prices[item.name])) or 0
    local hookOK, hookErr = runHooks('buyItem', src, { shopId = shopId, itemName = item.name, count = count, totalPrice = price * count })
    if not hookOK then return false, hookErr end
    return lock({ shop.key, playerKey(src) }, function()
        if price > 0 then
            local paid, payErr = exports.qbcore:removeMoney(src, shop.currency == 'money' and 'cash' or shop.currency, price * count, 'qbinventory-shop')
            if not paid then return false, payErr end
        end
        local added, addErr = addPlayer(src, item.name, count, nil, item.info)
        if not added then if price > 0 then exports.qbcore:addMoney(src, shop.currency == 'money' and 'cash' or shop.currency, price * count, 'qbinventory-refund') end; return false, addErr end
        item.amount = item.amount - count; if item.amount == 0 then shop.stock[slot] = nil end
        bump(shop.key); bump(playerKey(src)); broadcast(shop.key); broadcast(playerKey(src)); recordAudit('purchase', src, { shop = shopId, item = item.name, amount = count, price = price * count })
        return true
    end)
end

function registerHook(eventName, callback, options)
    assert(type(eventName) == 'string' and type(callback) == 'function', 'eventName and callback are required')
    hooks[eventName] = hooks[eventName] or {}
    local id = nextHookId; nextHookId = nextHookId + 1
    hooks[eventName][id] = { id = id, callback = callback, options = options or {}, owner = GetInvokingResource() or resource }
    return id
end
function removeHooks(id) for _, list in pairs(hooks) do list[id] = nil end end

-- Compatibility aliases. The matching __cfx handlers below make these callable
-- through the qb-inventory and ox_inventory provided identities as well.
local api = {
    getWeight = getWeight, canCarry = canCarry, addItem = addItem, removeItem = removeItem,
    getItemByName = getItemByName, getItemsByName = getItemsByName, getItemBySlot = getItemBySlot,
    getItemCount = getItemCount, hasItem = hasItem, getFreeSlot = getFreeSlot, moveItem = moveItem,
    clearInventory = clearInventory, setItems = setItems, createUseable = createUseable, useItem = useItem,
    stashGet = stashGet, stashSet = stashSet, stashOpen = stashOpen, dropCreate = dropCreate, dropTake = dropTake,
    AddItem = addItem, RemoveItem = removeItem, GetItemByName = getItemByName, GetItemsByName = getItemsByName,
    GetItemBySlot = getItemBySlot, GetItemCount = getItemCount, HasItem = hasItem, GetFreeSlot = getFreeSlot,
    CanAddItem = canCarry, GetFreeWeight = function(src) local w, m = getWeight(src); return m - w end,
    ClearInventory = clearInventory, SetInventory = setItems, CreateUsableItem = createUseable,
    OpenInventory = openQbInventory, CloseInventory = closeInventory, GetInventory = function(src) return playerItems(src) end,
    GetStashItems = stashGet, SetStashItems = stashSet, RegisterStash = registerStash,
    CreateTemporaryStash = createTemporaryStash, RegisterShop = registerShop, BuyItem = buyItem,
    RegisterHook = registerHook, RemoveHooks = removeHooks,
}
for name, fn in pairs(api) do exports(name, fn) end
for _, identity in ipairs({ 'qb-inventory', 'ox_inventory' }) do
    for name, fn in pairs(api) do
        AddEventHandler(('__cfx_export_%s_%s'):format(identity, name), function(setCB) setCB(fn) end)
    end
end

RegisterNetEvent('qbinventory:server:open', function(invType, data)
    local ok, result = openInventory(source, invType, data)
    if not ok then emit(source, 'qbinventory:client:rejected', result) end
end)
RegisterNetEvent('qbinventory:server:close', function(token) if sessions[source] and sessions[source].token == token then close(source, 'requested') end end)
RegisterNetEvent('qbinventory:server:transfer', function(request)
    local ok, result = transfer(source, request)
    if not ok then emit(source, 'qbinventory:client:rejected', result) end
end)
RegisterNetEvent('qbinventory:server:intent', function(request)
    local ok, result = handleIntent(source, request)
    if not ok then emit(source, 'qbinventory:client:rejected', result) end
end)
QB.callback.register('qbinventory:server:open', function(src, invType, data)
    return openInventory(src, invType, data)
end)
QB.callback.register('qbinventory:server:transfer', function(src, request)
    return transfer(src, request)
end)
QB.callback.register('qbinventory:server:intent', function(src, request)
    return handleIntent(src, request)
end)
-- Legacy hotbar event: never trust the transmitted item record. The only
-- accepted slot is resolved again from qbcore-owned PlayerData before use.
RegisterNetEvent('QBCore:Server:UseItem', function(item)
    if type(item) ~= 'table' then return end
    local slot = math.floor(tonumber(item.slot) or 0)
    local owned = slot > 0 and getItemBySlot(source, slot) or nil
    if owned and owned.name == item.name then useItem(source, slot) end
end)

-- Persistence is deliberately a secondary-store concern. Hydrating happens
-- only after its qbsql migration succeeds; malformed rows remain quarantined
-- by that module instead of being silently loaded into live state.
AddEventHandler('qbinventory:server:persistenceReady', function()
    local persistence = I.persistence
    if not persistence or not persistence.restoreAll then return end
    local restored, rejected = persistence.restoreAll()
    if not restored then
        print(('^1[qbinventory]^7 secondary inventory restore failed: %s'):format(tostring(rejected)))
        return
    end
    for _, inv in ipairs(restored) do
        inv.key = key(inv.type, inv.id)
        inventories[inv.key] = inv
    end
    for _, bad in ipairs(rejected or {}) do
        print(('^3[qbinventory]^7 ignored malformed persisted %s:%s (%s)'):format(bad.type, bad.id, bad.reason))
        TriggerEvent('qbinventory:server:persistenceRejected', I.copy(bad))
    end
    print(('^2[qbinventory]^7 restored %d secondary inventories.'):format(#restored))
end)

-- Writes made by another server resource through qbcore's public mutation
-- funnel remain qbcore-owned. We only advance the session revision and push a
-- replacement view, so an open shared panel cannot overwrite that change.
AddEventHandler('qbcore:server:inventoryChanged', function(src)
    if ownPlayerWrites[src] then return end
    if not getInventory(playerKey(src)) then return end
    bump(playerKey(src))
    broadcast(playerKey(src))
end)

AddEventHandler('playerDropped', function() close(source, 'disconnected') end)
AddEventHandler('onResourceStop', function(name)
    if name == resource then for src in pairs(sessions) do close(src, 'resource stopped') end end
    for eventName, list in pairs(hooks) do for id, hook in pairs(list) do if hook.owner == name then list[id] = nil end end end
end)

CreateThread(function()
    while true do
        Wait(5000)
        for src, session in pairs(sessions) do if now() > session.expires then close(src, 'expired') end end
    end
end)
