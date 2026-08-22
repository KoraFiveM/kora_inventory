-- Secure server-only domains for item-bound containers and evidence storage.
-- This file intentionally registers no network event: callers are trusted
-- server resources and must never pass browser/client inventory payloads here.

local I = assert(QbInventory and QbInventory.internal, 'qbinventory server authority must load first')
local C = assert(I.config and I.config.containers, 'Config.qbinventory.containers is required')

local Containers = {}
local Evidence = {}

local function whole(value)
    local number = math.floor(tonumber(value) or 0)
    return number > 0 and number or nil
end

local function cleanId(value)
    if type(value) ~= 'string' then return nil end
    value = value:match('^%s*(.-)%s*$')
    local limit = tonumber(C.maxIdentifierLength) or 96
    if value == '' or #value > limit or not value:match('^[%w_%-%.]+$') then return nil end
    return value
end

local function playerData(source)
    return exports.qbcore:getPlayerData(source)
end

local function citizenId(source)
    local data = playerData(source)
    local id = data and (data.citizenid or data.citizenId)
    return type(id) == 'string' and id ~= '' and id or nil
end

local function key(kind, id)
    return ('%s:%s'):format(kind, id)
end

local function currentPlayer(source)
    local inventoryKey, inventory = I.resolveInventory(tonumber(source))
    if not inventoryKey or not inventory or inventory.type ~= 'player' then return nil, nil end
    return inventoryKey, inventory
end

local function policy(action, source, context)
    local callback = C.evidence and C.evidence.access
    if type(callback) ~= 'function' then return false, 'evidence access is not configured' end
    local ok, allowed, reason = pcall(callback, source, action, I.copy(context or {}))
    if not ok then
        print(('^3[qbinventory]^7 evidence access policy failed: %s'):format(tostring(allowed)))
        return false, 'evidence access policy failed'
    end
    if allowed ~= true then return false, reason or 'evidence access denied' end
    return true
end

local function playerInRange(source, target, distance)
    if source == target then return true end
    local targetPed = GetPlayerPed(target)
    if not targetPed or targetPed == 0 then return false, 'target player unavailable' end
    if C.evidence.requireSameBucket ~= false and GetPlayerRoutingBucket(source) ~= GetPlayerRoutingBucket(target) then
        return false, 'different routing bucket'
    end
    if not QB.distance.player(source, GetEntityCoords(targetPed), tonumber(distance) or C.evidence.distance or 3.0) then
        return false, 'too far away'
    end
    return true
end

local function containerOptions(options, owner)
    options = options or {}
    return {
        label = options.label or 'Container',
        slots = whole(options.slots) or C.defaultSlots,
        maxWeight = tonumber(options.maxWeight or options.maxweight) or C.defaultMaxWeight,
        owner = owner,
        groups = I.copy(options.groups),
        coords = options.coords and I.copy(options.coords) or nil,
        distance = tonumber(options.distance),
        access = options.access,
        temporary = options.temporary == true,
    }
end

local function ensureContainer(id, options)
    id = cleanId(id)
    if not id then return nil, 'invalid container identifier' end
    options = options or {}
    local containerKey, existing = I.resolveInventory(key('container', id))
    if existing then return containerKey, existing end

    -- A general container must be bounded by an owner, group/access callback,
    -- or world coordinate. This prevents an accidentally global durable stash.
    if not options.owner and type(options.access) ~= 'function' and type(options.groups) ~= 'table' and not options.coords then
        return nil, 'container requires a server-side access boundary'
    end
    I.createSecondary('container', id, options)
    containerKey, existing = I.resolveInventory(key('container', id))
    if not existing then return nil, 'could not create container' end
    return containerKey, existing
end

---Create a bounded generic secondary container. `ownerSource` is resolved to a
---citizen id by this server; never use a client-supplied owner string.
function Containers.create(id, options)
    options = options or {}
    if type(options) ~= 'table' then return false, 'invalid container options' end
    local owner
    if options.ownerSource ~= nil then
        owner = citizenId(whole(options.ownerSource))
        if not owner then return false, 'container owner is unavailable' end
    end
    local prepared = containerOptions(options, owner)
    local containerKey, inventory = ensureContainer(id, prepared)
    if not containerKey then return false, inventory end
    if options.items ~= nil then
        -- Seed items are accepted only from a trusted server call and are
        -- still checked by the authority's slot/item/weight validation.
        local ok, err = I.setInventoryItems(containerKey, options.items)
        if not ok then
            I.removeSecondary(containerKey)
            return false, err
        end
    end
    return true, I.view(containerKey)
end

---Open an existing bounded generic container for a server-resolved player.
function Containers.open(source, id)
    source, id = whole(source), cleanId(id)
    if not source or not id then return false, 'invalid container open request' end
    local containerKey, inventory = I.resolveInventory(key('container', id))
    if not inventory then return false, 'container not found' end
    return I.open(source, containerKey)
end

---Bind a container to an item currently held in a player's qbcore inventory.
---The identifier is generated server-side and written through qbcore's item
---mutation funnel; callers cannot select another player's item or owner.
function Containers.bindItem(source, slot, options)
    source, slot = whole(source), whole(slot)
    if not source or not slot then return false, 'invalid item container request' end
    local playerKey, inventory = currentPlayer(source)
    local item = inventory and inventory.items[slot]
    local owner = citizenId(source)
    if not item or not owner then return false, 'item or player not found' end
    local info = item.info or item.metadata or {}
    local bound = cleanId(info.containerId)
    if bound then return true, bound end

    options = options or {}
    if type(options) ~= 'table' then return false, 'invalid container options' end
    local suffix = ('-%d-%d-%d'):format(slot, GetGameTimer(), math.random(100000, 999999))
    local ownerPart = owner:gsub('[^%w_%-%.]', '_')
    local available = (tonumber(C.maxIdentifierLength) or 96) - #suffix - #'item-'
    if available < 1 then return false, 'container identifier limit is too small' end
    local generated = ('item-%s%s'):format(ownerPart:sub(1, available), suffix)
    generated = cleanId(generated)
    local prepared = containerOptions(options, owner)
    local containerKey, container = ensureContainer(generated, prepared)
    if not containerKey then return false, container end

    local items = I.copy(inventory.items)
    items[slot].info = I.copy(items[slot].info or items[slot].metadata or {})
    items[slot].info.containerId = generated
    items[slot].metadata = I.copy(items[slot].info)
    local ok, err = I.setInventoryItems(playerKey, items)
    if not ok then
        I.removeSecondary(containerKey)
        return false, err
    end
    return true, generated
end

---Open a container only when its binding is present on an item in the caller's
---current qbcore-owned inventory. Slot/item data comes from the server store.
function Containers.openItem(source, slot)
    source, slot = whole(source), whole(slot)
    if not source or not slot then return false, 'invalid item container request' end
    local _, inventory = currentPlayer(source)
    local item = inventory and inventory.items[slot]
    local info = item and (item.info or item.metadata) or nil
    local id = info and cleanId(info.containerId)
    if not id then return false, 'item has no server-bound container' end
    return Containers.open(source, id)
end

local function evidenceOptions()
    return {
        label = 'Evidence',
        slots = whole(C.evidence.slots) or 100,
        maxWeight = tonumber(C.evidence.maxWeight) or 150000,
        -- Persist the same policy function after hydration: serialized state
        -- must never make evidence public simply because callbacks cannot be
        -- stored in JSON.
        access = function(source, inventory)
            return policy('open', source, { evidenceId = inventory.id })
        end,
    }
end

local function evidenceInventory(id)
    id = cleanId(id)
    if not id then return nil, nil, 'invalid evidence identifier' end
    local evidenceKey, inventory = I.resolveInventory(key('evidence', id))
    if not inventory then
        I.createSecondary('evidence', id, evidenceOptions())
        evidenceKey, inventory = I.resolveInventory(key('evidence', id))
    end
    if not inventory then return nil, nil, 'could not create evidence inventory' end
    inventory.access = evidenceOptions().access
    return evidenceKey, inventory
end

function Evidence.open(source, id)
    source = whole(source)
    if not source then return false, 'invalid evidence open request' end
    local evidenceKey, inventory, err = evidenceInventory(id)
    if not inventory then return false, err end
    local allowed, reason = policy('open', source, { evidenceId = inventory.id })
    if not allowed then return false, reason end
    return I.open(source, evidenceKey)
end

local function moveEvidence(action, source, target, evidenceId, slot, amount, targetSlot)
    source, target, slot = whole(source), whole(target), whole(slot)
    amount = whole(amount)
    targetSlot = targetSlot and whole(targetSlot) or nil
    if not source or not target or not slot or not amount then return false, 'invalid evidence transfer request' end
    local evidenceKey, evidence, err = evidenceInventory(evidenceId)
    if not evidence then return false, err end
    local context = { evidenceId = evidence.id, target = target, slot = slot, amount = amount }
    local allowed, reason = policy(action, source, context)
    if not allowed then return false, reason end
    local inRange, rangeReason = playerInRange(source, target)
    if not inRange then return false, rangeReason end
    local playerKey, player = currentPlayer(target)
    if not player then return false, 'target player not found' end

    local fromKey, toKey = action == 'seize' and playerKey or evidenceKey, action == 'seize' and evidenceKey or playerKey
    return I.lock({ fromKey, toKey }, function()
        local sourceInventory = select(2, I.resolveInventory(fromKey))
        local destinationInventory = select(2, I.resolveInventory(toKey))
        local item = sourceInventory and sourceInventory.items[slot]
        if not item or amount > (tonumber(item.amount) or 0) then return false, 'item changed' end
        local canAdd, addReason = I.canAdd(toKey, item.name, amount, targetSlot, item.info or item.metadata)
        if not canAdd then return false, addReason end
        local removed, removeReason, removedItem = I.removeFrom(fromKey, slot, amount)
        if not removed then return false, removeReason end
        local added, addError = I.addTo(toKey, removedItem.name, amount, targetSlot, removedItem.info or removedItem.metadata, 'evidence-' .. action)
        if not added then
            I.addTo(fromKey, removedItem.name, amount, slot, removedItem.info or removedItem.metadata, 'evidence-rollback')
            return false, addError
        end
        I.bump(fromKey); I.bump(toKey)
        I.broadcast(fromKey); I.broadcast(toKey)
        if TriggerEvent then
            TriggerEvent('qbinventory:server:evidenceMoved', action, source, target, evidence.id, I.copy(removedItem))
        end
        return true
    end)
end

---Move a server-resolved target player's item into evidence/confiscation.
function Evidence.seize(source, target, evidenceId, slot, amount, evidenceSlot)
    return moveEvidence('seize', source, target, evidenceId, slot, amount, evidenceSlot)
end

---Return an evidence item to a server-resolved target player.
function Evidence.release(source, target, evidenceId, slot, amount, playerSlot)
    return moveEvidence('release', source, target, evidenceId, slot, amount, playerSlot)
end

QbInventory.containers = Containers
QbInventory.evidence = Evidence
QbInventory.confiscation = Evidence

return { containers = Containers, evidence = Evidence }
