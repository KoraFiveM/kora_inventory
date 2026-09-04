-- qbinventory server authority. Player item writes intentionally go through
-- qbcore:setPath, preserving its dirty-column persistence and delta replication.

local C = Config.qbinventory
local I = QbInventory
local resource = GetCurrentResourceName()

local inventories, sessions, hooks, audit = {}, {}, {}, {}
local locks, nextHookId, nextDropId = {}, 1, 1
local ownPlayerWrites = {}
local inspectionHooks, nextInspectionHookId = {}, 1
-- stashSet is declared before the shared write funnel below. Forward-declare
-- it so the closure captures this local rather than resolving a nonexistent
-- global when a resource calls SetStashItems during startup.
local setInventoryItems
-- `owner = true` registrations are templates, not one globally shared stash.
-- The actual secondary record is created lazily per citizen when they open it.
local ownedStashTemplates = {}

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

-- This policy is intentionally server-only. Cash item operations are never
-- exposed to a browser or trusted from a resource-provided item payload.
local cashItemsActive = false
local function cashPolicy()
    local policy = C.cash
    if type(policy) ~= 'table' or policy.asItem ~= true then return nil end
    local item = type(policy.item) == 'string' and policy.item:lower() or nil
    local account = type(policy.account) == 'string' and policy.account:lower() or nil
    if not item or item == '' or not account or account == '' then return nil end
    local def = itemDef(item)
    if not def or def.unique then return nil end
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
        useable = def.useable == true or hasUseable(def.name or name), container = def.container == true, image = def.image, imageUrl = def.imageUrl, label = def.label or name,
        weight = def.weight or 0, shouldClose = def.shouldClose, description = def.description,
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
    local policy = C.itemBoxes
    if type(policy) ~= 'table' or policy.enabled ~= true then return end
    if action == 'add' and policy.showAdditions ~= true then return end
    if action == 'purchase' and policy.showPurchases ~= true then return end
    if action == 'remove' and policy.showRemovals ~= true then return end
    if action == 'use' and policy.showUses ~= true then return end

    local def = itemDef(name)
    if not def then return end
    local payload = {
        name = def.name or tostring(name):lower(),
        label = def.label or tostring(name),
        image = def.image,
        imageUrl = def.imageUrl,
        amount = amount,
        action = action,
        duration = math.max(750, math.floor(tonumber(policy.duration) or 2600)),
    }
    emit(src, 'qbinventory:client:itemBox', payload)
    -- The upstream name, for legacy client scripts. Argument order is
    -- upstream's (itemData, type, amount). qbinventory's own client bridge
    -- registers this as a no-op, so its UI still renders exactly one receipt
    -- from the native event above.
    emit(src, 'qb-inventory:client:ItemBox', payload, action, amount)
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

local function mayInspectPlayer(src, target)
    local policy = C.playerInspection or {}
    local allowed = false
    local function run(callback)
        local ok, result, reason = pcall(callback, src, target, I.copy(playerData(src) or {}), I.copy(playerData(target) or {}))
        if not ok then
            print(('^3[qbinventory]^7 player inspection policy failed: %s'):format(tostring(result)))
            return false, 'player inspection policy failed'
        end
        if result == false then return false, reason or 'player inspection denied' end
        if result == true then allowed = true end
        return true
    end
    if I.isCallable(policy.access) then
        local ok, err = run(policy.access)
        if not ok then return false, err end
    end
    for _, hook in pairs(inspectionHooks) do
        local ok, err = run(hook.callback)
        if not ok then return false, err end
    end
    return allowed, allowed and nil or 'player inspection not authorised'
end

-- `opts` is only ever the raw client-supplied open request (never available
-- during in-session transfer revalidation, see validSession below) -- an
-- access callback that depends on it must treat a missing opts as "already
-- gated at open time", not as a reason to fail an otherwise-valid session.
local function canAccess(src, inv, opts)
    if not inv then return false, 'inventory not found' end
    if inv.type == 'player' then
        if inv.source == src then return true end
        if not sameBucket(src, inv.source) then return false, 'different routing bucket' end
        if not QB.distance.player(src, GetEntityCoords(GetPlayerPed(inv.source)), C.interactionDistance) then
            return false, 'too far away'
        end
        return mayInspectPlayer(src, inv.source)
    end
    if inv.owner then
        local data = playerData(src)
        if not data or (inv.owner ~= src and inv.owner ~= data.citizenid) then return false, 'not owner' end
    end
    if not groupAllowed(src, inv.groups) then return false, 'not authorised' end
    if inv.access then
        local ok, allowed = pcall(inv.access, src, inv, opts)
        if not ok or not allowed then return false, 'access denied' end
    end
    if inv.coords and not QB.distance.player(src, inv.coords, inv.distance) then return false, 'too far away' end
    return true
end

local function view(k)
    local inv = getInventory(k)
    if not inv then return nil end
    local items = I.copy(inv.items)
    -- Older player records predate `imageUrl`. Resolve presentation fields from
    -- the current core registry at render time so no player-inventory migration
    -- is needed merely to adopt the remote artwork catalogue.
    for _, item in pairs(items) do
        local def = item and itemDef(item.name)
        if def then
            item.image = def.image or item.image
            item.imageUrl = def.imageUrl or item.imageUrl
            item.container = def.container == true
        end
    end
    return {
        id = inv.id, key = inv.key, type = inv.type, label = inv.label, slots = inv.slots,
        maxWeight = inv.maxWeight, weight = I.totalWeight(inv.items), revision = revision(k),
        items = items, stock = inv.stock and I.copy(inv.stock) or nil,
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
            -- Legacy qb-inventory dependants listen for this to re-read their
            -- own PlayerData after a change. qbinventory's own client bridge
            -- treats it as a refresh request, and third-party scripts that only
            -- know the upstream name now hear about committed changes at all --
            -- previously nothing outside qbinventory was ever notified.
            emit(src, 'qb-inventory:client:updateInventory')
        end
    end
end

local function lock(keys, fn)
    table.sort(keys)
    local owner = coroutine.running() or 'main'
    for _, k in ipairs(keys) do
        local held = locks[k]
        if held and held.owner ~= owner then return false, 'inventory busy' end
    end
    for _, k in ipairs(keys) do
        local held = locks[k]
        if held then held.depth = held.depth + 1 else locks[k] = { owner = owner, depth = 1 } end
    end
    local result = table.pack(xpcall(fn, debug.traceback))
    for _, k in ipairs(keys) do
        local held = locks[k]
        held.depth = held.depth - 1
        if held.depth == 0 then locks[k] = nil end
    end
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
    if not item then return false, 'empty slot' end
    amount = I.amount(amount, item.amount)
    if not amount or amount > item.amount then return false, 'not enough of item' end
    local removed = I.copy(item)
    removed.amount = amount
    if amount == item.amount then inv.items[slot] = nil else item.amount = item.amount - amount end
    return true, nil, removed
end

local function addPlayer(src, name, amount, slot, metadata, reason)
    local items = playerItems(src)
    -- Every weapon added through the public inventory surface receives the
    -- canonical server metadata, not only weapons crafted in crafting.lua.
    -- This covers shops, admin grants and compatibility callers alike.
    if I.weapons and I.weapons.isWeapon and I.weapons.prepareMetadata and I.weapons.isWeapon(name) then
        local prepared, prepareErr = I.weapons.prepareMetadata(name, metadata)
        if not prepared then return false, prepareErr end
        metadata = prepared
    end
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
            -- A multi-item grant must never duplicate an instance serial.
            if item.unique and I.weapons and I.weapons.isWeapon and I.weapons.prepareMetadata and I.weapons.isWeapon(name) then
                local individual = I.copy(metadata or {})
                individual.serial = nil
                local prepared, prepareErr = I.weapons.prepareMetadata(name, individual)
                if not prepared then return false, prepareErr end
                one.info, one.metadata = prepared, I.copy(prepared)
            end
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

-- These functions are called only by qbcore's money module. They bypass the
-- public AddItem/RemoveItem compatibility layer deliberately: that layer
-- redirects physical cash back into qbcore, while these are the one audited
-- route that changes the actual cash stack.
local function requireCashAuthority(account)
    if GetInvokingResource() ~= 'qbcore' then return nil, 'physical cash is restricted to qbcore' end
    local policy = cashPolicy()
    if not policy or policy.account ~= account then return nil, 'physical cash is not configured for this account' end
    return policy
end

local function physicalCashCanImport(src, account, amount)
    local policy, err = requireCashAuthority(account)
    if not policy then return false, err end
    amount = math.floor(tonumber(amount) or -1)
    if amount < 0 then return false, 'invalid cash amount' end
    if amount == 0 then return true end
    return canCarry(src, policy.item, amount)
end

local function physicalCashBalance(src, policy)
    local total = 0
    for _, item in pairs(playerItems(src)) do
        if type(item.name) == 'string' and item.name:lower() == policy.item then total = total + (tonumber(item.amount) or 0) end
    end
    return total
end

local function physicalCashCredit(src, policy, account, amount, reason)
    local ok, addErr = addPlayer(src, policy.item, amount, nil, {}, 'qbcore-cash:' .. tostring(reason or 'add'))
    if not ok then return false, addErr end
    bump(playerKey(src)); broadcast(playerKey(src))
    recordAudit('cash-add', src, { account = account, amount = amount, reason = reason })
    showItemBox(src, policy.item, amount, 'add')
    return true
end

local function physicalCashGet(src, account)
    local policy, err = requireCashAuthority(account)
    if not policy then return nil, err end
    return physicalCashBalance(src, policy)
end

local function physicalCashAdd(src, account, amount, reason)
    local policy, err = requireCashAuthority(account)
    amount = I.amount(amount, 0)
    if not policy then return false, err end
    if not amount then return false, 'invalid cash amount' end
    return lock({ playerKey(src) }, function()
        return physicalCashCredit(src, policy, account, amount, reason)
    end)
end

local function physicalCashDebit(src, policy, account, amount, reason)
    local items, remaining, planned = playerItems(src), amount, {}
    for slot = 1, C.playerSlots do
        local item = items[slot]
        if item and type(item.name) == 'string' and item.name:lower() == policy.item then
            local take = math.min(remaining, item.amount)
            planned[#planned + 1] = { slot = slot, amount = take }
            remaining = remaining - take
            if remaining == 0 then break end
        end
    end
    if remaining > 0 then return false, 'insufficient funds' end
    for _, part in ipairs(planned) do
        local ok, removeErr = removePlayer(src, part.slot, part.amount)
        if not ok then return false, removeErr end
    end
    bump(playerKey(src)); broadcast(playerKey(src))
    recordAudit('cash-remove', src, { account = account, amount = amount, reason = reason })
    showItemBox(src, policy.item, amount, 'remove')
    return true
end

local function physicalCashRemove(src, account, amount, reason)
    local policy, err = requireCashAuthority(account)
    amount = I.amount(amount, 0)
    if not policy then return false, err end
    if not amount then return false, 'invalid cash amount' end
    return lock({ playerKey(src) }, function()
        return physicalCashDebit(src, policy, account, amount, reason)
    end)
end

local function physicalCashSet(src, account, amount, reason)
    local policy, err = requireCashAuthority(account)
    amount = math.floor(tonumber(amount) or -1)
    if not policy then return false, err end
    if amount < 0 then return false, 'invalid cash amount' end
    local current = physicalCashBalance(src, policy)
    return lock({ playerKey(src) }, function()
        local lockedCurrent = physicalCashBalance(src, policy)
        if amount == lockedCurrent then return true end
        if amount > lockedCurrent then return physicalCashCredit(src, policy, account, amount - lockedCurrent, reason or 'set') end
        return physicalCashDebit(src, policy, account, lockedCurrent - amount, reason or 'set')
    end)
end

local function physicalCashTransfer(fromSrc, toSrc, account, amount, reason)
    local policy, err = requireCashAuthority(account)
    amount = I.amount(amount, 0)
    if not policy then return false, err end
    if not amount or fromSrc == toSrc then return false, 'invalid cash transfer' end
    if not playerData(fromSrc) or not playerData(toSrc) then return false, 'player unavailable' end
    return lock({ playerKey(fromSrc), playerKey(toSrc) }, function()
        local current = physicalCashBalance(fromSrc, policy)
        if current < amount then return false, 'insufficient funds' end
        local canReceive, carryErr = canCarry(toSrc, policy.item, amount)
        if not canReceive then return false, carryErr end
        local removed, removeErr = physicalCashDebit(fromSrc, policy, account, amount, reason or 'transfer')
        if not removed then return false, removeErr end
        local added, addErr = physicalCashCredit(toSrc, policy, account, amount, reason or 'transfer')
        if not added then
            local rolledBack, rollbackErr = physicalCashCredit(fromSrc, policy, account, amount, 'transfer-rollback')
            if not rolledBack then print(('^1[qbinventory]^7 physical cash rollback failed: %s'):format(tostring(rollbackErr))) end
            return false, addErr
        end
        recordAudit('cash-transfer', fromSrc, { to = toSrc, account = account, amount = amount, reason = reason })
        return true
    end)
end

local function physicalCashImport(src, account, amount)
    local policy, err = requireCashAuthority(account)
    amount = math.floor(tonumber(amount) or -1)
    if not policy then return false, err end
    if amount < 0 then return false, 'invalid legacy cash balance' end
    if amount == 0 then return true end
    local canImport, importErr = canCarry(src, policy.item, amount)
    if not canImport then return false, importErr end
    return lock({ playerKey(src) }, function()
        return physicalCashCredit(src, policy, account, amount, 'legacy-balance-migration')
    end)
end

-- Shop stock is only ever legitimately mutated by buyItem()'s direct
-- shop.stock manipulation (paid, price-checked) -- every OTHER write path
-- (generic transfer, the ox adapter, and anything added later) funnels
-- through addTo/removeFrom, so the read-only guard lives here once instead
-- of being re-asserted (and risking drifting error strings) at every caller.
local function addTo(k, name, amount, slot, metadata, reason)
    local inv = getInventory(k)
    if not inv then return false, 'inventory not found' end
    if inv.type == 'shop' then return false, 'shop inventory is read only' end
    if inv.type == 'player' then return addPlayer(inv.source, name, amount, slot, metadata, reason) end
    return addSecondary(inv, name, amount, slot, metadata)
end

---Removes `amount` from `slot` of any inventory.
---
---`(ok, err, removed)` on BOTH branches -- callers read the removed item from
---the third slot, and a two-value branch here silently hands them an error
---message where the item should be.
---@param k string Inventory key.
---@param slot integer
---@param amount integer|nil Defaults to the whole stack.
---@return boolean ok
---@return string|nil err
---@return table|nil removed
local function removeFrom(k, slot, amount)
    local inv = getInventory(k)
    if not inv then return false, 'inventory not found' end
    if inv.type == 'shop' then return false, 'shop items must be purchased' end
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
            -- `src` is appended as a SECOND argument (not prepended) so an
            -- existing single-arg `function(payload)` hook keeps working
            -- unmodified -- it just never reads the extra parameter.
            local ok, result = pcall(hook.callback, payload, src)
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
    local ok, err = canAccess(src, second, opts)
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
    local containerApi = QbInventory.containers
    if to.type == 'container' and containerApi and containerApi.isPortableItem and containerApi.isPortableItem(item) then
        local info = item.info or item.metadata or {}
        if info.containerId and tostring(info.containerId) == tostring(to.id) then
            return false, 'a container cannot be stored inside itself'
        end
        if not containerApi.allowNested(item) then return false, 'portable containers cannot be stored in another container' end
    end
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
    return lock({ session.primary }, function()
        local currentSession, current = validSession(src, request.token, session.primary, session.primary,
            request.primaryRevision, request.primaryRevision)
        if not currentSession or not current then return false, 'stale inventory' end
        local item = current.items[slot]
        if not item then return false, 'invalid item slot' end
        -- Captured before useItem() runs: a successful use can consume the
        -- item (or the whole stack), so `current.items[slot]` may be gone or
        -- a different record afterwards.
        local itemName, preventClose = item.name, item.preventClose == true
        local ok, err = useItem(src, slot)
        if not ok then return false, err or 'item cannot be used' end
        recordAudit('use', src, { item = itemName, slot = slot })
        return true, { preventClose = preventClose }
    end)
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

-- Giving is deliberately a separate intent from an inventory transfer.  The
-- recipient is never made a browser-visible inventory: the client resolves a
-- nearby ped locally, then the server verifies that player again immediately
-- before committing a two-player transaction.
local function intentGive(src, request)
    local session = sessions[src]
    if not session or type(request.payload) ~= 'table' then return false, 'invalid session action' end
    if request.payload.inventory and request.payload.inventory ~= session.primary then
        return false, 'items can only be given from your inventory'
    end

    local target = math.floor(tonumber(request.payload.target) or 0)
    if target < 1 or target == src or not playerData(target) then return false, 'invalid give recipient' end
    if not sameBucket(src, target) then return false, 'different routing bucket' end
    local targetPed = GetPlayerPed(target)
    if not targetPed or targetPed == 0 or not QB.distance.player(src, GetEntityCoords(targetPed), C.interactionDistance) then
        return false, 'recipient is too far away'
    end

    local _, primary = validSession(src, request.token, session.primary, session.primary, request.primaryRevision, request.primaryRevision)
    if not primary then return false, 'stale inventory' end
    local slot = math.floor(tonumber(request.payload.slot) or 0)
    local item = primary.items[slot]
    local amount = I.amount(request.payload.amount, item and item.amount)
    if not item or not amount or amount > item.amount then return false, 'invalid item amount' end

    local recipientKey = playerKey(target)
    local function recipientCanReceive(inv, sourceItem)
        local incoming = I.copy(sourceItem)
        incoming.amount = amount
        if I.totalWeight(inv.items) + I.itemWeight(incoming) > inv.maxWeight then return false, 'recipient is over weight' end
        if incoming.unique then
            local free = 0
            for candidate = 1, inv.slots do if not inv.items[candidate] then free = free + 1 end end
            if free < amount then return false, 'recipient has no free slot' end
        elseif not I.stackSlot(inv.items, incoming) and not I.firstFreeSlot(inv.items, inv.slots) then
            return false, 'recipient has no free slot'
        end
        return true
    end
    return lock({ session.primary, recipientKey }, function()
        -- The session and source revision are checked a second time inside the
        -- lock.  The target's live bucket, entity and distance are likewise
        -- re-read so an old local target selection cannot transfer remotely.
        local _, current = validSession(src, request.token, session.primary, session.primary, request.primaryRevision, request.primaryRevision)
        if not current then return false, 'stale inventory' end
        if not playerData(target) or not sameBucket(src, target) then return false, 'recipient unavailable' end
        local currentTargetPed = GetPlayerPed(target)
        if not currentTargetPed or currentTargetPed == 0
            or not QB.distance.player(src, GetEntityCoords(currentTargetPed), C.interactionDistance) then
            return false, 'recipient is too far away'
        end
        local currentItem = current.items[slot]
        if not currentItem or currentItem.name ~= item.name or currentItem.amount < amount then return false, 'source item changed' end
        local recipient = getInventory(recipientKey)
        if not recipient then return false, 'recipient unavailable' end
        local canReceive, receiveErr = recipientCanReceive(recipient, currentItem)
        if not canReceive then return false, receiveErr end

        local removedOK, removedErr, removed = removePlayer(src, slot, amount)
        if not removedOK then return false, removedErr end
        local addedOK, addedErr = addPlayer(target, removed.name, amount, nil, removed.info, 'give')
        if not addedOK then
            local rollbackOK, rollbackErr = addPlayer(src, removed.name, amount, slot, removed.info, 'give-rollback')
            if not rollbackOK then
                print(('^1[qbinventory]^7 give rollback failed for %s: %s'):format(session.primary, tostring(rollbackErr)))
            end
            return false, addedErr
        end

        bump(session.primary); bump(recipientKey)
        broadcast(session.primary); broadcast(recipientKey)
        recordAudit('give', src, { to = target, item = removed.name, amount = amount, slot = slot })
        TriggerEvent('qbinventory:server:itemsMoved', src, {
            action = 'give', fromInventory = session.primary, toInventory = recipientKey,
            fromType = 'player', toType = 'player', fromSlot = slot, itemName = removed.name,
            count = amount, metadata = I.copy(removed.info),
        })
        return true, { fromRevision = revision(session.primary), toRevision = revision(recipientKey) }
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
        local purchaseInfo = I.copy(currentItem.info or {})
        if I.weapons and I.weapons.isWeapon and I.weapons.prepareMetadata and I.weapons.isWeapon(currentItem.name) then
            local prepared, prepareErr = I.weapons.prepareMetadata(currentItem.name, purchaseInfo)
            if not prepared then return false, prepareErr end
            purchaseInfo = prepared
        end
        local added, addErr = addPlayer(src, currentItem.name, count, nil, purchaseInfo, 'purchase')
        if not added then
            if price > 0 then exports.qbcore:addMoney(src, currentShop.currency == 'money' and 'cash' or currentShop.currency, price * count, 'qbinventory-refund') end
            return false, addErr
        end
        currentItem.amount = currentItem.amount - count
        if currentItem.amount == 0 then currentShop.items[slot] = nil; if currentShop.stock then currentShop.stock[slot] = nil end end
        bump(shopKey); bump(session.primary)
        broadcast(shopKey); broadcast(session.primary)
        recordAudit('purchase', src, { shop = currentShop.id, item = currentItem.name, amount = count, price = price * count })
        showItemBox(src, currentItem.name, count, 'purchase')
        TriggerEvent('qbinventory:server:itemPurchased', src, {
            shopId = currentShop.id, itemName = currentItem.name, count = count,
            metadata = I.copy(purchaseInfo), price = price * count,
        })
        return true
    end)
end

local function handleIntent(src, request)
    if type(request) ~= 'table' or type(request.action) ~= 'string' or type(request.token) ~= 'string' then return false, 'invalid request' end
    if request.action == 'use' then return intentUse(src, request) end
    if request.action == 'drop' then return intentDrop(src, request) end
    if request.action == 'give' then return intentGive(src, request) end
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
    amount = I.amount(amount, 1)
    if cashItemsActive and isCashItemName(name) then
        -- Compatibility still works, but monetary accounting and events stay
        -- in qbcore. Never let an arbitrary resource mutate the cash stack.
        return exports.qbcore:addMoney(src, cashPolicy().account, amount, reason or 'qbinventory-add-cash')
    end
    return lock({ playerKey(src) }, function()
        local ok, err = canCarry(src, name, amount); if not ok then return false, err end
        local done, why = addPlayer(src, name, amount, slot, info, reason)
        if done then
            bump(playerKey(src)); broadcast(playerKey(src)); recordAudit('add', src, { item = name, amount = amount, reason = reason })
            showItemBox(src, name, amount, 'add')
        end
        return done, why
    end)
end
function removeItem(src, name, amount, slot, reason)
    amount = I.amount(amount, 1); if not amount then return false, 'invalid amount' end
    if cashItemsActive and isCashItemName(name) then
        return exports.qbcore:removeMoney(src, cashPolicy().account, amount, reason or 'qbinventory-remove-cash')
    end
    return lock({ playerKey(src) }, function()
        local items = playerItems(src)
        if slot then
            if not items[slot] or items[slot].name ~= name then return false, 'item not in slot' end
            local ok, err = removePlayer(src, slot, amount)
            if ok then
                bump(playerKey(src)); broadcast(playerKey(src))
                recordAudit('remove', src, { item = name, amount = amount, slot = slot, reason = reason })
                showItemBox(src, name, amount, 'remove')
            end
            return ok, err
        end
        local remaining, planned = amount, {}
        for s = 1, C.playerSlots do local item = items[s]; if item and item.name == name then planned[#planned + 1] = { slot = s, amount = math.min(remaining, item.amount) }; remaining = remaining - item.amount; if remaining <= 0 then break end end end
        if remaining > 0 then return false, 'not enough of item' end
        for _, part in ipairs(planned) do removePlayer(src, part.slot, part.amount) end
        bump(playerKey(src)); broadcast(playerKey(src)); recordAudit('remove', src, { item = name, amount = amount, reason = reason })
        showItemBox(src, name, amount, 'remove')
        return true
    end)
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
    if cashItemsActive then keeps[cashPolicy().item] = true end
    return lock({ playerKey(src) }, function()
        for slot, item in pairs(playerItems(src)) do
            if not keeps[itemNameKey(item.name)] then
                local ok, err = playerSetPath(src, { 'items', slot }, nil)
                if not ok then return false, err end
            end
        end
        bump(playerKey(src)); broadcast(playerKey(src)); return true
    end)
end
function setItems(src, newItems)
    if type(newItems) ~= 'table' then return false, 'items must be a table' end
    -- A whole-inventory replacement cannot prove that its proposed cash stack
    -- matches the ledger. Reject it instead of permitting a mint/burn bypass.
    if cashItemsActive then return false, 'SetInventory is unavailable while cash is an item' end
    local checked = {}
    for slot, item in pairs(newItems) do
        slot = tonumber(slot); local amount = item and I.amount(item.amount, 1)
        if not slot or slot < 1 or slot > C.playerSlots or not item or not itemDef(item.name) or not amount then return false, 'invalid item table' end
        local built = buildItem(item.name, amount, slot, item.info or item.metadata)
        -- Server integrations legitimately attach qb-compatible fields such
        -- as `quality`, `description` and weapon serials.  Preserve those on
        -- a validated replacement; never copy slot/name/count aliases over
        -- the canonical values derived above.
        for field, value in pairs(item) do
            if field ~= 'slot' and field ~= 'name' and field ~= 'amount' and field ~= 'count'
                and field ~= 'info' and field ~= 'metadata' and field ~= 'weight' and field ~= 'type'
                and field ~= 'unique' and field ~= 'useable' and field ~= 'label' and field ~= 'image' and field ~= 'imageUrl'
                and field ~= 'shouldClose' and field ~= 'preventClose' and field ~= 'useTime' then
                built[field] = I.copy(value)
            end
        end
        checked[slot] = built
    end
    if I.totalWeight(checked) > C.playerMaxWeight then return false, 'over weight' end
    return lock({ playerKey(src) }, function()
        local ok, err = playerSetPath(src, { 'items' }, checked)
        if not ok then return false, err end
        bump(playerKey(src)); broadcast(playerKey(src)); return true
    end)
end

local useables = {}
-- Declared on its own line first: a `local x = ... function() x end` would
-- close over the *global* x, since the local is not in scope until after its
-- own statement -- and the cleanup only runs on resource stop, so the nil
-- index would not surface until then.
local useableOwners = QB.resources.serverRegistry(function(name) useables[name] = nil end)
function createUseable(name, handler)
    assert(type(name) == 'string' and I.isCallable(handler), 'name and handler are required')
    local owner = GetInvokingResource() or resource; useables[name] = handler; useableOwners.track(owner, name)
end
-- Whether clicking Use on this item would do something even without a
-- registered handler: either a portable-container definition (useItem's own
-- container bypass, above/below), or a dynamically createUseable-registered
-- handler. buildItem() ORs this with the item/weapon definition's own static
-- `useable` flag -- a static true (e.g. phone/id_card/lockpick) still shows
-- the Use button and falls back to the legacy QBCore:Server:UseItem event
-- for whichever resource handles it (useItem's own fallback, below), same as
-- real qb-core. A bare global (like createUseable/useItem) so buildItem --
-- defined earlier in this same file, but only ever CALLED later, once every
-- top-level statement here has run -- can resolve it too.
function hasUseable(name)
    if useables[name] then return true end
    local containers = QbInventory.containers
    return containers and containers.isPortableItem and containers.isPortableItem({ name = name }) or false
end
function useItem(src, slotOrName)
    return lock({ playerKey(src) }, function()
        local item = type(slotOrName) == 'number' and getItemBySlot(src, slotOrName) or getItemByName(src, slotOrName)
        if not item then return false, 'item not found' end
        local allowed, err = runHooks('usingItem', src, { itemName = item.name, item = I.copy(item), inventoryId = playerKey(src), inventoryType = 'player' })
        if not allowed then return false, err end
        local containers = QbInventory.containers
        if type(slotOrName) == 'number' and containers and containers.isPortableItem and containers.isPortableItem(item) then
            local ok, result = containers.openConfiguredItem(src, slotOrName)
            if ok then
                TriggerEvent('qbinventory:server:openedContainer', src, item.name, item)
                return true
            end
            return false, result
        end
        local handler = useables[item.name]
        if handler then
            local ok, result = pcall(handler, src, I.copy(item))
            if not ok then return false, result end
            if result == false then return false, 'item use was rejected' end
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
    if not data or type(data.citizenid) ~= 'string' or data.citizenid == '' then return nil, 'owner identity unavailable' end
    opts = I.copy(opts or {})
    opts.owner = data.citizenid
    -- Namespace durable private storage; never trust a client-chosen owner.
    return secondary('stash', ('%s:%s'):format(tostring(identifier), data.citizenid), opts)
end

function stashGet(identifier) local inv = secondary('stash', identifier); return I.copy(inv.items) end
function stashSet(identifier, items)
    local inv = secondary('stash', identifier)
    return lock({ inv.key }, function()
        return setInventoryItems(inv.key, I.copy(items or {}))
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
function shopGet(identifier)
    local inv = getInventory(key('shop', identifier))
    if not inv then return nil, 'shop not found' end
    return I.copy(inv.stock or inv.items or {})
end
function shopSet(identifier, items)
    local inv = getInventory(key('shop', identifier))
    if not inv then return false, 'shop not found' end
    if type(items) ~= 'table' then return false, 'items must be a table' end
    return lock({ inv.key }, function()
        return setInventoryItems(inv.key, I.copy(items))
    end)
end
function stashOpen(src, identifier, opts)
    local template = ownedStashTemplates[tostring(identifier)]
    local inv, err
    if template or (type(opts) == 'table' and opts.owner == true) then
        inv, err = ownedStash(src, identifier, template or opts)
        if not inv then return false, err end
    else
        inv = secondary('stash', identifier, opts)
    end
    return open(src, inv.key, opts)
end
function dropCreate(coords, items)
    local id = nextDropId; nextDropId = nextDropId + 1
    local inv = secondary('drop', id, { label = 'Ground drop', coords = coords, distance = C.dropDistance, slots = C.defaultSlots, items = items, temporary = true })
    TriggerClientEvent('qbinventory:client:dropCreated', -1, id, coords); return id
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
    local opts = { label = label, slots = slots, maxWeight = maxWeight, owner = owner, groups = groups, coords = coords }
    if owner == true then
        ownedStashTemplates[tostring(id)] = opts
        return key('stash', id)
    end
    local inv = secondary('stash', id, opts); return inv.key
end
function createTemporaryStash(properties) properties = properties or {}; properties.temporary = true; local inv = secondary('temporary', properties.id or ('tmp-%d'):format(now()), properties); return inv.key end

-- Shop configuration is trusted server data, but it still passes through the
-- same item-definition builder as every other inventory. That keeps the NUI
-- view (label, image, weight, unique/type) canonical and stops a misspelled
-- stock row becoming an unbuyable or misleading item at runtime.
local function normaliseShopStock(rows, slots)
    if rows == nil then return {} end
    if type(rows) ~= 'table' then return nil, 'shop inventory must be a table' end
    local entries = {}
    for rawSlot, row in pairs(rows) do
        if type(row) ~= 'table' then return nil, 'invalid shop item' end
        local slot = math.floor(tonumber(row.slot or rawSlot) or 0)
        if slot < 1 or slot > slots or entries[slot] then return nil, 'invalid or duplicate shop slot' end
        local amount = I.amount(row.amount or row.count, 1)
        local price = tonumber(row.price)
        if not amount or not price or price < 0 then return nil, 'invalid shop amount or price' end
        if cashItemsActive and isCashItemName(row.name) then return nil, 'physical cash cannot be shop stock' end
        local item, err = buildItem(row.name, amount, slot, row.info or row.metadata)
        if not item then return nil, ('invalid shop item in slot %d: %s'):format(slot, tostring(err)) end
        item.price = price
        entries[slot] = item
    end
    return entries
end

function registerShop(id, data)
    data = data or {}
    local slots = math.floor(tonumber(data.slots) or C.defaultSlots)
    if slots < 1 then return nil, 'invalid shop slots' end
    local initial, stockErr = normaliseShopStock(data.inventory or data.items, slots)
    if not initial then return nil, stockErr end
    data.slots = slots
    local inv, restored = secondary('shop', id, data)
    if not restored then
        inv.stock = initial
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
    elseif invType == 'trunk' or invType == 'glovebox' then
        -- Network id is the only client intent accepted for vehicle storage.
        -- The vehicle domain resolves plate, class, coordinates and access
        -- server-side before it creates or opens any inventory key.
        if not I.vehicles or type(I.vehicles.open) ~= 'function' then return false, 'vehicle storage unavailable' end
        return I.vehicles.open(src, invType, data)
    elseif invType == 'stash' and ownedStashTemplates[tostring(type(data) == 'table' and data.id or data)] then
        local identifier = type(data) == 'table' and data.id or data
        local inv, err = ownedStash(src, identifier, ownedStashTemplates[tostring(identifier)])
        if not inv then return false, err end
        k = inv.key
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
        shop = getInventory(key('shop', shopId))
        item = shop and (shop.stock or shop.items)[slot] or nil
        if not item or item.amount < count then return false, 'out of stock' end
        price = tonumber(item.price or (shop.prices and shop.prices[item.name])) or 0
        if price > 0 then
            local paid, payErr = exports.qbcore:removeMoney(src, shop.currency == 'money' and 'cash' or shop.currency, price * count, 'qbinventory-shop')
            if not paid then return false, payErr end
        end
        local purchaseInfo = I.copy(item.info or {})
        if I.weapons and I.weapons.isWeapon and I.weapons.prepareMetadata and I.weapons.isWeapon(item.name) then
            local prepared, prepareErr = I.weapons.prepareMetadata(item.name, purchaseInfo)
            if not prepared then return false, prepareErr end
            purchaseInfo = prepared
        end
        local added, addErr = addPlayer(src, item.name, count, nil, purchaseInfo)
        if not added then if price > 0 then exports.qbcore:addMoney(src, shop.currency == 'money' and 'cash' or shop.currency, price * count, 'qbinventory-refund') end; return false, addErr end
        item.amount = item.amount - count; if item.amount == 0 then shop.stock[slot] = nil end
        bump(shop.key); bump(playerKey(src)); broadcast(shop.key); broadcast(playerKey(src)); recordAudit('purchase', src, { shop = shopId, item = item.name, amount = count, price = price * count })
        TriggerEvent('qbinventory:server:itemPurchased', src, {
            shopId = shopId, itemName = item.name, count = count,
            metadata = I.copy(purchaseInfo), price = price * count,
        })
        return true
    end)
end

function registerHook(eventName, callback, options)
    assert(type(eventName) == 'string' and I.isCallable(callback), 'eventName and callback are required')
    hooks[eventName] = hooks[eventName] or {}
    local id = nextHookId; nextHookId = nextHookId + 1
    hooks[eventName][id] = { id = id, callback = callback, options = options or {}, owner = GetInvokingResource() or resource }
    return id
end
function removeHooks(id) for _, list in pairs(hooks) do list[id] = nil end end

---Grant player inspection only through explicit trusted server policy. The
---callback receives source, target, and detached player data; it must return
---true to grant. Returning false rejects the request.
function registerInspectionAccess(callback)
    assert(I.isCallable(callback), 'inspection callback is required')
    local id = nextInspectionHookId; nextInspectionHookId = nextInspectionHookId + 1
    inspectionHooks[id] = { callback = callback, owner = GetInvokingResource() or resource }
    return id
end
function removeInspectionAccess(id) inspectionHooks[id] = nil end

-- Trusted server-side extension seam. Compatibility/domain modules load after
-- this authority and may use these helpers, but no client event ever receives
-- this table. Player writes still route through qbcore; callers must acquire
-- deterministic locks and call bump/broadcast only after a committed change.
local function resolveInventoryRef(reference, preferredType)
    if type(reference) == 'number' then
        local k = playerKey(reference)
        return k, getInventory(k)
    end
    if type(reference) == 'table' then
        if reference.key then return resolveInventoryRef(reference.key, preferredType) end
        if reference.type and reference.id ~= nil then return resolveInventoryRef(key(reference.type, reference.id)) end
        return nil, nil
    end
    if type(reference) ~= 'string' or reference == '' then return nil, nil end
    local direct = getInventory(reference)
    if direct then return reference, direct end
    if preferredType then
        local typed = key(preferredType, reference)
        local inv = getInventory(typed)
        if inv then return typed, inv end
    end
    for _, kind in ipairs({ 'stash', 'trunk', 'glovebox', 'container', 'shop', 'temporary', 'drop', 'evidence' }) do
        local typed = key(kind, reference)
        local inv = getInventory(typed)
        if inv then return typed, inv end
    end
    return nil, nil
end

local function canAddToInventory(reference, name, amount, slot, metadata)
    local k, inv = resolveInventoryRef(reference)
    local count = I.amount(amount, 1)
    local item, err
    if count then item, err = buildItem(name, count, slot, metadata)
    else err = 'invalid count' end
    if not k or not inv then return false, 'inventory' end
    if not item then return false, err or 'item' end
    if I.totalWeight(inv.items) + I.itemWeight(item) > inv.maxWeight then return false, 'weight' end
    if item.unique then
        local free = 0
        for candidate = 1, inv.slots do if not inv.items[candidate] then free = free + 1 end end
        if free < item.amount then return false, 'slots' end
    elseif slot and inv.items[slot] and (inv.items[slot].name ~= item.name or not I.sameInfo(inv.items[slot].info, item.info)) then
        return false, 'slots'
    elseif not I.stackSlot(inv.items, item) and not I.firstFreeSlot(inv.items, inv.slots) then
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
    if not oldKey or not inv then return nil, 'inventory' end
    if inv.type == 'player' then return nil, 'player inventories cannot be rekeyed' end

    local newKey = key(newKind or inv.type, newId)
    if newKey == oldKey then return newKey end
    if inventories[newKey] then return nil, 'target inventory already exists' end

    -- Drop the durable row under the old identity BEFORE re-registering, so a
    -- crash between the two cannot leave the same contents persisted twice.
    local persistence = I.persistence
    if persistence and persistence.delete and persistence.shouldPersist and persistence.shouldPersist(inv) then
        persistence.delete(inv.type, inv.id)
    end

    inventories[oldKey] = nil
    inv.key, inv.id = newKey, newId
    if newKind then inv.type = newKind end
    inventories[newKey] = inv

    -- Any session pointing at the old key would fail every subsequent
    -- revision check, so move viewers across rather than stranding them.
    for src, session in pairs(sessions) do
        if session.primary == oldKey then session.primary = newKey end
        if session.secondary == oldKey then session.secondary = newKey end
    end

    bump(newKey); broadcast(newKey)
    return newKey
end

local function removeSecondaryInventory(reference)
    local k, inv = resolveInventoryRef(reference)
    if not k or not inv then return false, 'inventory not found' end
    if inv.type == 'player' then return false, 'player inventories are owned by qbcore' end

    inventories[k] = nil
    if I.persistence and I.persistence.delete then
        local ok, err = I.persistence.delete(inv.type, inv.id)
        if not ok and I.persistence.getStatus and I.persistence.getStatus().ready then
            -- Keep the authoritative in-memory record if deleting durable
            -- storage failed, so a retry cannot silently resurrect it.
            inventories[k] = inv
            return false, err
        end
    end
    return true
end

setInventoryItems = function(reference, items)
    local k, inv = resolveInventoryRef(reference)
    if not k or not inv then return false, 'inventory not found' end
    if type(items) ~= 'table' then return false, 'items must be a table' end
    if inv.type == 'player' then return setItems(inv.source, items) end
    local checked = {}
    for rawSlot, rawItem in pairs(items) do
        local slot = math.floor(tonumber(rawSlot) or 0)
        local amount = rawItem and I.amount(rawItem.amount or rawItem.count, 1)
        if slot < 1 or slot > inv.slots or not rawItem or not amount or not itemDef(rawItem.name) then
            return false, 'invalid item table'
        end
        local built, err = buildItem(rawItem.name, amount, slot, rawItem.info or rawItem.metadata)
        if not built then return false, err end
        for field, value in pairs(rawItem) do
            if field ~= 'slot' and field ~= 'name' and field ~= 'amount' and field ~= 'count'
                and field ~= 'info' and field ~= 'metadata' and field ~= 'weight' and field ~= 'type'
                and field ~= 'unique' and field ~= 'useable' and field ~= 'label' and field ~= 'image' and field ~= 'imageUrl'
                and field ~= 'shouldClose' and field ~= 'preventClose' and field ~= 'useTime' then
                built[field] = I.copy(value)
            end
        end
        checked[slot] = built
    end
    if I.totalWeight(checked) > inv.maxWeight then return false, 'over weight' end
    inv.items = checked
    if inv.type == 'shop' then inv.stock = inv.items end
    bump(k); broadcast(k)
    return true
end

I.internal = {
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
    registerInspectionAccess = registerInspectionAccess,
    removeInspectionAccess = removeInspectionAccess,
    getRevision = revision,
    -- Read-only view of a player's live session. Compatibility bridges need the
    -- token and the two authorised inventory keys to translate a legacy request
    -- into a validated transfer; they must never be able to invent them.
    sessionOf = function(src)
        local session = sessions[src]
        if not session then return nil end
        return { token = session.token, primary = session.primary, secondary = session.secondary, expires = session.expires }
    end,
    -- The validated move/split/swap funnel: token, both revisions, access,
    -- routing bucket, distance and hooks are all rechecked inside its lock.
    -- Legacy transports translate onto this instead of mutating items directly.
    transfer = function(src, request) return transfer(src, request) end,
    copy = I.copy,
    totalWeight = I.totalWeight,
    sameInfo = I.sameInfo,
    config = C,
    persistence = I.persistence,
}

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
    shopGet = shopGet, shopSet = shopSet,
    GetStashItems = stashGet, SetStashItems = stashSet, RegisterStash = registerStash,
    GetShopItems = shopGet, SetShopItems = shopSet,
    CreateTemporaryStash = createTemporaryStash, RegisterShop = registerShop, registerShop = registerShop, BuyItem = buyItem,
    RegisterHook = registerHook, RemoveHooks = removeHooks,
    registerHook = registerHook, removeHooks = removeHooks,
    RegisterInspectionAccess = registerInspectionAccess, RemoveInspectionAccess = removeInspectionAccess,
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
    physicalCashGet = physicalCashGet, physicalCashAdd = physicalCashAdd, physicalCashRemove = physicalCashRemove,
    physicalCashSet = physicalCashSet, physicalCashTransfer = physicalCashTransfer,
    physicalCashImport = physicalCashImport, physicalCashCanImport = physicalCashCanImport,
}
for name, fn in pairs(api) do exports(name, fn) end
for name, fn in pairs(physicalCashApi) do exports(name, fn) end
I.api = api

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
    if name == resource then
        -- Do not unregister physical cash here. A restart gap must fail closed
        -- in qbcore rather than silently create a second ledger balance.
        for src in pairs(sessions) do close(src, 'resource stopped') end
    end
    if I.vehicles and I.vehicles.cleanupResource then I.vehicles.cleanupResource(name) end
    for eventName, list in pairs(hooks) do for id, hook in pairs(list) do if hook.owner == name then list[id] = nil end end end
    for id, hook in pairs(inspectionHooks) do if hook.owner == name then inspectionHooks[id] = nil end end
end)

CreateThread(function()
    Wait(0)
    local policy = cashPolicy()
    if not policy then return end
    local ok, err = exports.qbcore:registerPhysicalCash(policy.account)
    if not ok then
        print(('^1[qbinventory]^7 physical cash was not enabled: %s'):format(tostring(err)))
        return
    end
    cashItemsActive = true
    print(('^2[qbinventory]^7 physical cash enabled for qbcore account %s as item %s.'):format(policy.account, policy.item))
end)

CreateThread(function()
    while true do
        Wait(5000)
        for src, session in pairs(sessions) do if now() > session.expires then close(src, 'expired') end end
    end
end)
