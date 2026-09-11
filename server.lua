-- qbinventory server authority. Player item writes intentionally go through
-- qbcore:setPath, preserving its dirty-column persistence and delta replication.

local config = Config.qbinventory
local inventory = QbInventory
local resourceName = GetCurrentResourceName()

-- Runtime state -------------------------------------------------------------

local inventories = {}
local sessions = {}
local hooks = {}
local audit = {}
local locks = {}
local ownPlayerWrites = {}
local inspectionHooks = {}
local ownedStashTemplates = {}

local nextHookId = 1
local nextDropId = 1
local nextInspectionHookId = 1

-- stashSet is declared before the shared write funnel below. Forward-declare
-- it so the closure captures this local rather than resolving a nonexistent
-- global when a resource calls SetStashItems during startup.
local setInventoryItems
local canCarry
local hasUseable
local useItem
local dropCreate
-- `owner = true` registrations are templates, not one globally shared stash.
-- The actual secondary record is created lazily per citizen when they open it.

-- Framework adapters --------------------------------------------------------

local function now()
    return GetGameTimer()
end
local function key(kind, id)
    return ('%s:%s'):format(kind, tostring(id))
end
local function playerKey(src)
    return key('player', src)
end
local function itemDef(name)
    local item = type(name) == 'string' and name:lower() or name
    return exports.qbcore:getShared('items', item) or exports.qbcore:getShared('weapons', item)
end
local function playerData(src)
    return exports.qbcore:getPlayerData(src)
end
local function playerItems(src)
    return exports.qbcore:getPlayerData(src, { 'items' }) or {}
end
-- Physical cash policy ------------------------------------------------------

-- This policy is intentionally server-only. Cash item operations are never
-- exposed to a browser or trusted from a resource-provided item payload.
local cashItemsActive = false
local function cashPolicy()
    local policy = config.cash
    if type(policy) ~= 'table' or policy.asItem ~= true then
        return nil
    end
    local item = type(policy.item) == 'string' and policy.item:lower() or nil
    local account = type(policy.account) == 'string' and policy.account:lower() or nil
    if not item or item == '' or not account or account == '' then
        return nil
    end
    local def = itemDef(item)
    if not def or def.unique then
        return nil
    end
    return { item = item, account = account }
end
local function isCashItemName(name)
    local policy = cashPolicy()
    return policy and type(name) == 'string' and name:lower() == policy.item
end

-- qbcore emits its inventory-change event synchronously from setPath. Mark
-- qbinventory-originated writes so the listener below does not produce partial
-- live patches or double-bump a transaction's revision.
local function playerSetPath(src, path, value)
    ownPlayerWrites[src] = (ownPlayerWrites[src] or 0) + 1
    local results = table.pack(exports.qbcore:setPath(src, path, value))
    ownPlayerWrites[src] = ownPlayerWrites[src] - 1
    if ownPlayerWrites[src] == 0 then
        ownPlayerWrites[src] = nil
    end
    return table.unpack(results, 1, results.n)
end

local function recordAudit(action, src, details)
    audit[#audit + 1] = { at = os.time(), action = action, source = src, details = inventory.copy(details or {}) }
    if #audit > config.auditLimit then
        table.remove(audit, 1)
    end
    TriggerEvent('qbinventory:server:audit', action, src, details)
end

-- Canonical item records ----------------------------------------------------

local canonicalItemFields = {
    amount = true,
    count = true,
    image = true,
    imageUrl = true,
    info = true,
    label = true,
    metadata = true,
    name = true,
    preventClose = true,
    shouldClose = true,
    slot = true,
    type = true,
    unique = true,
    useable = true,
    useTime = true,
    weight = true,
}

local function copyItemExtensions(target, source)
    for field, value in pairs(source) do
        if not canonicalItemFields[field] then
            target[field] = inventory.copy(value)
        end
    end
end

local function buildItem(name, amount, slot, metadata)
    local def = itemDef(name)
    if not def then
        return nil, 'unknown item'
    end
    return {
        slot = slot,
        name = def.name or tostring(name):lower(),
        amount = amount,
        info = inventory.copy(metadata or {}),
        metadata = inventory.copy(metadata or {}),
        type = def.type or 'item',
        unique = def.unique or false,
        useable = def.useable == true or hasUseable(def.name or name),
        container = def.container == true,
        image = def.image,
        imageUrl = def.imageUrl,
        label = def.label or name,
        weight = def.weight or 0,
        shouldClose = def.shouldClose,
        description = def.description,
        -- `preventClose` is qbinventory's own native field (opposite polarity
        -- of legacy `shouldClose`, default false = "closes the panel after
        -- use"). `shouldClose` itself is left untouched above for qb-core
        -- compat parity -- but a legacy item that set `shouldClose = false`
        -- meant exactly "leave the inventory open", so honour that as an
        -- implicit preventClose when the item hasn't set the native field.
        preventClose = def.preventClose == true or def.shouldClose == false,
        -- Milliseconds run through qblib's progress bar (client.lua) before a
        -- use effect applies. 0/absent keeps today's immediate-use behaviour.
        useTime = math.max(0, math.floor(tonumber(def.useTime) or 0)),
        created = os.time(),
    }
end

-- Presentation is deliberately derived from the canonical item definition,
-- not from an arbitrary resource's ItemBox payload.  This keeps qbinventory
-- headless at its API boundary while its optional UI remains consistent and
-- prevents an external resource from spoofing receipt labels, images or text.
local function showItemBox(src, name, amount, action)
    local policy = config.itemBoxes
    if type(policy) ~= 'table' or policy.enabled ~= true then
        return
    end
    if action == 'add' and policy.showAdditions ~= true then
        return
    end
    if action == 'purchase' and policy.showPurchases ~= true then
        return
    end
    if action == 'remove' and policy.showRemovals ~= true then
        return
    end
    if action == 'use' and policy.showUses ~= true then
        return
    end

    local def = itemDef(name)
    if not def then
        return
    end
    local payload = {
        name = def.name or tostring(name):lower(),
        label = def.label or tostring(name),
        image = def.image,
        imageUrl = def.imageUrl,
        amount = amount,
        action = action,
        duration = math.max(750, math.floor(tonumber(policy.duration) or 2600)),
    }
    TriggerClientEvent('qbinventory:client:itemBox', src, payload)
    -- The upstream name, for legacy client scripts. Argument order is
    -- upstream's (itemData, type, amount). qbinventory's own client bridge
    -- registers this as a no-op, so its UI still renders exactly one receipt
    -- from the native event above.
    TriggerClientEvent('qb-inventory:client:ItemBox', src, payload, action, amount)
end

-- Inventory registry and access --------------------------------------------

local function secondary(kind, id, opts)
    local inventoryKey = key(kind, id)
    local inv = inventories[inventoryKey]
    -- The second return means "already exists", whether it came from this live
    -- registry or durable restoration. Callers such as RegisterShop must never
    -- reseed and wipe stock merely because a fixture refreshed its policy.
    if inv then
        return inv, true
    end
    opts = opts or {}
    -- Hydrate qbinventory-owned storage only after the persistence bootstrap
    -- has completed. Player inventories are intentionally never read here.
    local persistence = inventory.persistence
    if persistence and persistence.getStatus and persistence.getStatus().ready then
        local restored, restoreErr = persistence.load(kind, id)
        if restored then
            restored.key = inventoryKey
            -- Registration-time policy (especially a non-serialisable access
            -- callback) is authoritative over persisted descriptive state.
            for _, field in ipairs({ 'label', 'coords', 'distance', 'groups', 'owner', 'access', 'prices', 'currency' }) do
                if opts[field] ~= nil then
                    restored[field] = inventory.copy(opts[field])
                end
            end
            if opts.slots ~= nil then
                restored.slots = math.floor(tonumber(opts.slots) or restored.slots)
            end
            if opts.maxWeight ~= nil or opts.maxweight ~= nil then
                restored.maxWeight = tonumber(opts.maxWeight or opts.maxweight) or restored.maxWeight
            end
            inventories[inventoryKey] = restored
            return restored, true
        elseif restoreErr then
            print(('^3[qbinventory]^7 could not restore %s: %s'):format(inventoryKey, tostring(restoreErr)))
        end
    end
    inv = {
        key = inventoryKey,
        id = id,
        type = kind,
        label = opts.label or tostring(id),
        slots = math.floor(tonumber(opts.slots) or config.defaultSlots),
        maxWeight = tonumber(opts.maxWeight or opts.maxweight) or config.defaultMaxWeight,
        items = inventory.copy(opts.items or {}),
        revision = 0,
        coords = opts.coords,
        distance = tonumber(opts.distance) or config.interactionDistance,
        groups = opts.groups,
        owner = opts.owner,
        temporary = opts.temporary == true,
        stock = opts.stock,
        prices = opts.prices,
        currency = opts.currency or 'money',
        access = opts.access,
    }
    inventories[inventoryKey] = inv
    if persistence and persistence.markDirty then
        persistence.markDirty(inv)
    end
    return inv
end

local function getInventory(inventoryKey)
    if type(inventoryKey) ~= 'string' then
        return nil
    end
    local src = tonumber(inventoryKey:match('^player:(%d+)$'))
    if src then
        local data = playerData(src)
        if not data then
            return nil
        end
        return {
            key = inventoryKey,
            id = src,
            type = 'player',
            label = data.name or ('Player %d'):format(src),
            slots = config.playerSlots,
            maxWeight = config.playerMaxWeight,
            items = playerItems(src),
            revision = (inventories[inventoryKey] and inventories[inventoryKey].revision) or 0,
            source = src,
        }
    end
    return inventories[inventoryKey]
end

local function revision(inventoryKey)
    local inv = inventories[inventoryKey]
    if not inv then
        inv = { key = inventoryKey, revision = 0 }
        inventories[inventoryKey] = inv
    end
    return inv.revision or 0
end

local function bump(inventoryKey)
    local inv = inventories[inventoryKey]
    if not inv then
        inv = { key = inventoryKey, revision = 0 }
        inventories[inventoryKey] = inv
    end
    inv.revision = (inv.revision or 0) + 1
    if inv.type and inv.type ~= 'player' and inventory.persistence and inventory.persistence.markDirty then
        inventory.persistence.markDirty(inv)
    end
    return inv.revision
end

local function groupAllowed(src, groups)
    if not groups then
        return true
    end
    local data = playerData(src)
    if not data then
        return false
    end
    local job, gang = data.job or {}, data.gang or {}
    for group, minimum in pairs(groups) do
        if group == job.name or group == gang.name then
            local grade = (job.name == group and job.grade or gang.grade) or {}
            local level = tonumber(grade.level) or 0
            if minimum == nil or level >= tonumber(minimum) then
                return true
            end
        end
    end
    return false
end

---One registered inventory may be reachable from several fixtures. Funnel the
---single-coordinate and coordinate-list forms through one fail-closed check so
---open and in-session revalidation always apply the same rule.
local function withinCoordinates(src, coords, distance)
    local points = inventory.coordinateList(coords)
    if points == nil then
        return true
    end
    for _, point in ipairs(points) do
        local ok, nearby = pcall(QB.distance.player, src, point, tonumber(point.distance) or distance)
        if ok and nearby then
            return true
        end
    end
    return false
end

local function sameBucket(src, target)
    return not config.requireSameBucket or GetPlayerRoutingBucket(src) == GetPlayerRoutingBucket(target)
end

local function mayInspectPlayer(src, target)
    local policy = config.playerInspection or {}
    local allowed = false
    local function run(callback)
        local ok, result, reason = pcall(
            callback,
            src,
            target,
            inventory.copy(playerData(src) or {}),
            inventory.copy(playerData(target) or {})
        )
        if not ok then
            print(('^3[qbinventory]^7 player inspection policy failed: %s'):format(tostring(result)))
            return false, 'player inspection policy failed'
        end
        if result == false then
            return false, reason or 'player inspection denied'
        end
        if result == true then
            allowed = true
        end
        return true
    end
    if inventory.isCallable(policy.access) then
        local ok, err = run(policy.access)
        if not ok then
            return false, err
        end
    end
    for _, hook in pairs(inspectionHooks) do
        local ok, err = run(hook.callback)
        if not ok then
            return false, err
        end
    end
    return allowed, allowed and nil or 'player inspection not authorised'
end

-- `opts` is only ever the raw client-supplied open request (never available
-- during in-session transfer revalidation, see validSession below) -- an
-- access callback that depends on it must treat a missing opts as "already
-- gated at open time", not as a reason to fail an otherwise-valid session.
local function canAccess(src, inv, opts)
    if not inv then
        return false, 'inventory not found'
    end
    if inv.type == 'player' then
        if inv.source == src then
            return true
        end
        if not sameBucket(src, inv.source) then
            return false, 'different routing bucket'
        end
        if not QB.distance.player(src, GetEntityCoords(GetPlayerPed(inv.source)), config.interactionDistance) then
            return false, 'too far away'
        end
        return mayInspectPlayer(src, inv.source)
    end
    if inv.owner then
        local data = playerData(src)
        if not data or (inv.owner ~= src and inv.owner ~= data.citizenid) then
            return false, 'not owner'
        end
    end
    if not groupAllowed(src, inv.groups) then
        return false, 'not authorised'
    end
    if inv.access then
        local ok, allowed = pcall(inv.access, src, inv, opts)
        if not ok or not allowed then
            return false, 'access denied'
        end
    end
    if not withinCoordinates(src, inv.coords, inv.distance) then
        return false, 'too far away'
    end
    return true
end

local function viewItems(source)
    local items = inventory.copy(source or {})
    -- Older player records predate `imageUrl`. Resolve presentation fields from
    -- the current core registry at render time so no player-inventory migration
    -- is needed merely to adopt the remote artwork catalogue.
    for _, item in pairs(items) do
        -- Trusted server integrations may attach bookkeeping to durable stock.
        -- It is authority state, not item metadata, and must never reach NUI.
        item.serverData = nil
        local def = item and itemDef(item.name)
        if def then
            item.image = def.image or item.image
            item.imageUrl = def.imageUrl or item.imageUrl
            item.container = def.container == true
        end
    end
    return items
end

local function view(inventoryKey)
    local inv = getInventory(inventoryKey)
    if not inv then
        return nil
    end
    local items = viewItems(inv.items)
    return {
        id = inv.id,
        key = inv.key,
        type = inv.type,
        label = inv.label,
        slots = inv.slots,
        maxWeight = inv.maxWeight,
        weight = inventory.totalWeight(inv.items),
        revision = revision(inventoryKey),
        items = items,
        stock = inv.stock and viewItems(inv.stock) or nil,
    }
end

local function patchView(inventoryKey)
    return { key = inventoryKey, revision = revision(inventoryKey), inventory = view(inventoryKey) }
end

local function broadcast(inventoryKey)
    local update = patchView(inventoryKey)
    for src, session in pairs(sessions) do
        if session.primary == inventoryKey or session.secondary == inventoryKey then
            TriggerClientEvent('qbinventory:client:sessionPatched', src, session.token, update)
            -- Legacy qb-inventory dependants listen for this to re-read their
            -- own PlayerData after a change. qbinventory's own client bridge
            -- treats it as a refresh request, and third-party scripts that only
            -- know the upstream name now hear about committed changes at all --
            -- previously nothing outside qbinventory was ever notified.
            TriggerClientEvent('qb-inventory:client:updateInventory', src)
        end
    end
end

-- Mutation primitives -------------------------------------------------------

local function lock(keys, transaction)
    table.sort(keys)
    local owner = coroutine.running() or 'main'
    for _, inventoryKey in ipairs(keys) do
        local held = locks[inventoryKey]
        if held and held.owner ~= owner then
            return false, 'inventory busy'
        end
    end
    for _, inventoryKey in ipairs(keys) do
        local held = locks[inventoryKey]
        if held then
            held.depth = held.depth + 1
        else
            locks[inventoryKey] = { owner = owner, depth = 1 }
        end
    end
    local result = table.pack(xpcall(transaction, debug.traceback))
    for _, inventoryKey in ipairs(keys) do
        local held = locks[inventoryKey]
        held.depth = held.depth - 1
        if held.depth == 0 then
            locks[inventoryKey] = nil
        end
    end
    if not result[1] then
        print(('^1[qbinventory]^7 transaction failed: %s'):format(result[2]))
        return false, 'transaction failed'
    end
    return table.unpack(result, 2, result.n)
end

local function addSecondary(inv, name, amount, slot, metadata)
    local item, err = buildItem(name, amount, slot, metadata)
    if not item then
        return false, err
    end
    local currentWeight = inventory.totalWeight(inv.items)
    if currentWeight + inventory.itemWeight(item) > inv.maxWeight then
        return false, 'over weight'
    end
    if item.unique and amount > 1 then
        local placed = {}
        for _ = 1, amount do
            local free = inventory.firstFreeSlot(inv.items, inv.slots)
            if not free then
                for _, used in ipairs(placed) do
                    inv.items[used] = nil
                end
                return false, 'no free slot'
            end
            local one = inventory.copy(item)
            one.amount = 1
            one.slot = free
            inv.items[free] = one
            placed[#placed + 1] = free
        end
        return true, placed[1]
    end
    local stack = slot and inv.items[slot] and inv.items[slot].name == name and slot
        or inventory.stackSlot(inv.items, item)
    if stack then
        inv.items[stack].amount = inv.items[stack].amount + amount
        return true, stack
    end
    slot = slot or inventory.firstFreeSlot(inv.items, inv.slots)
    if not slot or inv.items[slot] then
        return false, 'no free slot'
    end
    item.slot = slot
    inv.items[slot] = item
    return true, slot
end

---Removes from a SECONDARY inventory (stash, drop, trunk, glovebox, container,
---evidence). Reached only through removeFrom, which dispatches here for
---anything that is not a player inventory.
---
---Returns `(ok, err, removed)` -- three values, matching removePlayer. The
---middle slot is the ERROR and stays nil on success; the item is third. This
---returned `(true, removed)` for a long time, one value short, so every call
---site's `local ok, err, removed = removeFrom(...)` bound the item to `err` and
---left `removed` nil -- and the next line crashed with "attempt to index a nil
---value (local 'removed')". That made a transfer OUT of any secondary
---inventory fail, which is most of what a stash is for.
---@param inv table
---@param slot integer
---@param amount integer|nil Defaults to the whole stack.
---@return boolean ok
---@return string|nil err
---@return table|nil removed
local function removeSecondary(inv, slot, amount)
    local item = inv.items[slot]
    if not item then
        return false, 'empty slot'
    end
    amount = inventory.amount(amount, item.amount)
    if not amount or amount > item.amount then
        return false, 'not enough of item'
    end
    local removed = inventory.copy(item)
    removed.amount = amount
    if amount == item.amount then
        inv.items[slot] = nil
    else
        item.amount = item.amount - amount
    end
    return true, nil, removed
end

local function addPlayer(src, name, amount, slot, metadata, reason)
    local items = playerItems(src)
    -- Every weapon added through the public inventory surface receives the
    -- canonical server metadata, not only weapons crafted in crafting.lua.
    -- This covers shops, admin grants and compatibility callers alike.
    if
        inventory.weapons
        and inventory.weapons.isWeapon
        and inventory.weapons.prepareMetadata
        and inventory.weapons.isWeapon(name)
    then
        local prepared, prepareErr = inventory.weapons.prepareMetadata(name, metadata)
        if not prepared then
            return false, prepareErr
        end
        metadata = prepared
    end
    local item, err = buildItem(name, amount, slot, metadata)
    if not item then
        return false, err
    end
    if inventory.totalWeight(items) + inventory.itemWeight(item) > config.playerMaxWeight then
        return false, 'over weight'
    end
    if item.unique and amount > 1 then
        local placed = {}
        for _ = 1, amount do
            local free = inventory.firstFreeSlot(items, config.playerSlots)
            if not free then
                for _, used in ipairs(placed) do
                    playerSetPath(src, { 'items', used }, nil)
                end
                return false, 'no free slot'
            end
            local one = inventory.copy(item)
            one.amount = 1
            one.slot = free
            -- A multi-item grant must never duplicate an instance serial.
            if
                item.unique
                and inventory.weapons
                and inventory.weapons.isWeapon
                and inventory.weapons.prepareMetadata
                and inventory.weapons.isWeapon(name)
            then
                local individual = inventory.copy(metadata or {})
                individual.serial = nil
                local prepared, prepareErr = inventory.weapons.prepareMetadata(name, individual)
                if not prepared then
                    return false, prepareErr
                end
                one.info, one.metadata = prepared, inventory.copy(prepared)
            end
            local ok, err = playerSetPath(src, { 'items', free }, one)
            if not ok then
                for _, used in ipairs(placed) do
                    playerSetPath(src, { 'items', used }, nil)
                end
                return false, err
            end
            items[free] = one
            placed[#placed + 1] = free
        end
        return true
    end
    local stack = slot and items[slot] and items[slot].name == name and slot or inventory.stackSlot(items, item)
    if stack then
        local nextItem = inventory.copy(items[stack])
        nextItem.amount = nextItem.amount + amount
        return playerSetPath(src, { 'items', stack }, nextItem)
    end
    slot = slot or inventory.firstFreeSlot(items, config.playerSlots)
    if not slot or items[slot] then
        return false, 'no free slot'
    end
    item.slot = slot
    return playerSetPath(src, { 'items', slot }, item)
end

local function removePlayer(src, slot, amount)
    local items = playerItems(src)
    local item = items[slot]
    if not item then
        return false, 'empty slot'
    end
    amount = inventory.amount(amount, item.amount)
    if not amount or amount > item.amount then
        return false, 'not enough of item'
    end
    local removed = inventory.copy(item)
    removed.amount = amount
    if amount == item.amount then
        local ok, err = playerSetPath(src, { 'items', slot }, nil)
        return ok, err, removed
    end
    local nextItem = inventory.copy(item)
    nextItem.amount = nextItem.amount - amount
    local ok, err = playerSetPath(src, { 'items', slot }, nextItem)
    return ok, err, removed
end

-- Physical cash operations -------------------------------------------------

-- These functions are called only by qbcore's money module. They bypass the
-- public AddItem/RemoveItem compatibility layer deliberately: that layer
-- redirects physical cash back into qbcore, while these are the one audited
-- route that changes the actual cash stack.
local function requireCashAuthority(account)
    if GetInvokingResource() ~= 'qbcore' then
        return nil, 'physical cash is restricted to qbcore'
    end
    local policy = cashPolicy()
    if not policy or policy.account ~= account then
        return nil, 'physical cash is not configured for this account'
    end
    return policy
end

local function physicalCashCanImport(src, account, amount)
    local policy, err = requireCashAuthority(account)
    if not policy then
        return false, err
    end
    amount = math.floor(tonumber(amount) or -1)
    if amount < 0 then
        return false, 'invalid cash amount'
    end
    if amount == 0 then
        return true
    end
    return canCarry(src, policy.item, amount)
end

local function physicalCashBalance(src, policy)
    local total = 0
    for _, item in pairs(playerItems(src)) do
        if type(item.name) == 'string' and item.name:lower() == policy.item then
            total = total + (tonumber(item.amount) or 0)
        end
    end
    return total
end

local function physicalCashCredit(src, policy, account, amount, reason)
    local ok, addErr = addPlayer(src, policy.item, amount, nil, {}, 'qbcore-cash:' .. tostring(reason or 'add'))
    if not ok then
        return false, addErr
    end
    bump(playerKey(src))
    broadcast(playerKey(src))
    recordAudit('cash-add', src, { account = account, amount = amount, reason = reason })
    showItemBox(src, policy.item, amount, 'add')
    return true
end

local function physicalCashGet(src, account)
    local policy, err = requireCashAuthority(account)
    if not policy then
        return nil, err
    end
    return physicalCashBalance(src, policy)
end

local function physicalCashAdd(src, account, amount, reason)
    local policy, err = requireCashAuthority(account)
    amount = inventory.amount(amount, 0)
    if not policy then
        return false, err
    end
    if not amount then
        return false, 'invalid cash amount'
    end
    return lock({ playerKey(src) }, function()
        return physicalCashCredit(src, policy, account, amount, reason)
    end)
end

local function physicalCashDebit(src, policy, account, amount, reason)
    local items, remaining, planned = playerItems(src), amount, {}
    for slot = 1, config.playerSlots do
        local item = items[slot]
        if item and type(item.name) == 'string' and item.name:lower() == policy.item then
            local take = math.min(remaining, item.amount)
            planned[#planned + 1] = { slot = slot, amount = take }
            remaining = remaining - take
            if remaining == 0 then
                break
            end
        end
    end
    if remaining > 0 then
        return false, 'insufficient funds'
    end
    for _, part in ipairs(planned) do
        local ok, removeErr = removePlayer(src, part.slot, part.amount)
        if not ok then
            return false, removeErr
        end
    end
    bump(playerKey(src))
    broadcast(playerKey(src))
    recordAudit('cash-remove', src, { account = account, amount = amount, reason = reason })
    showItemBox(src, policy.item, amount, 'remove')
    return true
end

local function physicalCashRemove(src, account, amount, reason)
    local policy, err = requireCashAuthority(account)
    amount = inventory.amount(amount, 0)
    if not policy then
        return false, err
    end
    if not amount then
        return false, 'invalid cash amount'
    end
    return lock({ playerKey(src) }, function()
        return physicalCashDebit(src, policy, account, amount, reason)
    end)
end

local function physicalCashSet(src, account, amount, reason)
    local policy, err = requireCashAuthority(account)
    amount = math.floor(tonumber(amount) or -1)
    if not policy then
        return false, err
    end
    if amount < 0 then
        return false, 'invalid cash amount'
    end
    local current = physicalCashBalance(src, policy)
    return lock({ playerKey(src) }, function()
        local lockedCurrent = physicalCashBalance(src, policy)
        if amount == lockedCurrent then
            return true
        end
        if amount > lockedCurrent then
            return physicalCashCredit(src, policy, account, amount - lockedCurrent, reason or 'set')
        end
        return physicalCashDebit(src, policy, account, lockedCurrent - amount, reason or 'set')
    end)
end

local function physicalCashTransfer(fromSrc, toSrc, account, amount, reason)
    local policy, err = requireCashAuthority(account)
    amount = inventory.amount(amount, 0)
    if not policy then
        return false, err
    end
    if not amount or fromSrc == toSrc then
        return false, 'invalid cash transfer'
    end
    if not playerData(fromSrc) or not playerData(toSrc) then
        return false, 'player unavailable'
    end
    return lock({ playerKey(fromSrc), playerKey(toSrc) }, function()
        local current = physicalCashBalance(fromSrc, policy)
        if current < amount then
            return false, 'insufficient funds'
        end
        local canReceive, carryErr = canCarry(toSrc, policy.item, amount)
        if not canReceive then
            return false, carryErr
        end
        local removed, removeErr = physicalCashDebit(fromSrc, policy, account, amount, reason or 'transfer')
        if not removed then
            return false, removeErr
        end
        local added, addErr = physicalCashCredit(toSrc, policy, account, amount, reason or 'transfer')
        if not added then
            local rolledBack, rollbackErr = physicalCashCredit(fromSrc, policy, account, amount, 'transfer-rollback')
            if not rolledBack then
                print(('^1[qbinventory]^7 physical cash rollback failed: %s'):format(tostring(rollbackErr)))
            end
            return false, addErr
        end
        recordAudit('cash-transfer', fromSrc, { to = toSrc, account = account, amount = amount, reason = reason })
        return true
    end)
end

local function physicalCashImport(src, account, amount)
    local policy, err = requireCashAuthority(account)
    amount = math.floor(tonumber(amount) or -1)
    if not policy then
        return false, err
    end
    if amount < 0 then
        return false, 'invalid legacy cash balance'
    end
    if amount == 0 then
        return true
    end
    local canImport, importErr = canCarry(src, policy.item, amount)
    if not canImport then
        return false, importErr
    end
    return lock({ playerKey(src) }, function()
        return physicalCashCredit(src, policy, account, amount, 'legacy-balance-migration')
    end)
end

-- Shop stock is only ever legitimately mutated by buyItem()'s direct
-- shop.stock manipulation (paid, price-checked) -- every OTHER write path
-- (generic transfer, the ox adapter, and anything added later) funnels
-- through addTo/removeFrom, so the read-only guard lives here once instead
-- of being re-asserted (and risking drifting error strings) at every caller.
local function addTo(inventoryKey, name, amount, slot, metadata, reason)
    local inv = getInventory(inventoryKey)
    if not inv then
        return false, 'inventory not found'
    end
    if inv.type == 'shop' then
        return false, 'shop inventory is read only'
    end
    if inv.type == 'player' then
        return addPlayer(inv.source, name, amount, slot, metadata, reason)
    end
    return addSecondary(inv, name, amount, slot, metadata)
end

---Removes `amount` from `slot` of any inventory.
---
---`(ok, err, removed)` on BOTH branches -- callers read the removed item from
---the third slot, and a two-value branch here silently hands them an error
---message where the item should be.
---@param inventoryKey string Inventory key.
---@param slot integer
---@param amount integer|nil Defaults to the whole stack.
---@return boolean ok
---@return string|nil err
---@return table|nil removed
local function removeFrom(inventoryKey, slot, amount)
    local inv = getInventory(inventoryKey)
    if not inv then
        return false, 'inventory not found'
    end
    if inv.type == 'shop' then
        return false, 'shop items must be purchased'
    end
    if inv.type == 'player' then
        return removePlayer(inv.source, slot, amount)
    end
    return removeSecondary(inv, slot, amount)
end

local function runHooks(name, src, payload)
    for _, hook in pairs(hooks[name] or {}) do
        local filter = hook.options or {}
        local match = (not filter.itemFilter or filter.itemFilter[payload.itemName])
            and (not filter.inventoryFilter or filter.inventoryFilter[payload.fromInventory] or filter.inventoryFilter[payload.toInventory])
            and (not filter.typeFilter or filter.typeFilter[payload.fromType] or filter.typeFilter[payload.toType])
        if match then
            -- `src` is appended as a SECOND argument (not prepended) so an
            -- existing single-arg `function(payload)` hook keeps working
            -- unmodified -- it just never reads the extra parameter.
            local ok, result = pcall(hook.callback, payload, src)
            if not ok then
                print(('^3[qbinventory]^7 hook %d failed: %s'):format(hook.id, result))
            elseif result == false then
                return false, 'action denied by hook'
            elseif type(result) == 'table' then
                payload.metadata = result
            end
        end
    end
    return true
end

-- Sessions and transfers ----------------------------------------------------

local function close(src, reason)
    local session = sessions[src]
    if not session then
        return false
    end
    sessions[src] = nil
    TriggerClientEvent('qbinventory:client:sessionClosed', src, session.token, reason or 'closed')
    TriggerEvent('qbinventory:server:sessionClosed', src, session, reason or 'closed')
    return true
end

---Remove an exhausted ground drop and its client-side representation.
---
---Drops are temporary inventories, but their bag props live on every client.
---Keeping this in the mutation funnel (rather than only in `dropTake`) makes
---the ordinary two-panel transfer path clean up the prop as well.
---@param inv table
---@param src integer|nil
local function removeEmptyDrop(inv, src)
    if inv.type ~= 'drop' or next(inv.items) then
        return false
    end

    if inventory.persistence and inventory.persistence.delete then
        inventory.persistence.delete(inv.type, inv.id)
    end
    inventories[inv.key] = nil
    TriggerClientEvent('qbinventory:client:dropRemoved', -1, inv.id)
    if src then
        close(src, 'drop empty')
    end
    return true
end

local function open(src, secondaryKey, opts)
    close(src, 'replaced')
    local primary = playerKey(src)
    local second = getInventory(secondaryKey)
    if not second then
        return false, 'inventory not found'
    end
    local ok, err = canAccess(src, second, opts)
    if not ok then
        return false, err
    end
    local hookOK, hookErr = runHooks('openInventory', src, { inventoryId = secondaryKey, inventoryType = second.type })
    if not hookOK then
        return false, hookErr
    end
    local token = ('%s:%d:%d'):format(src, now(), math.random(100000, 999999))
    sessions[src] = { token = token, primary = primary, secondary = secondaryKey, expires = now() + config.sessionTtl }
    local payload =
        { token = token, primary = view(primary), secondary = view(secondaryKey), expires = sessions[src].expires }
    TriggerClientEvent('qbinventory:client:sessionOpened', src, payload)
    TriggerEvent('qbinventory:server:sessionOpened', src, payload)
    return true, payload
end

-- A player opening their own inventory is a one-panel session. Treating the
-- primary player view as its own secondary would render it twice and would
-- accidentally make self-transfers look like cross-inventory operations.
local function openSelf(src)
    close(src, 'replaced')
    local primary = playerKey(src)
    if not getInventory(primary) then
        return false, 'player inventory not found'
    end
    local token = ('%s:%d:%d'):format(src, now(), math.random(100000, 999999))
    sessions[src] = { token = token, primary = primary, secondary = nil, expires = now() + config.sessionTtl }
    local payload = { token = token, primary = view(primary), secondary = nil, expires = sessions[src].expires }
    TriggerClientEvent('qbinventory:client:sessionOpened', src, payload)
    TriggerEvent('qbinventory:server:sessionOpened', src, payload)
    return true, payload
end

local function validSession(src, token, fromKey, toKey, expectedFrom, expectedTo)
    local session = sessions[src]
    if not session or token ~= session.token then
        return nil, 'invalid session'
    end
    if now() > session.expires then
        close(src, 'expired')
        return nil, 'session expired'
    end
    if
        (fromKey ~= session.primary and fromKey ~= session.secondary)
        or (toKey ~= session.primary and toKey ~= session.secondary)
    then
        return nil, 'inventory not in session'
    end
    local from, to = getInventory(fromKey), getInventory(toKey)
    local ok, err = canAccess(src, from)
    if not ok then
        close(src, err)
        return nil, err
    end
    ok, err = canAccess(src, to)
    if not ok then
        close(src, err)
        return nil, err
    end
    if expectedFrom ~= nil and tonumber(expectedFrom) ~= revision(fromKey) then
        return nil, 'stale source inventory'
    end
    if expectedTo ~= nil and tonumber(expectedTo) ~= revision(toKey) then
        return nil, 'stale target inventory'
    end
    return session, from, to
end

local function transfer(src, request)
    if type(request) ~= 'table' then
        return false, 'invalid request'
    end
    local fromKey, toKey = request.fromInventory, request.toInventory
    local _, from, to = validSession(src, request.token, fromKey, toKey, request.fromRevision, request.toRevision)
    if not from then
        return false, to
    end
    if from.type == 'shop' then
        return false, 'shop items must be purchased'
    end
    if to.type == 'shop' then
        return false, 'shop inventory is read only'
    end
    local fromSlot, toSlot = math.floor(tonumber(request.fromSlot) or 0), tonumber(request.toSlot)
    local item = from.items[fromSlot]
    local amount = inventory.amount(request.amount, item and item.amount)
    if not item or not amount or amount > item.amount then
        return false, 'invalid item amount'
    end
    if toSlot then
        toSlot = math.floor(toSlot)
        if toSlot < 1 or toSlot > to.slots then
            return false, 'invalid target slot'
        end
    end
    local containerApi = QbInventory.containers
    if
        to.type == 'container'
        and containerApi
        and containerApi.isPortableItem
        and containerApi.isPortableItem(item)
    then
        local info = item.info or item.metadata or {}
        if info.containerId and tostring(info.containerId) == tostring(to.id) then
            return false, 'a container cannot be stored inside itself'
        end
        if not containerApi.allowNested(item) then
            return false, 'portable containers cannot be stored in another container'
        end
    end
    local payload = {
        action = 'swapItems',
        fromInventory = fromKey,
        toInventory = toKey,
        fromType = from.type,
        toType = to.type,
        fromSlot = fromSlot,
        toSlot = toSlot,
        itemName = item.name,
        count = amount,
        metadata = inventory.copy(item.info),
    }
    local hookOK, hookErr = runHooks('swapItems', src, payload)
    if not hookOK then
        recordAudit('transfer-rejected', src, { reason = hookErr, item = item.name })
        return false, hookErr
    end
    return lock({ fromKey, toKey }, function()
        -- Revalidate inside the critical section; every external request carries revisions.
        local session, currentFrom, currentTo =
            validSession(src, request.token, fromKey, toKey, request.fromRevision, request.toRevision)
        if not session then
            return false, 'stale session'
        end
        local currentItem = currentFrom.items[fromSlot]
        if not currentItem then
            return false, 'source item changed'
        end
        if fromKey == toKey and toSlot == fromSlot then
            return true
        end
        local target = toSlot and currentTo.items[toSlot] or nil
        local stacks = target
            and target.name == currentItem.name
            and not target.unique
            and not currentItem.unique
            and inventory.sameInfo(target.info, currentItem.info)

        -- An occupied non-stack target is a true slot swap. Partial amounts
        -- cannot replace an unrelated occupied slot, and each side must still
        -- respect its own weight cap after the exchange.
        if target and not stacks then
            if amount ~= currentItem.amount then
                return false, 'cannot partially swap occupied slots'
            end
            if fromKey ~= toKey then
                local fromWeight = inventory.totalWeight(currentFrom.items)
                    - inventory.itemWeight(currentItem)
                    + inventory.itemWeight(target)
                local toWeight = inventory.totalWeight(currentTo.items)
                    - inventory.itemWeight(target)
                    + inventory.itemWeight(currentItem)
                if fromWeight > currentFrom.maxWeight or toWeight > currentTo.maxWeight then
                    return false, 'over weight'
                end
            end
            local sourceOK, sourceErr, sourceItem = removeFrom(fromKey, fromSlot, currentItem.amount)
            if not sourceOK then
                return false, sourceErr
            end
            local targetOK, targetErr, targetItem = removeFrom(toKey, toSlot, target.amount)
            if not targetOK then
                addTo(fromKey, sourceItem.name, sourceItem.amount, fromSlot, sourceItem.info, 'swap-rollback')
                return false, targetErr
            end
            local placeSource, placeSourceErr =
                addTo(toKey, sourceItem.name, sourceItem.amount, toSlot, sourceItem.info, 'swap')
            if not placeSource then
                addTo(toKey, targetItem.name, targetItem.amount, toSlot, targetItem.info, 'swap-rollback')
                addTo(fromKey, sourceItem.name, sourceItem.amount, fromSlot, sourceItem.info, 'swap-rollback')
                return false, placeSourceErr
            end
            local placeTarget, placeTargetErr =
                addTo(fromKey, targetItem.name, targetItem.amount, fromSlot, targetItem.info, 'swap')
            if not placeTarget then
                removeFrom(toKey, toSlot, sourceItem.amount)
                addTo(toKey, targetItem.name, targetItem.amount, toSlot, targetItem.info, 'swap-rollback')
                addTo(fromKey, sourceItem.name, sourceItem.amount, fromSlot, sourceItem.info, 'swap-rollback')
                return false, placeTargetErr
            end
            bump(fromKey)
            if toKey ~= fromKey then
                bump(toKey)
            end
            broadcast(fromKey)
            if toKey ~= fromKey then
                broadcast(toKey)
            end
            recordAudit('swap', src, { from = fromKey, to = toKey, source = sourceItem.name, target = targetItem.name })
            TriggerEvent('qbinventory:server:itemsMoved', src, payload)
            return true, { fromRevision = revision(fromKey), toRevision = revision(toKey) }
        end
        local removedOK, removedErr, removed = removeFrom(fromKey, fromSlot, amount)
        if not removedOK then
            return false, removedErr
        end
        local addedOK, addedErr = addTo(toKey, removed.name, amount, toSlot, payload.metadata, 'transfer')
        if not addedOK then
            addTo(fromKey, removed.name, amount, fromSlot, removed.info, 'transfer-rollback')
            return false, addedErr
        end
        bump(fromKey)
        if toKey ~= fromKey then
            bump(toKey)
        end
        broadcast(fromKey)
        if toKey ~= fromKey then
            broadcast(toKey)
        end
        recordAudit('transfer', src, { from = fromKey, to = toKey, item = removed.name, amount = amount })
        TriggerEvent('qbinventory:server:itemsMoved', src, payload)
        local result = { fromRevision = revision(fromKey), toRevision = revision(toKey) }
        removeEmptyDrop(currentFrom, src)
        return true, result
    end)
end

-- Validated client intents --------------------------------------------------
-- UI actions are intentionally narrower than arbitrary exports. Each one
-- starts from the current server-issued session, derives every inventory key
-- from it, and checks the revision supplied by the client mirror.
local function intentUse(src, request)
    local session = sessions[src]
    if not session or type(request.payload) ~= 'table' then
        return false, 'invalid session action'
    end
    if request.payload.inventory and request.payload.inventory ~= session.primary then
        return false, 'items can only be used from your inventory'
    end
    local _, primary = validSession(
        src,
        request.token,
        session.primary,
        session.primary,
        request.primaryRevision,
        request.primaryRevision
    )
    if not primary then
        return false, 'stale inventory'
    end
    local slot = math.floor(tonumber(request.payload.slot) or 0)
    if slot < 1 or not primary.items[slot] then
        return false, 'invalid item slot'
    end
    return lock({ session.primary }, function()
        local currentSession, current = validSession(
            src,
            request.token,
            session.primary,
            session.primary,
            request.primaryRevision,
            request.primaryRevision
        )
        if not currentSession or not current then
            return false, 'stale inventory'
        end
        local item = current.items[slot]
        if not item then
            return false, 'invalid item slot'
        end
        -- Captured before useItem() runs: a successful use can consume the
        -- item (or the whole stack), so `current.items[slot]` may be gone or
        -- a different record afterwards.
        local itemName, preventClose = item.name, item.preventClose == true
        local ok, err = useItem(src, slot)
        if not ok then
            return false, err or 'item cannot be used'
        end
        recordAudit('use', src, { item = itemName, slot = slot })
        return true, { preventClose = preventClose }
    end)
end

local function intentDrop(src, request)
    local session = sessions[src]
    if not session or type(request.payload) ~= 'table' then
        return false, 'invalid session action'
    end
    if request.payload.inventory and request.payload.inventory ~= session.primary then
        return false, 'items can only be dropped from your inventory'
    end
    local _, primary = validSession(
        src,
        request.token,
        session.primary,
        session.primary,
        request.primaryRevision,
        request.primaryRevision
    )
    if not primary then
        return false, 'stale inventory'
    end
    local slot = math.floor(tonumber(request.payload.slot) or 0)
    local item = primary.items[slot]
    local amount = inventory.amount(request.payload.amount, item and item.amount)
    if not item or not amount or amount > item.amount then
        return false, 'invalid item amount'
    end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then
        return false, 'player entity unavailable'
    end

    return lock({ session.primary }, function()
        local current = getInventory(session.primary)
        if not current or revision(session.primary) ~= tonumber(request.primaryRevision) then
            return false, 'stale inventory'
        end
        local removedOK, removedErr, removed = removePlayer(src, slot, amount)
        if not removedOK then
            return false, removedErr
        end
        removed.slot = 1
        local id = dropCreate(GetEntityCoords(ped), { [1] = removed })
        bump(session.primary)
        broadcast(session.primary)
        recordAudit('drop', src, { id = id, item = removed.name, amount = amount })
        return true, id
    end)
end

-- Giving is deliberately a separate intent from an inventory transfer.  The
-- recipient is never made a browser-visible inventory: the client resolves a
-- nearby ped locally, then the server verifies that player again immediately
-- before committing a two-player transaction.
local function intentGive(src, request)
    local session = sessions[src]
    if not session or type(request.payload) ~= 'table' then
        return false, 'invalid session action'
    end
    if request.payload.inventory and request.payload.inventory ~= session.primary then
        return false, 'items can only be given from your inventory'
    end

    local target = math.floor(tonumber(request.payload.target) or 0)
    if target < 1 or target == src or not playerData(target) then
        return false, 'invalid give recipient'
    end
    if not sameBucket(src, target) then
        return false, 'different routing bucket'
    end
    local targetPed = GetPlayerPed(target)
    if
        not targetPed
        or targetPed == 0
        or not QB.distance.player(src, GetEntityCoords(targetPed), config.interactionDistance)
    then
        return false, 'recipient is too far away'
    end

    local _, primary = validSession(
        src,
        request.token,
        session.primary,
        session.primary,
        request.primaryRevision,
        request.primaryRevision
    )
    if not primary then
        return false, 'stale inventory'
    end
    local slot = math.floor(tonumber(request.payload.slot) or 0)
    local item = primary.items[slot]
    local amount = inventory.amount(request.payload.amount, item and item.amount)
    if not item or not amount or amount > item.amount then
        return false, 'invalid item amount'
    end

    local recipientKey = playerKey(target)
    local function recipientCanReceive(inv, sourceItem)
        local incoming = inventory.copy(sourceItem)
        incoming.amount = amount
        if inventory.totalWeight(inv.items) + inventory.itemWeight(incoming) > inv.maxWeight then
            return false, 'recipient is over weight'
        end
        if incoming.unique then
            local free = 0
            for candidate = 1, inv.slots do
                if not inv.items[candidate] then
                    free = free + 1
                end
            end
            if free < amount then
                return false, 'recipient has no free slot'
            end
        elseif not inventory.stackSlot(inv.items, incoming) and not inventory.firstFreeSlot(inv.items, inv.slots) then
            return false, 'recipient has no free slot'
        end
        return true
    end
    return lock({ session.primary, recipientKey }, function()
        -- The session and source revision are checked a second time inside the
        -- lock.  The target's live bucket, entity and distance are likewise
        -- re-read so an old local target selection cannot transfer remotely.
        local _, current = validSession(
            src,
            request.token,
            session.primary,
            session.primary,
            request.primaryRevision,
            request.primaryRevision
        )
        if not current then
            return false, 'stale inventory'
        end
        if not playerData(target) or not sameBucket(src, target) then
            return false, 'recipient unavailable'
        end
        local currentTargetPed = GetPlayerPed(target)
        if
            not currentTargetPed
            or currentTargetPed == 0
            or not QB.distance.player(src, GetEntityCoords(currentTargetPed), config.interactionDistance)
        then
            return false, 'recipient is too far away'
        end
        local currentItem = current.items[slot]
        if not currentItem or currentItem.name ~= item.name or currentItem.amount < amount then
            return false, 'source item changed'
        end
        local recipient = getInventory(recipientKey)
        if not recipient then
            return false, 'recipient unavailable'
        end
        local canReceive, receiveErr = recipientCanReceive(recipient, currentItem)
        if not canReceive then
            return false, receiveErr
        end

        local removedOK, removedErr, removed = removePlayer(src, slot, amount)
        if not removedOK then
            return false, removedErr
        end
        local addedOK, addedErr = addPlayer(target, removed.name, amount, nil, removed.info, 'give')
        if not addedOK then
            local rollbackOK, rollbackErr = addPlayer(src, removed.name, amount, slot, removed.info, 'give-rollback')
            if not rollbackOK then
                print(
                    ('^1[qbinventory]^7 give rollback failed for %s: %s'):format(session.primary, tostring(rollbackErr))
                )
            end
            return false, addedErr
        end

        bump(session.primary)
        bump(recipientKey)
        broadcast(session.primary)
        broadcast(recipientKey)
        recordAudit('give', src, { to = target, item = removed.name, amount = amount, slot = slot })
        TriggerEvent('qbinventory:server:itemsMoved', src, {
            action = 'give',
            fromInventory = session.primary,
            toInventory = recipientKey,
            fromType = 'player',
            toType = 'player',
            fromSlot = slot,
            itemName = removed.name,
            count = amount,
            metadata = inventory.copy(removed.info),
        })
        return true, { fromRevision = revision(session.primary), toRevision = revision(recipientKey) }
    end)
end

local function intentBuy(src, request)
    local session = sessions[src]
    if not session or type(request.payload) ~= 'table' then
        return false, 'invalid session action'
    end
    local shopKey = request.payload.inventory or request.payload.shopInventory or session.secondary
    if shopKey ~= session.secondary then
        return false, 'shop is not in this session'
    end
    local _, shop, player =
        validSession(src, request.token, shopKey, session.primary, request.secondaryRevision, request.primaryRevision)
    if not shop then
        return false, player
    end
    if shop.type ~= 'shop' then
        return false, 'secondary inventory is not a shop'
    end
    local slot = math.floor(tonumber(request.payload.slot) or 0)
    local count = inventory.amount(request.payload.amount, 1)
    local item = (shop.stock or shop.items)[slot]
    if not item or not count or item.amount < count then
        return false, 'out of stock'
    end
    local price = tonumber(item.price or (shop.prices and shop.prices[item.name])) or 0
    local hookOK, hookErr =
        runHooks('buyItem', src, { shopId = shop.id, itemName = item.name, count = count, totalPrice = price * count })
    if not hookOK then
        return false, hookErr
    end

    return lock({ shopKey, session.primary }, function()
        local _, currentShop, currentPlayer = validSession(
            src,
            request.token,
            shopKey,
            session.primary,
            request.secondaryRevision,
            request.primaryRevision
        )
        if not currentShop then
            return false, currentPlayer
        end
        local currentItem = (currentShop.stock or currentShop.items)[slot]
        if not currentItem or currentItem.amount < count then
            return false, 'out of stock'
        end
        if price > 0 then
            local paid, payErr = exports.qbcore:removeMoney(
                src,
                currentShop.currency == 'money' and 'cash' or currentShop.currency,
                price * count,
                'qbinventory-shop'
            )
            if not paid then
                return false, payErr
            end
        end
        local purchaseInfo = inventory.copy(currentItem.info or {})
        if
            inventory.weapons
            and inventory.weapons.isWeapon
            and inventory.weapons.prepareMetadata
            and inventory.weapons.isWeapon(currentItem.name)
        then
            local prepared, prepareErr = inventory.weapons.prepareMetadata(currentItem.name, purchaseInfo)
            if not prepared then
                return false, prepareErr
            end
            purchaseInfo = prepared
        end
        local added, addErr = addPlayer(src, currentItem.name, count, nil, purchaseInfo, 'purchase')
        if not added then
            if price > 0 then
                exports.qbcore:addMoney(
                    src,
                    currentShop.currency == 'money' and 'cash' or currentShop.currency,
                    price * count,
                    'qbinventory-refund'
                )
            end
            return false, addErr
        end
        currentItem.amount = currentItem.amount - count
        if currentItem.amount == 0 then
            currentShop.items[slot] = nil
            if currentShop.stock then
                currentShop.stock[slot] = nil
            end
        end
        bump(shopKey)
        bump(session.primary)
        broadcast(shopKey)
        broadcast(session.primary)
        recordAudit('purchase', src, {
            shop = currentShop.id,
            item = currentItem.name,
            amount = count,
            price = price * count,
            serverData = inventory.copy(currentItem.serverData),
        })
        showItemBox(src, currentItem.name, count, 'purchase')
        TriggerEvent('qbinventory:server:itemPurchased', src, {
            shopId = currentShop.id,
            itemName = currentItem.name,
            count = count,
            metadata = inventory.copy(purchaseInfo),
            price = price * count,
        })
        return true
    end)
end

local function handleIntent(src, request)
    if type(request) ~= 'table' or type(request.action) ~= 'string' or type(request.token) ~= 'string' then
        return false, 'invalid request'
    end
    if request.action == 'use' then
        return intentUse(src, request)
    end
    if request.action == 'drop' then
        return intentDrop(src, request)
    end
    if request.action == 'give' then
        return intentGive(src, request)
    end
    if request.action == 'buy' then
        return intentBuy(src, request)
    end
    return false, 'unsupported intent'
end

-- Player inventory API ------------------------------------------------------

---@param src integer
---@return number currentWeight
---@return number maxWeight
local function getWeight(src)
    local inv = getInventory(playerKey(src))
    return inv and inventory.totalWeight(inv.items) or 0, config.playerMaxWeight
end
---@param src integer
---@param name string
---@param amount number|nil
---@return boolean canCarryItem
---@return string|nil reason
canCarry = function(src, name, amount)
    local def = itemDef(name)
    amount = inventory.amount(amount, 1)
    if not def or not amount then
        return false, 'unknown item'
    end
    local inv = getInventory(playerKey(src))
    if not inv then
        return false, 'no such player'
    end
    local item = buildItem(name, amount, nil, {})
    if inventory.totalWeight(inv.items) + inventory.itemWeight(item) > inv.maxWeight then
        return false, 'over weight'
    end
    if def.unique then
        local free = 0
        for slot = 1, inv.slots do
            if not inv.items[slot] then
                free = free + 1
            end
        end
        if free < amount then
            return false, 'no free slot'
        end
    elseif not inventory.stackSlot(inv.items, item) then
        if not inventory.firstFreeSlot(inv.items, inv.slots) then
            return false, 'no free slot'
        end
    end
    return true
end
---@param src integer
---@param name string
---@param amount number|nil
---@param slot integer|nil
---@param info table|nil
---@param reason string|nil
---@return boolean added
---@return string|nil reason
local function addItem(src, name, amount, slot, info, reason)
    amount = inventory.amount(amount, 1)
    if cashItemsActive and isCashItemName(name) then
        -- Compatibility still works, but monetary accounting and events stay
        -- in qbcore. Never let an arbitrary resource mutate the cash stack.
        return exports.qbcore:addMoney(src, cashPolicy().account, amount, reason or 'qbinventory-add-cash')
    end
    return lock({ playerKey(src) }, function()
        local ok, err = canCarry(src, name, amount)
        if not ok then
            return false, err
        end
        local done, why = addPlayer(src, name, amount, slot, info, reason)
        if done then
            bump(playerKey(src))
            broadcast(playerKey(src))
            recordAudit('add', src, { item = name, amount = amount, reason = reason })
            showItemBox(src, name, amount, 'add')
        end
        return done, why
    end)
end
---@param src integer
---@param name string
---@param amount number|nil
---@param slot integer|nil
---@param reason string|nil
---@return boolean removed
---@return string|nil reason
local function removeItem(src, name, amount, slot, reason)
    amount = inventory.amount(amount, 1)
    if not amount then
        return false, 'invalid amount'
    end
    if cashItemsActive and isCashItemName(name) then
        return exports.qbcore:removeMoney(src, cashPolicy().account, amount, reason or 'qbinventory-remove-cash')
    end
    return lock({ playerKey(src) }, function()
        local items = playerItems(src)
        if slot then
            if not items[slot] or items[slot].name ~= name then
                return false, 'item not in slot'
            end
            local ok, err = removePlayer(src, slot, amount)
            if ok then
                bump(playerKey(src))
                broadcast(playerKey(src))
                recordAudit('remove', src, { item = name, amount = amount, slot = slot, reason = reason })
                showItemBox(src, name, amount, 'remove')
            end
            return ok, err
        end
        local remaining, planned = amount, {}
        for sourceSlot = 1, config.playerSlots do
            local item = items[sourceSlot]
            if item and item.name == name then
                planned[#planned + 1] = { slot = sourceSlot, amount = math.min(remaining, item.amount) }
                remaining = remaining - item.amount
                if remaining <= 0 then
                    break
                end
            end
        end
        if remaining > 0 then
            return false, 'not enough of item'
        end
        for _, part in ipairs(planned) do
            removePlayer(src, part.slot, part.amount)
        end
        bump(playerKey(src))
        broadcast(playerKey(src))
        recordAudit('remove', src, { item = name, amount = amount, reason = reason })
        showItemBox(src, name, amount, 'remove')
        return true
    end)
end
local function itemNameKey(name)
    return type(name) == 'string' and name:lower() or nil
end

---@param src integer
---@param name string
---@return table|nil item
local function getItemByName(src, name)
    local wanted = itemNameKey(name)
    if not wanted then
        return nil
    end
    for _, item in pairs(playerItems(src)) do
        if itemNameKey(item.name) == wanted then
            return item
        end
    end
end
---@param src integer
---@param name string
---@return table[] items
local function getItemsByName(src, name)
    local wanted, out = itemNameKey(name), {}
    if not wanted then
        return out
    end
    for _, item in pairs(playerItems(src)) do
        if itemNameKey(item.name) == wanted then
            out[#out + 1] = item
        end
    end
    return out
end
---@param src integer
---@param slot integer
---@return table|nil item
local function getItemBySlot(src, slot)
    return playerItems(src)[slot]
end
---@param src integer
---@param names string|string[]
---@return number count
local function getItemCount(src, names)
    local wanted, total = {}, 0
    if type(names) == 'string' then
        wanted[itemNameKey(names)] = true
    elseif type(names) == 'table' then
        for _, name in pairs(names) do
            local key = itemNameKey(name)
            if key then
                wanted[key] = true
            end
        end
    else
        return 0
    end
    for _, item in pairs(playerItems(src)) do
        if wanted[itemNameKey(item.name)] then
            total = total + (tonumber(item.amount) or 0)
        end
    end
    return total
end
---@param src integer
---@param names string|string[]|table<string, number>
---@param amount number|nil
---@return boolean hasItems
local function hasItem(src, names, amount)
    if type(names) ~= 'table' then
        return getItemCount(src, names) >= (tonumber(amount) or 1)
    end
    local counts = {}
    for _, item in pairs(playerItems(src)) do
        local name = itemNameKey(item.name)
        counts[name] = (counts[name] or 0) + (tonumber(item.amount) or 0)
    end
    local isArray = #names > 0
    for key, value in pairs(names) do
        local name = itemNameKey(isArray and value or key)
        local required = isArray and (tonumber(amount) or 1) or (tonumber(value) or 1)
        if not name or (counts[name] or 0) < required then
            return false
        end
    end
    return true
end
---@param src integer
---@return integer|nil slot
local function getFreeSlot(src)
    return inventory.firstFreeSlot(playerItems(src), config.playerSlots)
end
---@param src integer
---@param fromSlot integer
---@param toSlot integer
---@param amount number|nil
---@return boolean moved
---@return string|nil reason
local function moveItem(src, fromSlot, toSlot, amount)
    local from = getItemBySlot(src, fromSlot)
    if not from then
        return false, 'empty source slot'
    end
    toSlot = math.floor(tonumber(toSlot) or 0)
    amount = inventory.amount(amount, from.amount)
    if toSlot < 1 or toSlot > config.playerSlots or not amount or amount > from.amount then
        return false, 'invalid move'
    end
    if fromSlot == toSlot then
        return true
    end
    local target = getItemBySlot(src, toSlot)
    if
        target
        and (target.name ~= from.name or target.unique or from.unique or not inventory.sameInfo(target.info, from.info))
    then
        return false, 'destination occupied'
    end
    return lock({ playerKey(src) }, function()
        local removed, removeErr, moved = removePlayer(src, fromSlot, amount)
        if not removed then
            return false, removeErr
        end
        local added, addErr = addPlayer(src, moved.name, amount, toSlot, moved.info, 'move')
        if not added then
            addPlayer(src, moved.name, amount, fromSlot, moved.info, 'move-rollback')
            return false, addErr
        end
        bump(playerKey(src))
        broadcast(playerKey(src))
        recordAudit('move', src, { fromSlot = fromSlot, toSlot = toSlot, amount = amount })
        return true
    end)
end
---@param src integer
---@param keep string|string[]|table<string, boolean>|nil
---@return boolean cleared
---@return string|nil reason
local function clearInventory(src, keep)
    local keeps = {}
    if type(keep) == 'string' then
        keeps[itemNameKey(keep)] = true
    elseif type(keep) == 'table' then
        for key, value in pairs(keep) do
            keeps[itemNameKey(type(key) == 'number' and value or key)] = true
        end
    end
    if cashItemsActive then
        keeps[cashPolicy().item] = true
    end
    return lock({ playerKey(src) }, function()
        for slot, item in pairs(playerItems(src)) do
            if not keeps[itemNameKey(item.name)] then
                local ok, err = playerSetPath(src, { 'items', slot }, nil)
                if not ok then
                    return false, err
                end
            end
        end
        bump(playerKey(src))
        broadcast(playerKey(src))
        return true
    end)
end
---@param src integer
---@param newItems table<integer, table>
---@return boolean replaced
---@return string|nil reason
local function setItems(src, newItems)
    if type(newItems) ~= 'table' then
        return false, 'items must be a table'
    end
    -- A whole-inventory replacement cannot prove that its proposed cash stack
    -- matches the ledger. Reject it instead of permitting a mint/burn bypass.
    if cashItemsActive then
        return false, 'SetInventory is unavailable while cash is an item'
    end
    local checked = {}
    for slot, item in pairs(newItems) do
        slot = tonumber(slot)
        local amount = item and inventory.amount(item.amount, 1)
        if not slot or slot < 1 or slot > config.playerSlots or not item or not itemDef(item.name) or not amount then
            return false, 'invalid item table'
        end
        local built = buildItem(item.name, amount, slot, item.info or item.metadata)
        -- Server integrations legitimately attach qb-compatible fields such
        -- as `quality`, `description` and weapon serials.  Preserve those on
        -- a validated replacement; never copy slot/name/count aliases over
        -- the canonical values derived above.
        copyItemExtensions(built, item)
        checked[slot] = built
    end
    if inventory.totalWeight(checked) > config.playerMaxWeight then
        return false, 'over weight'
    end
    return lock({ playerKey(src) }, function()
        local ok, err = playerSetPath(src, { 'items' }, checked)
        if not ok then
            return false, err
        end
        bump(playerKey(src))
        broadcast(playerKey(src))
        return true
    end)
end

local useables, builtInUseables = {}, {}

-- Useable item API ----------------------------------------------------------

-- Declared on its own line first: a `local x = ... function() x end` would
-- close over the *global* x, since the local is not in scope until after its
-- own statement -- and the cleanup only runs on resource stop, so the nil
-- index would not surface until then.
local useableOwners = QB.resources.serverRegistry(function(name)
    useables[name] = nil
end)

---@param name string
---@param handler function|table
local function createUseable(name, handler)
    assert(type(name) == 'string' and inventory.isCallable(handler), 'name and handler are required')
    local owner = GetInvokingResource() or resourceName
    useables[name] = handler
    useableOwners.track(owner, name)
end
-- Internal, registry-driven handlers (weapons/ammunition) live below explicit
-- resource registrations so a gameplay resource can intentionally override
-- them. Passing nil removes only the built-in handler.
---@param name string
---@param handler function|table|nil
local function setBuiltInUseable(name, handler)
    assert(
        type(name) == 'string' and (handler == nil or inventory.isCallable(handler)),
        'name and callable handler are required'
    )
    builtInUseables[name] = handler
end
-- Whether clicking Use on this item would do something even without a
-- registered handler: either a portable-container definition (useItem's own
-- container bypass, above/below), or a dynamically createUseable-registered
-- handler. buildItem() ORs this with the item/weapon definition's own static
-- `useable` flag -- a static true (e.g. phone/id_card/lockpick) still shows
-- the Use button and falls back to the legacy QBCore:Server:UseItem event
-- for whichever resource handles it (useItem's own fallback, below), same as
-- real qb-core. These are forward-declared locals because buildItem is defined
-- earlier but is only called after this file has initialized the handlers.
---@param name string
---@return boolean hasHandler
hasUseable = function(name)
    if useables[name] or builtInUseables[name] then
        return true
    end
    local containers = QbInventory.containers
    return containers and containers.isPortableItem and containers.isPortableItem({ name = name }) or false
end
---@param src integer
---@param slotOrName integer|string
---@return boolean used
---@return any result
useItem = function(src, slotOrName)
    return lock({ playerKey(src) }, function()
        local item = type(slotOrName) == 'number' and getItemBySlot(src, slotOrName) or getItemByName(src, slotOrName)
        if not item then
            return false, 'item not found'
        end
        local allowed, err = runHooks('usingItem', src, {
            itemName = item.name,
            item = inventory.copy(item),
            inventoryId = playerKey(src),
            inventoryType = 'player',
        })
        if not allowed then
            return false, err
        end
        local containers = QbInventory.containers
        if
            type(slotOrName) == 'number'
            and containers
            and containers.isPortableItem
            and containers.isPortableItem(item)
        then
            local ok, result = containers.openConfiguredItem(src, slotOrName)
            if ok then
                TriggerEvent('qbinventory:server:openedContainer', src, item.name, item)
                return true
            end
            return false, result
        end
        local handler = useables[item.name] or builtInUseables[item.name]
        if handler then
            local ok, result = pcall(handler, src, inventory.copy(item))
            if not ok then
                return false, result
            end
            if result == false then
                return false, 'item use was rejected'
            end
            TriggerEvent('qbinventory:server:usedItem', src, item.name, item)
            -- Opening a portable container above is deliberately excluded: it
            -- consumes nothing and returns before this point.
            showItemBox(src, item.name, 1, 'use')
            return true
        end
        TriggerEvent('QBCore:Server:UseItem', src, item)
        return false, 'no useable registered'
    end)
end

local function ownedStash(src, identifier, opts)
    local data = playerData(src)
    if not data or type(data.citizenid) ~= 'string' or data.citizenid == '' then
        return nil, 'owner identity unavailable'
    end
    opts = inventory.copy(opts or {})
    opts.owner = data.citizenid
    -- Namespace durable private storage; never trust a client-chosen owner.
    return secondary('stash', ('%s:%s'):format(tostring(identifier), data.citizenid), opts)
end

-- Secondary inventories ----------------------------------------------------

---@param identifier string|number
---@return table items
local function stashGet(identifier)
    local inv = secondary('stash', identifier)
    return inventory.copy(inv.items)
end
---@param identifier string|number
---@param items table<integer, table>|nil
---@return boolean updated
---@return string|nil reason
local function stashSet(identifier, items)
    local inv = secondary('stash', identifier)
    return lock({ inv.key }, function()
        return setInventoryItems(inv.key, inventory.copy(items or {}))
    end)
end
-- Shop stock accessors. A shop is registered with its opening stock, but until
-- now nothing could change that stock afterwards: registerShop only seeds a
-- shop that was NOT restored from durable storage, and the generic transfer
-- path deliberately refuses shop inventories ("shop items must be purchased").
-- A restocking/business resource therefore had no way to put goods on a shelf
-- or reprice one. These are the shop equivalents of stashGet/stashSet and go
-- through the same locked setInventoryItems funnel, so stock, revision,
-- viewers and persistence all stay consistent. Unlike the stash pair they
-- refuse an unknown id rather than lazily creating one -- a shop is a
-- deliberate registration with prices and an access policy, never something a
-- restock call should conjure into existence.
---@param identifier string|number
---@return table|nil items
---@return string|nil reason
local function shopGet(identifier)
    local inv = getInventory(key('shop', identifier))
    if not inv then
        return nil, 'shop not found'
    end
    return inventory.copy(inv.stock or inv.items or {})
end
---@param identifier string|number
---@param items table<integer, table>
---@return boolean updated
---@return string|nil reason
local function shopSet(identifier, items)
    local inv = getInventory(key('shop', identifier))
    if not inv then
        return false, 'shop not found'
    end
    if type(items) ~= 'table' then
        return false, 'items must be a table'
    end
    return lock({ inv.key }, function()
        return setInventoryItems(inv.key, inventory.copy(items))
    end)
end
---@param src integer
---@param identifier string|number
---@param opts table|nil
---@return boolean opened
---@return table|string result
local function stashOpen(src, identifier, opts)
    local template = ownedStashTemplates[tostring(identifier)]
    local inv, err
    if template or (type(opts) == 'table' and opts.owner == true) then
        inv, err = ownedStash(src, identifier, template or opts)
        if not inv then
            return false, err
        end
    else
        inv = secondary('stash', identifier, opts)
    end
    return open(src, inv.key, opts)
end
---@param coords vector3|table
---@param items table<integer, table>
---@return integer id
dropCreate = function(coords, items)
    local id = nextDropId
    nextDropId = nextDropId + 1
    local inv = secondary('drop', id, {
        label = 'Ground drop',
        coords = coords,
        distance = config.dropDistance,
        slots = config.defaultSlots,
        items = items,
        temporary = true,
    })
    TriggerClientEvent('qbinventory:client:dropCreated', -1, id, coords)
    return id
end

---Every live ground drop, as { { id, coords }, ... }.
---
---Exists so client/drops.lua can render the props for drops that already
---existed when a player connected -- `dropCreated` is a one-shot broadcast, so
---without this a bag is visible only to whoever was online when it landed.
---
---Deliberately IDs and coordinates only, never contents: the position of a
---dropped bag is already broadcast to every client the moment it is created,
---but what is inside one is not, and must stay a server-side question answered
---by `open`'s own access and distance checks.
---@return table[]
local function dropList()
    local out = {}
    for _, inv in pairs(inventories) do
        if inv.type == 'drop' and inv.coords then
            out[#out + 1] = { id = inv.id, coords = inv.coords }
        end
    end
    return out
end

QB.callback.register('qbinventory:server:drops', function(_src)
    return dropList()
end)
---@param src integer
---@param id integer|string
---@param slot integer
---@param amount number|nil
---@return boolean taken
---@return any result
local function dropTake(src, id, slot, amount)
    local inv = getInventory(key('drop', id))
    if not inv then
        return false, 'no such drop'
    end
    local ok, payload = open(src, inv.key)
    if not ok then
        return false, payload
    end
    local session = sessions[src]
    local result, err = transfer(src, {
        token = session.token,
        fromInventory = inv.key,
        toInventory = playerKey(src),
        fromSlot = slot,
        amount = amount,
        fromRevision = revision(inv.key),
        toRevision = revision(playerKey(src)),
    })
    return result, err
end

-- Registration and shops ---------------------------------------------------
-- Ox-style inventory constructors and shops.
local function refreshRegistration(inv, opts)
    inv.label = opts.label or inv.label
    inv.slots = math.floor(tonumber(opts.slots) or inv.slots)
    inv.maxWeight = tonumber(opts.maxWeight or opts.maxweight) or inv.maxWeight
    inv.coords = inventory.copy(opts.coords)
    inv.distance = tonumber(opts.distance) or config.interactionDistance
    inv.groups = inventory.copy(opts.groups)
    inv.owner = opts.owner
    inv.access = opts.access
    if inv.type == 'shop' then
        inv.prices = opts.prices or inv.prices or {}
        inv.currency = opts.currency or 'money'
    end
    if inventory.persistence and inventory.persistence.markDirty then
        inventory.persistence.markDirty(inv)
    end
end

---@param id string|number
---@param label string|nil
---@param slots integer|nil
---@param maxWeight number|nil
---@param owner integer|string|boolean|nil
---@param groups table|nil
---@param coords vector3|table|nil
---@param distance number|nil
---@return string inventoryKey
local function registerStash(id, label, slots, maxWeight, owner, groups, coords, distance)
    local opts = {
        label = label,
        slots = slots,
        maxWeight = maxWeight,
        owner = owner,
        groups = groups,
        coords = coords,
        distance = distance,
    }
    if owner == true then
        ownedStashTemplates[tostring(id)] = opts
        return key('stash', id)
    end
    local inv = secondary('stash', id, opts)
    -- Re-registration retains contents but refreshes the live access boundary.
    -- This matters for resources whose fixtures can be edited at runtime.
    refreshRegistration(inv, opts)
    return inv.key
end
---@param properties table|nil
---@return string inventoryKey
local function createTemporaryStash(properties)
    properties = properties or {}
    properties.temporary = true
    local inv = secondary('temporary', properties.id or ('tmp-%d'):format(now()), properties)
    return inv.key
end

-- Shop configuration is trusted server data, but it still passes through the
-- same item-definition builder as every other inventory. That keeps the NUI
-- view (label, image, weight, unique/type) canonical and stops a misspelled
-- stock row becoming an unbuyable or misleading item at runtime.
local function normaliseShopStock(rows, slots)
    if rows == nil then
        return {}
    end
    if type(rows) ~= 'table' then
        return nil, 'shop inventory must be a table'
    end
    local entries = {}
    for rawSlot, row in pairs(rows) do
        if type(row) ~= 'table' then
            return nil, 'invalid shop item'
        end
        local slot = math.floor(tonumber(row.slot or rawSlot) or 0)
        if slot < 1 or slot > slots or entries[slot] then
            return nil, 'invalid or duplicate shop slot'
        end
        local amount = inventory.amount(row.amount or row.count, 1)
        local price = tonumber(row.price)
        if not amount or not price or price < 0 then
            return nil, 'invalid shop amount or price'
        end
        if cashItemsActive and isCashItemName(row.name) then
            return nil, 'physical cash cannot be shop stock'
        end
        local item, err = buildItem(row.name, amount, slot, row.info or row.metadata)
        if not item then
            return nil, ('invalid shop item in slot %d: %s'):format(slot, tostring(err))
        end
        item.price = price
        entries[slot] = item
    end
    return entries
end

---@param id string|number
---@param data table|nil
---@return string|nil inventoryKey
---@return string|nil reason
local function registerShop(id, data)
    data = data or {}
    local slots = math.floor(tonumber(data.slots) or config.defaultSlots)
    if slots < 1 then
        return nil, 'invalid shop slots'
    end
    local initial, stockErr = normaliseShopStock(data.inventory or data.items, slots)
    if not initial then
        return nil, stockErr
    end
    data.slots = slots
    local inv, restored = secondary('shop', id, data)
    refreshRegistration(inv, data)
    if not restored then
        inv.stock = initial
        inv.items = inv.stock -- a shop is rendered as an inventory; stock is its authoritative slot table.
    else
        inv.stock = inv.stock or inv.items
    end
    inv.prices = data.prices or inv.prices or {}
    if inventory.persistence and inventory.persistence.markDirty then
        inventory.persistence.markDirty(inv)
    end
    return inv.key
end
---@param src integer
---@param invType string
---@param data any
---@return boolean opened
---@return table|string result
local function openInventory(src, invType, data)
    local inventoryKey
    if invType == 'player' then
        local target = tonumber(data) or src
        if target == src then
            return openSelf(src)
        end
        inventoryKey = playerKey(target)
    elseif invType == 'trunk' or invType == 'glovebox' then
        -- Network id is the only client intent accepted for vehicle storage.
        -- The vehicle domain resolves plate, class, coordinates and access
        -- server-side before it creates or opens any inventory key.
        if not inventory.vehicles or type(inventory.vehicles.open) ~= 'function' then
            return false, 'vehicle storage unavailable'
        end
        return inventory.vehicles.open(src, invType, data)
    elseif invType == 'stash' and ownedStashTemplates[tostring(type(data) == 'table' and data.id or data)] then
        local identifier = type(data) == 'table' and data.id or data
        local inv, err = ownedStash(src, identifier, ownedStashTemplates[tostring(identifier)])
        if not inv then
            return false, err
        end
        inventoryKey = inv.key
    elseif type(data) == 'table' and data.key then
        inventoryKey = data.key
    else
        inventoryKey = key(invType, type(data) == 'table' and data.id or data)
    end
    return open(src, inventoryKey, type(data) == 'table' and data or nil)
end
---@param src integer
---@return boolean closed
local function closeInventory(src)
    return close(src, 'requested')
end
---@param src integer
---@param identifier string|number
---@param opts table|nil
---@return boolean opened
---@return table|string result
local function openQbInventory(src, identifier, opts)
    if type(opts) == 'table' and opts.type then
        return openInventory(src, opts.type, opts)
    end
    return stashOpen(src, identifier, opts)
end

---@param src integer
---@param shopId string|number
---@param slot integer
---@param count number|nil
---@return boolean purchased
---@return string|nil reason
local function buyItem(src, shopId, slot, count)
    local shop = getInventory(key('shop', shopId))
    if not shop then
        return false, 'shop not found'
    end
    local ok, opened = open(src, shop.key)
    if not ok then
        return false, opened
    end
    local item = (shop.stock or shop.items)[slot]
    count = inventory.amount(count, 1)
    if not item or not count or item.amount < count then
        return false, 'out of stock'
    end
    local price = tonumber(item.price or (shop.prices and shop.prices[item.name])) or 0
    local hookOK, hookErr =
        runHooks('buyItem', src, { shopId = shopId, itemName = item.name, count = count, totalPrice = price * count })
    if not hookOK then
        return false, hookErr
    end
    return lock({ shop.key, playerKey(src) }, function()
        shop = getInventory(key('shop', shopId))
        item = shop and (shop.stock or shop.items)[slot] or nil
        if not item or item.amount < count then
            return false, 'out of stock'
        end
        price = tonumber(item.price or (shop.prices and shop.prices[item.name])) or 0
        if price > 0 then
            local paid, payErr = exports.qbcore:removeMoney(
                src,
                shop.currency == 'money' and 'cash' or shop.currency,
                price * count,
                'qbinventory-shop'
            )
            if not paid then
                return false, payErr
            end
        end
        local purchaseInfo = inventory.copy(item.info or {})
        if
            inventory.weapons
            and inventory.weapons.isWeapon
            and inventory.weapons.prepareMetadata
            and inventory.weapons.isWeapon(item.name)
        then
            local prepared, prepareErr = inventory.weapons.prepareMetadata(item.name, purchaseInfo)
            if not prepared then
                return false, prepareErr
            end
            purchaseInfo = prepared
        end
        local added, addErr = addPlayer(src, item.name, count, nil, purchaseInfo)
        if not added then
            if price > 0 then
                exports.qbcore:addMoney(
                    src,
                    shop.currency == 'money' and 'cash' or shop.currency,
                    price * count,
                    'qbinventory-refund'
                )
            end
            return false, addErr
        end
        item.amount = item.amount - count
        if item.amount == 0 then
            shop.stock[slot] = nil
        end
        bump(shop.key)
        bump(playerKey(src))
        broadcast(shop.key)
        broadcast(playerKey(src))
        recordAudit('purchase', src, {
            shop = shopId,
            item = item.name,
            amount = count,
            price = price * count,
            serverData = inventory.copy(item.serverData),
        })
        TriggerEvent('qbinventory:server:itemPurchased', src, {
            shopId = shopId,
            itemName = item.name,
            count = count,
            metadata = inventory.copy(purchaseInfo),
            price = price * count,
        })
        return true
    end)
end

---@param eventName string
---@param callback function|table
---@param options table|nil
---@return integer hookId
local function registerHook(eventName, callback, options)
    assert(type(eventName) == 'string' and inventory.isCallable(callback), 'eventName and callback are required')
    hooks[eventName] = hooks[eventName] or {}
    local id = nextHookId
    nextHookId = nextHookId + 1
    hooks[eventName][id] =
        { id = id, callback = callback, options = options or {}, owner = GetInvokingResource() or resourceName }
    return id
end
---@param id integer
local function removeHooks(id)
    for _, list in pairs(hooks) do
        list[id] = nil
    end
end

---Grant player inspection only through explicit trusted server policy. The
---callback receives source, target, and detached player data; it must return
---true to grant. Returning false rejects the request.
---@param callback function|table
---@return integer hookId
local function registerInspectionAccess(callback)
    assert(inventory.isCallable(callback), 'inspection callback is required')
    local id = nextInspectionHookId
    nextInspectionHookId = nextInspectionHookId + 1
    inspectionHooks[id] = { callback = callback, owner = GetInvokingResource() or resourceName }
    return id
end
---@param id integer
local function removeInspectionAccess(id)
    inspectionHooks[id] = nil
end

-- Internal module API -------------------------------------------------------

-- Trusted server-side extension seam. Compatibility/domain modules load after
-- this authority and may use these helpers, but no client event ever receives
-- this table. Player writes still route through qbcore; callers must acquire
-- deterministic locks and call bump/broadcast only after a committed change.
local function resolveInventoryRef(reference, preferredType)
    if type(reference) == 'number' then
        local inventoryKey = playerKey(reference)
        return inventoryKey, getInventory(inventoryKey)
    end
    if type(reference) == 'table' then
        if reference.key then
            return resolveInventoryRef(reference.key, preferredType)
        end
        if reference.type and reference.id ~= nil then
            return resolveInventoryRef(key(reference.type, reference.id))
        end
        return nil, nil
    end
    if type(reference) ~= 'string' or reference == '' then
        return nil, nil
    end
    local direct = getInventory(reference)
    if direct then
        return reference, direct
    end
    if preferredType then
        local typed = key(preferredType, reference)
        local inv = getInventory(typed)
        if inv then
            return typed, inv
        end
    end
    for _, kind in ipairs({ 'stash', 'trunk', 'glovebox', 'container', 'shop', 'temporary', 'drop', 'evidence' }) do
        local typed = key(kind, reference)
        local inv = getInventory(typed)
        if inv then
            return typed, inv
        end
    end
    return nil, nil
end

local function canAddToInventory(reference, name, amount, slot, metadata)
    local inventoryKey, inv = resolveInventoryRef(reference)
    local count = inventory.amount(amount, 1)
    local item, err
    if count then
        item, err = buildItem(name, count, slot, metadata)
    else
        err = 'invalid count'
    end
    if not inventoryKey or not inv then
        return false, 'inventory'
    end
    if not item then
        return false, err or 'item'
    end
    if inventory.totalWeight(inv.items) + inventory.itemWeight(item) > inv.maxWeight then
        return false, 'weight'
    end
    if item.unique then
        local free = 0
        for candidate = 1, inv.slots do
            if not inv.items[candidate] then
                free = free + 1
            end
        end
        if free < item.amount then
            return false, 'slots'
        end
    elseif
        slot
        and inv.items[slot]
        and (inv.items[slot].name ~= item.name or not inventory.sameInfo(inv.items[slot].info, item.info))
    then
        return false, 'slots'
    elseif not inventory.stackSlot(inv.items, item) and not inventory.firstFreeSlot(inv.items, inv.slots) then
        return false, 'slots'
    end
    return true
end

---Move a secondary inventory to a new id, keeping its contents, viewers and
---durable row. ox_inventory's UpdateVehicle renames trunk/glovebox inventories
---when a plate changes; setting inv.id in place is not enough -- the registry
---is keyed by the OLD key, so the inventory stays reachable only under the old
---name while its own .key field claims otherwise.
---@return string|nil newKey, string|nil err
local function rekeySecondary(reference, newKind, newId)
    local oldKey, inv = resolveInventoryRef(reference)
    if not oldKey or not inv then
        return nil, 'inventory'
    end
    if inv.type == 'player' then
        return nil, 'player inventories cannot be rekeyed'
    end

    local newKey = key(newKind or inv.type, newId)
    if newKey == oldKey then
        return newKey
    end
    if inventories[newKey] then
        return nil, 'target inventory already exists'
    end

    -- Drop the durable row under the old identity BEFORE re-registering, so a
    -- crash between the two cannot leave the same contents persisted twice.
    local persistence = inventory.persistence
    if persistence and persistence.delete and persistence.shouldPersist and persistence.shouldPersist(inv) then
        persistence.delete(inv.type, inv.id)
    end

    inventories[oldKey] = nil
    inv.key, inv.id = newKey, newId
    if newKind then
        inv.type = newKind
    end
    inventories[newKey] = inv

    -- Any session pointing at the old key would fail every subsequent
    -- revision check, so move viewers across rather than stranding them.
    for src, session in pairs(sessions) do
        if session.primary == oldKey then
            session.primary = newKey
        end
        if session.secondary == oldKey then
            session.secondary = newKey
        end
    end

    bump(newKey)
    broadcast(newKey)
    return newKey
end

local function removeSecondaryInventory(reference)
    local inventoryKey, inv = resolveInventoryRef(reference)
    if not inventoryKey or not inv then
        return false, 'inventory not found'
    end
    if inv.type == 'player' then
        return false, 'player inventories are owned by qbcore'
    end

    inventories[inventoryKey] = nil
    if inventory.persistence and inventory.persistence.delete then
        local ok, err = inventory.persistence.delete(inv.type, inv.id)
        if not ok and inventory.persistence.getStatus and inventory.persistence.getStatus().ready then
            -- Keep the authoritative in-memory record if deleting durable
            -- storage failed, so a retry cannot silently resurrect it.
            inventories[inventoryKey] = inv
            return false, err
        end
    end
    return true
end

setInventoryItems = function(reference, items)
    local inventoryKey, inv = resolveInventoryRef(reference)
    if not inventoryKey or not inv then
        return false, 'inventory not found'
    end
    if type(items) ~= 'table' then
        return false, 'items must be a table'
    end
    if inv.type == 'player' then
        return setItems(inv.source, items)
    end
    local checked = {}
    for rawSlot, rawItem in pairs(items) do
        local slot = math.floor(tonumber(rawSlot) or 0)
        local amount = rawItem and inventory.amount(rawItem.amount or rawItem.count, 1)
        if slot < 1 or slot > inv.slots or not rawItem or not amount or not itemDef(rawItem.name) then
            return false, 'invalid item table'
        end
        local built, err = buildItem(rawItem.name, amount, slot, rawItem.info or rawItem.metadata)
        if not built then
            return false, err
        end
        copyItemExtensions(built, rawItem)
        checked[slot] = built
    end
    if inventory.totalWeight(checked) > inv.maxWeight then
        return false, 'over weight'
    end
    inv.items = checked
    if inv.type == 'shop' then
        inv.stock = inv.items
    end
    bump(inventoryKey)
    broadcast(inventoryKey)
    removeEmptyDrop(inv)
    return true
end

inventory.internal = {
    key = key,
    playerKey = playerKey,
    getInventory = getInventory,
    resolveInventory = resolveInventoryRef,
    createSecondary = secondary,
    setInventoryItems = setInventoryItems,
    removeSecondary = removeSecondaryInventory,
    rekeySecondary = rekeySecondary,
    canAdd = canAddToInventory,
    addTo = addTo,
    removeFrom = removeFrom,
    buildItem = buildItem,
    itemDef = itemDef,
    view = view,
    bump = bump,
    broadcast = broadcast,
    lock = lock,
    open = open,
    openSelf = openSelf,
    close = close,
    canAccess = canAccess,
    hasUseable = hasUseable,
    setBuiltInUseable = setBuiltInUseable,
    registerInspectionAccess = registerInspectionAccess,
    removeInspectionAccess = removeInspectionAccess,
    getRevision = revision,
    -- Read-only view of a player's live session. Compatibility bridges need the
    -- token and the two authorised inventory keys to translate a legacy request
    -- into a validated transfer; they must never be able to invent them.
    sessionOf = function(src)
        local session = sessions[src]
        if not session then
            return nil
        end
        return {
            token = session.token,
            primary = session.primary,
            secondary = session.secondary,
            expires = session.expires,
        }
    end,
    -- The validated move/split/swap funnel: token, both revisions, access,
    -- routing bucket, distance and hooks are all rechecked inside its lock.
    -- Legacy transports translate onto this instead of mutating items directly.
    transfer = function(src, request)
        return transfer(src, request)
    end,
    copy = inventory.copy,
    totalWeight = inventory.totalWeight,
    sameInfo = inventory.sameInfo,
    config = config,
    persistence = inventory.persistence,
}

-- Public exports ------------------------------------------------------------

-- Compatibility aliases. The matching __cfx handlers below make these callable
-- through the qb-inventory and ox_inventory provided identities as well.
local api = {
    getWeight = getWeight,
    canCarry = canCarry,
    addItem = addItem,
    removeItem = removeItem,
    getItemByName = getItemByName,
    getItemsByName = getItemsByName,
    getItemBySlot = getItemBySlot,
    getItemCount = getItemCount,
    hasItem = hasItem,
    getFreeSlot = getFreeSlot,
    moveItem = moveItem,
    clearInventory = clearInventory,
    setItems = setItems,
    createUseable = createUseable,
    useItem = useItem,
    stashGet = stashGet,
    stashSet = stashSet,
    stashOpen = stashOpen,
    dropCreate = dropCreate,
    dropTake = dropTake,
    AddItem = addItem,
    RemoveItem = removeItem,
    GetItemByName = getItemByName,
    GetItemsByName = getItemsByName,
    GetItemBySlot = getItemBySlot,
    GetItemCount = getItemCount,
    HasItem = hasItem,
    GetFreeSlot = getFreeSlot,
    CanAddItem = canCarry,
    GetFreeWeight = function(src)
        local currentWeight, maxWeight = getWeight(src)
        return maxWeight - currentWeight
    end,
    ClearInventory = clearInventory,
    SetInventory = setItems,
    CreateUsableItem = createUseable,
    OpenInventory = openQbInventory,
    CloseInventory = closeInventory,
    GetInventory = function(src)
        return playerItems(src)
    end,
    shopGet = shopGet,
    shopSet = shopSet,
    GetStashItems = stashGet,
    SetStashItems = stashSet,
    RegisterStash = registerStash,
    GetShopItems = shopGet,
    SetShopItems = shopSet,
    CreateTemporaryStash = createTemporaryStash,
    RegisterShop = registerShop,
    registerShop = registerShop,
    BuyItem = buyItem,
    RegisterHook = registerHook,
    RemoveHooks = removeHooks,
    registerHook = registerHook,
    removeHooks = removeHooks,
    RegisterInspectionAccess = registerInspectionAccess,
    RemoveInspectionAccess = removeInspectionAccess,
    registerInspectionAccess = registerInspectionAccess,
}

-- Every public name is reachable in BOTH cases. Half of this surface already
-- carried a lowercase alias (registerShop/registerHook/removeHooks/
-- registerInspectionAccess) and half did not, so a caller had to know which
-- half a given name fell in -- qbambulance called `registerStash` and got
-- "No such export". Alias by reference rather than re-declaring the closure,
-- so both cases stay the same function object. test/smoke/contract.lua asserts
-- the pairing, so a future one-cased addition fails the suite.
api.registerStash = api.RegisterStash
api.getShopItems = api.GetShopItems
api.setShopItems = api.SetShopItems
api.createTemporaryStash = api.CreateTemporaryStash
api.buyItem = api.BuyItem
api.getInventory = api.GetInventory
api.getFreeWeight = api.GetFreeWeight
api.removeInspectionAccess = api.RemoveInspectionAccess

-- These are qbinventory-private bridge exports for qbcore only. They are not
-- advertised through qb-inventory/ox_inventory compatibility identities.
local physicalCashApi = {
    physicalCashGet = physicalCashGet,
    physicalCashAdd = physicalCashAdd,
    physicalCashRemove = physicalCashRemove,
    physicalCashSet = physicalCashSet,
    physicalCashTransfer = physicalCashTransfer,
    physicalCashImport = physicalCashImport,
    physicalCashCanImport = physicalCashCanImport,
}
for name, fn in pairs(api) do
    exports(name, fn)
end
for name, fn in pairs(physicalCashApi) do
    exports(name, fn)
end
inventory.api = api

-- Network transport ---------------------------------------------------------

RegisterNetEvent('qbinventory:server:open', function(invType, data)
    if GetInvokingResource() then
        return
    end
    local ok, result = openInventory(source, invType, data)
    if not ok then
        TriggerClientEvent('qbinventory:client:rejected', source, result)
    end
end)
RegisterNetEvent('qbinventory:server:close', function(token)
    if GetInvokingResource() then
        return
    end
    if sessions[source] and sessions[source].token == token then
        close(source, 'requested')
    end
end)
RegisterNetEvent('qbinventory:server:transfer', function(request)
    if GetInvokingResource() then
        return
    end
    local ok, result = transfer(source, request)
    if not ok then
        TriggerClientEvent('qbinventory:client:rejected', source, result)
    end
end)
RegisterNetEvent('qbinventory:server:intent', function(request)
    if GetInvokingResource() then
        return
    end
    local ok, result = handleIntent(source, request)
    if not ok then
        TriggerClientEvent('qbinventory:client:rejected', source, result)
    end
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
    if type(item) ~= 'table' then
        return
    end
    local slot = math.floor(tonumber(item.slot) or 0)
    local owned = slot > 0 and getItemBySlot(source, slot) or nil
    if owned and owned.name == item.name then
        useItem(source, slot)
    end
end)

-- Lifecycle and persistence ------------------------------------------------

-- Persistence is deliberately a secondary-store concern. Hydrating happens
-- only after its qbsql migration succeeds; malformed rows remain quarantined
-- by that module instead of being silently loaded into live state.
AddEventHandler('qbinventory:server:persistenceReady', function()
    local persistence = inventory.persistence
    if not persistence or not persistence.restoreAll then
        return
    end
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
        TriggerEvent('qbinventory:server:persistenceRejected', inventory.copy(bad))
    end
    print(('^2[qbinventory]^7 restored %d secondary inventories.'):format(#restored))
end)

-- Writes made by another server resource through qbcore's public mutation
-- funnel remain qbcore-owned. We only advance the session revision and push a
-- replacement view, so an open shared panel cannot overwrite that change.
AddEventHandler('qbcore:server:inventoryChanged', function(src)
    if ownPlayerWrites[src] then
        return
    end
    if not getInventory(playerKey(src)) then
        return
    end
    bump(playerKey(src))
    broadcast(playerKey(src))
end)

AddEventHandler('playerDropped', function()
    close(source, 'disconnected')
end)
AddEventHandler('onResourceStop', function(name)
    if name == resourceName then
        -- Do not unregister physical cash here. A restart gap must fail closed
        -- in qbcore rather than silently create a second ledger balance.
        for src in pairs(sessions) do
            close(src, 'resource stopped')
        end
    end
    if inventory.vehicles and inventory.vehicles.cleanupResource then
        inventory.vehicles.cleanupResource(name)
    end
    for eventName, list in pairs(hooks) do
        for id, hook in pairs(list) do
            if hook.owner == name then
                list[id] = nil
            end
        end
    end
    for id, hook in pairs(inspectionHooks) do
        if hook.owner == name then
            inspectionHooks[id] = nil
        end
    end
end)

CreateThread(function()
    Wait(0)
    local policy = cashPolicy()
    if not policy then
        return
    end
    local ok, err = exports.qbcore:registerPhysicalCash(policy.account)
    if not ok then
        print(('^1[qbinventory]^7 physical cash was not enabled: %s'):format(tostring(err)))
        return
    end
    cashItemsActive = true
    print(
        ('^2[qbinventory]^7 physical cash enabled for qbcore account %s as item %s.'):format(
            policy.account,
            policy.item
        )
    )
end)

CreateThread(function()
    while true do
        Wait(5000)
        for src, session in pairs(sessions) do
            if now() > session.expires then
                close(src, 'expired')
            end
        end
    end
end)
