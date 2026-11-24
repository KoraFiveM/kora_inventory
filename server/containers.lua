-- Secure server-only domains for item-bound containers and evidence storage.
-- This file intentionally registers no network event: callers are trusted
-- server resources and must never pass browser/client inventory payloads here.

local inventoryApi = assert(KoraInventory and KoraInventory.internal, 'kora_inventory server authority must load first')
local containerConfig =
    assert(inventoryApi.config and inventoryApi.config.containers, 'Config.kora_inventory.containers is required')

local containers = {}
local evidence = {}

local function whole(value)
    local number = math.floor(tonumber(value) or 0)
    return number > 0 and number or nil
end

local function cleanId(value)
    if type(value) ~= 'string' then
        return nil
    end
    value = value:match('^%s*(.-)%s*$')
    local limit = tonumber(containerConfig.maxIdentifierLength) or 96
    if value == '' or #value > limit or not value:match('^[%w_%-%.]+$') then
        return nil
    end
    return value
end

local function playerData(source)
    return exports.kora_core:getPlayerData(source)
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
    local inventoryKey, inventoryRecord = inventoryApi.resolveInventory(tonumber(source))
    if not inventoryKey or not inventoryRecord or inventoryRecord.type ~= 'player' then
        return nil, nil
    end
    return inventoryKey, inventoryRecord
end

local function portableDefinition(name)
    local definitions = containerConfig.items
    local definition = type(definitions) == 'table' and definitions[name] or nil
    return type(definition) == 'table' and definition or nil
end

local function itemInfo(item)
    return type(item) == 'table' and (item.info or item.metadata) or nil
end

-- Portable access is deliberately possession-based rather than owner-based:
-- handing a unique backpack to another player transfers the ability to open
-- it, but a copied/out-of-date item record cannot. This predicate reads the
-- current kora_core player slots each time core revalidates a session.
local function carrierHasContainer(source, containerId, expectedName)
    local _, inventoryRecord = currentPlayer(source)
    if not inventoryRecord then
        return false
    end
    for _, item in pairs(inventoryRecord.items or {}) do
        local info = itemInfo(item)
        if item.name == expectedName and info and cleanId(info.containerId) == containerId then
            return true
        end
    end
    return false
end

-- Search grants: a searcher who opened ANOTHER player's bag through
-- containers.openForSearcher. Server-only state, one per searcher, never taken
-- from a client. It is only a pointer: every access check below re-derives the
-- facts (target still carries the bag, still in range and bucket, search policy
-- still allows it, config still enabled), so a stale grant grants nothing.
local searchGrants = {}

local function searchConfig()
    local cfg = inventoryApi.config.search
    return type(cfg) == 'table' and cfg or {}
end

local function searcherMayOpen(source, containerId, expectedName)
    local grant = searchGrants[source]
    if not grant or grant.containerId ~= containerId or grant.name ~= expectedName then
        return false
    end
    if searchConfig().openContainers ~= true then
        return false
    end
    if source == grant.target or not carrierHasContainer(grant.target, containerId, expectedName) then
        return false
    end
    local _, targetInventory = currentPlayer(grant.target)
    if not targetInventory then
        return false
    end
    -- Same rule as opening that player's inventory: bucket, distance and the
    -- trusted inspection policy.
    local allowed = inventoryApi.canAccess(source, targetInventory)
    return allowed == true
end

local function portableOptions(item, definition)
    return {
        label = definition.label or item.label or item.name,
        slots = whole(definition.slots) or containerConfig.defaultSlots,
        maxWeight = tonumber(definition.maxWeight or definition.maxweight) or containerConfig.defaultMaxWeight,
        -- Functions are never persisted. openConfiguredItem restores this
        -- proof-of-possession policy every time a portable inventory is opened.
        -- A search grant is the only other way in, and it is re-validated on
        -- every session check (see searcherMayOpen).
        access = function(source, inventoryRecord)
            return carrierHasContainer(source, inventoryRecord.id, item.name)
                or searcherMayOpen(source, inventoryRecord.id, item.name)
        end,
        portable = true,
    }
end

local function restorePortablePolicy(container, item, definition)
    local options = portableOptions(item, definition)
    container.access = options.access
    container.label = options.label
end

local function policy(action, source, context)
    local callback = containerConfig.evidence and containerConfig.evidence.access
    if type(callback) ~= 'function' then
        return false, 'evidence access is not configured'
    end
    local ok, allowed, reason = pcall(callback, source, action, inventoryApi.copy(context or {}))
    if not ok then
        Kora.logging.warn('containers.evidence_policy_failed', 'Evidence access policy failed', { error = tostring(allowed) })
        return false, 'evidence access policy failed'
    end
    if allowed ~= true then
        return false, reason or 'evidence access denied'
    end
    return true
end

local function playerInRange(source, target, distance)
    if source == target then
        return true
    end
    local targetPed = GetPlayerPed(target)
    if not targetPed or targetPed == 0 then
        return false, 'target player unavailable'
    end
    if
        containerConfig.evidence.requireSameBucket ~= false
        and GetPlayerRoutingBucket(source) ~= GetPlayerRoutingBucket(target)
    then
        return false, 'different routing bucket'
    end
    if
        not Kora.distance.player(
            source,
            GetEntityCoords(targetPed),
            tonumber(distance) or containerConfig.evidence.distance or 3.0
        )
    then
        return false, 'too far away'
    end
    return true
end

local function containerOptions(options, owner)
    options = options or {}
    return {
        label = options.label or 'Container',
        slots = whole(options.slots) or containerConfig.defaultSlots,
        maxWeight = tonumber(options.maxWeight or options.maxweight) or containerConfig.defaultMaxWeight,
        owner = owner,
        groups = inventoryApi.copy(options.groups),
        coords = options.coords and inventoryApi.copy(options.coords) or nil,
        distance = tonumber(options.distance),
        access = options.access,
        temporary = options.temporary == true,
    }
end

local function ensureContainer(id, options)
    id = cleanId(id)
    if not id then
        return nil, 'invalid container identifier'
    end
    local containerKey, existing = inventoryApi.resolveInventory(key('container', id))
    if existing then
        return containerKey, existing
    end

    -- A general container must be bounded by an owner, group/access callback,
    -- or world coordinate. This prevents an accidentally global durable stash.
    if
        not options.owner
        and type(options.access) ~= 'function'
        and type(options.groups) ~= 'table'
        and not options.coords
    then
        return nil, 'container requires a server-side access boundary'
    end
    inventoryApi.createSecondary('container', id, options)
    containerKey, existing = inventoryApi.resolveInventory(key('container', id))
    if not existing then
        return nil, 'could not create container'
    end
    return containerKey, existing
end

---Create a bounded generic secondary container. `ownerSource` is resolved to a
---citizen id by this server; never use a client-supplied owner string.
function containers.create(id, options)
    options = options or {}
    if type(options) ~= 'table' then
        return false, 'invalid container options'
    end
    local owner
    if options.ownerSource ~= nil then
        owner = citizenId(whole(options.ownerSource))
        if not owner then
            return false, 'container owner is unavailable'
        end
    end
    local prepared = containerOptions(options, owner)
    local containerKey, inventoryRecord = ensureContainer(id, prepared)
    if not containerKey then
        return false, inventoryRecord
    end
    if options.items ~= nil then
        -- Seed items are accepted only from a trusted server call and are
        -- still checked by the authority's slot/item/weight validation.
        local ok, err = inventoryApi.setInventoryItems(containerKey, options.items)
        if not ok then
            inventoryApi.removeSecondary(containerKey)
            return false, err
        end
    end
    return true, inventoryApi.view(containerKey)
end

---Open an existing bounded generic container for a server-resolved player.
function containers.open(source, id)
    source, id = whole(source), cleanId(id)
    if not source or not id then
        return false, 'invalid container open request'
    end
    local containerKey, inventoryRecord = inventoryApi.resolveInventory(key('container', id))
    if not inventoryRecord then
        return false, 'container not found'
    end
    return inventoryApi.open(source, containerKey)
end

---Bind a container to an item currently held in a player's kora_core inventory.
---The identifier is generated server-side and written through kora_core's item
---mutation funnel; callers cannot select another player's item or owner.
function containers.bindItem(source, slot, options)
    source, slot = whole(source), whole(slot)
    if not source or not slot then
        return false, 'invalid item container request'
    end
    local playerKey, playerInventory = currentPlayer(source)
    local item = playerInventory and playerInventory.items[slot]
    options = options or {}
    if type(options) ~= 'table' then
        return false, 'invalid container options'
    end
    local owner = citizenId(source)
    if not item or (not owner and options.portable ~= true) then
        return false, 'item or player not found'
    end
    local info = item.info or item.metadata or {}
    local bound = cleanId(info.containerId)
    if bound then
        return true, bound
    end

    local suffix = ('-%d-%d-%d'):format(slot, GetGameTimer(), math.random(100000, 999999))
    local ownerPart = (owner or ('source-%d'):format(source)):gsub('[^%w_%-%.]', '_')
    local available = (tonumber(containerConfig.maxIdentifierLength) or 96) - #suffix - #'item-'
    if available < 1 then
        return false, 'container identifier limit is too small'
    end
    local generated = ('item-%s%s'):format(ownerPart:sub(1, available), suffix)
    generated = cleanId(generated)
    local prepared = containerOptions(options, options.portable ~= true and owner or nil)
    local containerKey, container = ensureContainer(generated, prepared)
    if not containerKey then
        return false, container
    end

    local items = inventoryApi.copy(playerInventory.items)
    items[slot].info = inventoryApi.copy(items[slot].info or items[slot].metadata or {})
    items[slot].info.containerId = generated
    items[slot].metadata = inventoryApi.copy(items[slot].info)
    local ok, err = inventoryApi.setInventoryItems(playerKey, items)
    if not ok then
        inventoryApi.removeSecondary(containerKey)
        return false, err
    end
    return true, generated
end

---Open a container only when its binding is present on an item in the caller's
---current kora_core-owned inventory. Slot/item data comes from the server store.
function containers.openItem(source, slot)
    source, slot = whole(source), whole(slot)
    if not source or not slot then
        return false, 'invalid item container request'
    end
    local _, playerInventory = currentPlayer(source)
    local item = playerInventory and playerInventory.items[slot]
    local info = item and (item.info or item.metadata) or nil
    local id = info and cleanId(info.containerId)
    if not id then
        return false, 'item has no server-bound container'
    end
    return containers.open(source, id)
end

---Open a configured portable container from a real, current player slot.
---This is the only item-driven entry point used by kora_inventory's use action:
---the browser provides merely a slot and the definition/access proof is
---resolved entirely on the server.
function containers.openConfiguredItem(source, slot)
    source, slot = whole(source), whole(slot)
    if not source or not slot then
        return false, 'invalid item container request'
    end
    local _, playerInventory = currentPlayer(source)
    local item = playerInventory and playerInventory.items[slot]
    local definition = item and portableDefinition(item.name)
    if not item or not definition then
        return false, 'item is not a portable container'
    end

    local options = portableOptions(item, definition)
    local info = itemInfo(item)
    local id = info and cleanId(info.containerId)
    if not id then
        local bound, result = containers.bindItem(source, slot, options)
        if not bound then
            return false, result
        end
        id = result
    end

    local containerKey, container = inventoryApi.resolveInventory(key('container', id))
    if not container then
        return false, 'bound container not found'
    end
    -- Reinstall this non-serialisable policy after storage hydration and when
    -- a backpack changes hands. The policy validates the exact current item.
    restorePortablePolicy(container, item, definition)
    return inventoryApi.open(source, containerKey)
end

---Open a configured portable container carried by ANOTHER player, for the
---searcher who is currently looking at that player's inventory. Trusted server
---call only: `targetSrc` and `slot` come from the server-validated session
---(server.lua's openTargetContainer intent), never from a browser container id.
---Every policy check is repeated here and again by the access callback on each
---later session validation. Returns the same (ok, payload|reason) as open.
function containers.openForSearcher(searcher, targetSrc, slot)
    searcher, targetSrc, slot = whole(searcher), whole(targetSrc), whole(slot)
    if not searcher or not targetSrc or not slot or searcher == targetSrc then
        return false, 'invalid search container request'
    end
    local cfg = searchConfig()
    if cfg.openContainers ~= true then
        return false, 'opening containers is disabled'
    end
    local _, targetInventory = currentPlayer(targetSrc)
    if not targetInventory then
        return false, 'target player not found'
    end
    -- Bucket, distance and the inspection policy: the same canAccess that
    -- opening that player's inventory used.
    local allowed, reason = inventoryApi.canAccess(searcher, targetInventory)
    if not allowed then
        return false, reason or 'access denied'
    end
    local item = targetInventory.items[slot]
    local definition = item and portableDefinition(item.name)
    if not item or not definition then
        return false, 'item is not a portable container'
    end
    local info = itemInfo(item)
    local id = info and cleanId(info.containerId)
    if not id then
        return false, 'container is empty'
    end
    -- Bound to this exact carried item (not merely any container with that id).
    if not carrierHasContainer(targetSrc, id, item.name) then
        return false, 'container is not carried by the target'
    end
    local containerKey, container = inventoryApi.resolveInventory(key('container', id))
    if not container then
        return false, 'bound container not found'
    end
    restorePortablePolicy(container, item, definition)
    local grant = { target = targetSrc, containerId = id, name = item.name }
    searchGrants[searcher] = grant
    local ok, result = inventoryApi.open(searcher, containerKey)
    if not ok then
        if searchGrants[searcher] == grant then
            searchGrants[searcher] = nil
        end
        return false, result
    end
    grant.token = type(result) == 'table' and result.token or nil
    return true, result
end

-- Closing the bag the searcher opened returns them to the target's inventory
-- when that is still allowed. Only a deliberate close ('requested') of THIS
-- session does so; expiry, range, cuffing and every other reason just close.
if type(AddEventHandler) == 'function' then
    AddEventHandler('kora_inventory:server:sessionClosed', function(source, session, reason)
        local grant = searchGrants[source]
        if not grant or type(session) ~= 'table' or grant.token ~= session.token then
            return
        end
        searchGrants[source] = nil
        if reason == 'requested' then
            -- Best effort: out of range or no longer allowed simply stays closed.
            inventoryApi.openInventory(source, 'player', grant.target)
        end
    end)
end

---View-only concealment for a player item that another player is searching.
---Called on the COPY a view is built from, never on stored data. Strips the
---server-bound container id (and the ox spelling) so nothing in the view can
---point at the inner inventory, and flags the slot as a closed bag. A bag's own
---weight is its definition weight; contents are never added to it, so nothing
---about them can leak through `weight` either.
---@return boolean concealed
function containers.concealForSearch(item)
    if type(item) ~= 'table' or not portableDefinition(item.name) then
        return false
    end
    local cfg = searchConfig()
    if cfg.hideContainerContents ~= false then
        for _, field in ipairs({ 'info', 'metadata' }) do
            if type(item[field]) == 'table' then
                item[field].containerId = nil
                item[field].container = nil
            end
        end
        item.closedContainer = true
    end
    item.openable = cfg.openContainers == true
    return true
end

function containers.isPortableItem(item)
    return type(item) == 'table' and portableDefinition(item.name) ~= nil
end

function containers.allowNested(item)
    local definition = type(item) == 'table' and portableDefinition(item.name) or nil
    return definition and definition.allowNested == true or false
end

local function evidenceOptions()
    return {
        label = 'evidence',
        slots = whole(containerConfig.evidence.slots) or 100,
        maxWeight = tonumber(containerConfig.evidence.maxWeight) or 150000,
        -- Persist the same policy function after hydration: serialized state
        -- must never make evidence public simply because callbacks cannot be
        -- stored in JSON.
        access = function(source, inventoryRecord)
            return policy('open', source, { evidenceId = inventoryRecord.id })
        end,
    }
end

local function evidenceInventory(id)
    id = cleanId(id)
    if not id then
        return nil, nil, 'invalid evidence identifier'
    end
    local evidenceKey, evidenceRecord = inventoryApi.resolveInventory(key('evidence', id))
    if not evidenceRecord then
        inventoryApi.createSecondary('evidence', id, evidenceOptions())
        evidenceKey, evidenceRecord = inventoryApi.resolveInventory(key('evidence', id))
    end
    if not evidenceRecord then
        return nil, nil, 'could not create evidence inventory'
    end
    evidenceRecord.access = evidenceOptions().access
    return evidenceKey, evidenceRecord
end

function evidence.open(source, id)
    source = whole(source)
    if not source then
        return false, 'invalid evidence open request'
    end
    local evidenceKey, evidenceRecord, err = evidenceInventory(id)
    if not evidenceRecord then
        return false, err
    end
    local allowed, reason = policy('open', source, { evidenceId = evidenceRecord.id })
    if not allowed then
        return false, reason
    end
    return inventoryApi.open(source, evidenceKey)
end

local function moveEvidence(action, source, target, evidenceId, slot, amount, targetSlot)
    source, target, slot = whole(source), whole(target), whole(slot)
    amount = whole(amount)
    targetSlot = targetSlot and whole(targetSlot) or nil
    if not source or not target or not slot or not amount then
        return false, 'invalid evidence transfer request'
    end
    local evidenceKey, evidenceRecord, err = evidenceInventory(evidenceId)
    if not evidenceRecord then
        return false, err
    end
    local context = { evidenceId = evidenceRecord.id, target = target, slot = slot, amount = amount }
    local allowed, reason = policy(action, source, context)
    if not allowed then
        return false, reason
    end
    local inRange, rangeReason = playerInRange(source, target)
    if not inRange then
        return false, rangeReason
    end
    local playerKey, player = currentPlayer(target)
    if not player then
        return false, 'target player not found'
    end

    local fromKey, toKey =
        action == 'seize' and playerKey or evidenceKey, action == 'seize' and evidenceKey or playerKey
    return inventoryApi.lock({ fromKey, toKey }, function()
        local sourceInventory = select(2, inventoryApi.resolveInventory(fromKey))
        local item = sourceInventory and sourceInventory.items[slot]
        if not item or amount > (tonumber(item.amount) or 0) then
            return false, 'item changed'
        end
        local canAdd, addReason = inventoryApi.canAdd(toKey, item.name, amount, targetSlot, item.info or item.metadata,
            item.gridRotated)
        if not canAdd then
            return false, addReason
        end
        local removed, removeReason, removedItem = inventoryApi.removeFrom(fromKey, slot, amount)
        if not removed then
            return false, removeReason
        end
        local added, addError = inventoryApi.addTo(
            toKey,
            removedItem.name,
            amount,
            targetSlot,
            removedItem.info or removedItem.metadata,
            'evidence-' .. action,
            nil,
            removedItem.gridRotated
        )
        if not added then
            if KoraInventory.grid and KoraInventory.grid.enabled() then
                inventoryApi.restoreRemoved(fromKey, slot, removedItem)
            else
                inventoryApi.addTo(
                    fromKey,
                    removedItem.name,
                    amount,
                    slot,
                    removedItem.info or removedItem.metadata,
                    'evidence-rollback'
                )
            end
            return false, addError
        end
        inventoryApi.bump(fromKey)
        inventoryApi.bump(toKey)
        inventoryApi.broadcast(fromKey)
        inventoryApi.broadcast(toKey)
        if TriggerEvent then
            TriggerEvent(
                'kora_inventory:server:evidenceMoved',
                action,
                source,
                target,
                evidenceRecord.id,
                inventoryApi.copy(removedItem)
            )
        end
        return true
    end)
end

---Move a server-resolved target player's item into evidence/confiscation.
function evidence.seize(source, target, evidenceId, slot, amount, evidenceSlot)
    return moveEvidence('seize', source, target, evidenceId, slot, amount, evidenceSlot)
end

---Return an evidence item to a server-resolved target player.
function evidence.release(source, target, evidenceId, slot, amount, playerSlot)
    return moveEvidence('release', source, target, evidenceId, slot, amount, playerSlot)
end

KoraInventory.containers = containers
KoraInventory.evidence = evidence
KoraInventory.confiscation = evidence

return { containers = containers, evidence = evidence }
