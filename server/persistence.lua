-- Durable storage for SECONDARY inventories only.
--
-- Player slots deliberately do not appear here. kora_core remains the sole owner
-- of PlayerData.items and players.inventory; this module only persists the
-- inventory records kora_inventory owns (stashes, vehicle stores, containers and
-- shops). All writes are explicit and revisioned so callers can keep mutation
-- locks in server.lua around their state transition.

KoraInventory = KoraInventory or {}
local inventory = KoraInventory
local persistence = {}
inventory.persistence = persistence

local resource = GetCurrentResourceName()
local persistenceConfig = (Config.kora_inventory and Config.kora_inventory.persistence) or {}
local state = { ready = false, migrating = false, lastError = nil, lastMigration = nil }
local dirty = {}
local writes, inflight = {}, {}

function persistence.withLock(kind, id, handler)
    local inventoryKey, owner = ('%s:%s'):format(kind, tostring(id)), coroutine.running() or 'main'
    if inflight[inventoryKey] then return false, 'inventory persistence busy' end
    if writes[inventoryKey] and writes[inventoryKey] ~= owner then return false, 'inventory persistence busy' end
    local nested = writes[inventoryKey] ~= nil
    writes[inventoryKey] = owner
    local results = table.pack(pcall(handler))
    if not nested then writes[inventoryKey] = nil end
    if not results[1] then return false, tostring(results[2]) end
    return table.unpack(results, 2, results.n)
end

function persistence.committed(inv)
    dirty[('%s:%s'):format(inv.type, tostring(inv.id))] = nil
end

local function fnv1a(str)
    local hash, prime = 0xCBF29CE484222325, 0x100000001B3
    for i = 1, #str do
        hash = hash ~ string.byte(str, i)
        hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF
    end
    return hash
end

local function checksum(str)
    local forwardHash = fnv1a(str)
    local reverseHash = fnv1a(str:reverse())
    return ('%016x%016x'):format(forwardHash, reverseHash) .. string.rep('0', 32)
end

local function encode(value)
    local ok, output = pcall(json.encode, value or {})
    return ok and output or nil
end

local function decode(value)
    if type(value) == 'table' then
        return inventory.copy(value)
    end
    if type(value) ~= 'string' then
        return nil, 'items are not JSON'
    end
    local ok, output = pcall(json.decode, value)
    if not ok or type(output) ~= 'table' then
        return nil, 'invalid JSON'
    end
    return output
end

local function isSecondaryType(kind)
    return kind == 'stash'
        or kind == 'trunk'
        or kind == 'glovebox'
        or kind == 'container'
        or kind == 'shop'
        or kind == 'temporary'
        or kind == 'drop'
        or kind == 'evidence'
end

local function cleanType(kind)
    kind = tostring(kind or 'stash'):lower()
    return isSecondaryType(kind) and kind or 'stash'
end

-- Accept the slot-keyed JSON used by qb-inventory/kora_core and tolerate the
-- `count` spelling used by ox-style records. Never invent or discard metadata.
function persistence.normaliseItems(value)
    local raw, err = decode(value)
    if not raw then
        return nil, err
    end
    local out = {}
    for rawSlot, rawItem in pairs(raw) do
        local slot = math.floor(tonumber(rawSlot) or 0)
        if slot < 1 or slot > 10000 then
            return nil, 'invalid item slot'
        end
        if type(rawItem) ~= 'table' or type(rawItem.name) ~= 'string' or rawItem.name == '' then
            return nil, 'invalid item name'
        end
        local amount = math.floor(tonumber(rawItem.amount or rawItem.count) or 0)
        if amount < 1 then
            return nil, 'invalid item amount'
        end
        local item = inventory.copy(rawItem)
        item.slot, item.amount = slot, amount
        item.info = inventory.copy(item.info or item.metadata or {})
        item.metadata = inventory.copy(item.metadata or item.info)
        out[slot] = item
    end
    return out
end

local function safeProperties(inv)
    -- Functions are runtime access policy and must never be serialised. They
    -- are supplied again by registerStash/registerShop on boot.
    return {
        coords = inv.coords,
        bucket = inv.bucket,
        distance = inv.distance,
        groups = inv.groups,
        owner = inv.owner,
        temporary = inv.temporary == true,
        stock = inv.stock,
        prices = inv.prices,
        currency = inv.currency,
        accessRequired = inv.accessRequired == true or not not inv.access,
        policyOwner = inv.policyOwner,
        blocked = inv.blocked == true,
    }
end

function persistence.shouldPersist(inv)
    if not persistenceConfig.enabled or type(inv) ~= 'table' or inv.type == 'player' then
        return false
    end
    -- The admin omnipack is a generated, read-only catalogue (server/omnipack.lua).
    if inv.omnipack == true or inv.id == 'omnipack' and inv.type == 'shop' then
        return false
    end
    if inv.type == 'drop' and not persistenceConfig.persistDrops then
        return false
    end
    if inv.temporary and not persistenceConfig.persistTemporary then
        return false
    end
    return isSecondaryType(inv.type)
end

function persistence.getStatus()
    return inventory.copy(state)
end

local function db(sql, params)
    if not state.ready then
        return nil, state.lastError or 'persistence is not ready'
    end
    return Kora.sql.execute(sql, params or {})
end

local function dbQuery(sql, params)
    if not state.ready then
        return nil, state.lastError or 'persistence is not ready'
    end
    return Kora.sql.query(sql, params or {})
end

local function dbUpsert(tableName, conflictKey, rows, opts)
    if not state.ready then
        return nil, state.lastError or 'persistence is not ready'
    end
    return Kora.sql.upsert(tableName, conflictKey, rows, opts)
end

-- One multi-row upsert per shop save instead of one query per stock slot.
-- Kora.sql.upsert (kora_sql's batched-upsert builder, the same one behind
-- enqueueMany/the hot player-save path) takes the composite `(shop_id, slot)`
-- primary key as `pk` per row and flushes a single
-- `INSERT ... VALUES (...),(...) ON DUPLICATE KEY UPDATE ...` statement.
local function saveShopStock(inv)
    if inv.type ~= 'shop' then
        return true
    end
    local rows = {}
    for slot, item in pairs(inv.stock or inv.items or {}) do
        local encoded = encode(item)
        if not encoded then
            return false, 'could not encode shop item'
        end
        rows[#rows + 1] = {
            pk = { tostring(inv.id), tonumber(slot) },
            cols = { item = encoded, revision = tonumber(inv.revision) or 0 },
        }
    end
    if not next(rows) then
        return true
    end
    local ok, err = dbUpsert('kora_inventory_shop_stock', { 'shop_id', 'slot' }, rows)
    if not ok then
        return false, err
    end
    return true
end

-- Save a fully-formed secondary inventory after server.lua has committed its
-- mutation. This never inspects player inventories and returns errors instead
-- of silently falling back to volatile state.
local function saveInventory(inv)
    if not persistence.shouldPersist(inv) then
        return true
    end
    local items, itemErr = persistence.normaliseItems(inv.items or {})
    if not items then
        return false, itemErr
    end
    local itemsJson, propertiesJson = encode(items), encode(safeProperties(inv))
    if not itemsJson or not propertiesJson then
        return false, 'could not encode inventory'
    end
    local ok, err = db(
        [[INSERT INTO `kora_inventory_inventories`
        (`inventory_type`,`inventory_id`,`label`,`slots`,`max_weight`,`revision`,`items`,`properties`)
        VALUES (?,?,?,?,?,?,?,?)
        ON DUPLICATE KEY UPDATE `label`=VALUES(`label`), `slots`=VALUES(`slots`),
          `max_weight`=VALUES(`max_weight`), `revision`=VALUES(`revision`),
          `items`=VALUES(`items`), `properties`=VALUES(`properties`)]],
        {
            cleanType(inv.type),
            tostring(inv.id),
            tostring(inv.label or inv.id),
            math.max(1, math.floor(tonumber(inv.slots) or 50)),
            math.max(0, math.floor(tonumber(inv.maxWeight or inv.maxweight) or 100000)),
            math.max(0, math.floor(tonumber(inv.revision) or 0)),
            itemsJson,
            propertiesJson,
        }
    )
    if not ok then
        return false, err
    end
    return saveShopStock(inv)
end

function persistence.save(inv)
    local inventoryKey = ('%s:%s'):format(inv.type, tostring(inv.id))
    if not inv.policyOwner then
        if writes[inventoryKey] and writes[inventoryKey] ~= (coroutine.running() or 'main') then return false, 'inventory persistence busy' end
        inflight[inventoryKey] = (inflight[inventoryKey] or 0) + 1
        local results = table.pack(pcall(saveInventory, inv))
        inflight[inventoryKey] = inflight[inventoryKey] - 1
        if inflight[inventoryKey] == 0 then inflight[inventoryKey] = nil end
        if not results[1] then return false, tostring(results[2]) end
        return table.unpack(results, 2, results.n)
    end
    return persistence.withLock(inv.type, inv.id, function()
        local snapshot = dirty[inventoryKey]
        local ok, err = saveInventory(inv)
        if ok and dirty[inventoryKey] == snapshot then dirty[inventoryKey] = nil end
        return ok, err
    end)
end

-- Queue a snapshot after a committed secondary mutation. It is intentionally
-- non-yielding, so server.lua can call it while holding its deterministic
-- inventory lock; the periodic flusher performs SQL outside that lock.
function persistence.markDirty(inv)
    if not persistence.shouldPersist(inv) then
        return false
    end
    dirty[('%s:%s'):format(cleanType(inv.type), tostring(inv.id))] = inventory.copy(inv)
    return true
end

function persistence.flush()
    if not state.ready then
        return false, state.lastError or 'persistence is not ready'
    end
    local failed = {}
    for inventoryKey, inv in pairs(dirty) do
        local ok, err = persistence.save(inv)
        if ok then
            -- A mutation may have replaced this snapshot while SQL was pending.
            if dirty[inventoryKey] == inv then
                dirty[inventoryKey] = nil
            end
        else
            failed[#failed + 1] = { key = inventoryKey, error = err }
            Kora.logging.error('persistence.save_failed', 'Inventory save failed', { inventoryKey = inventoryKey, error = tostring(err) })
        end
    end
    return #failed == 0, failed
end

function persistence.delete(kind, id)
    if kind == 'player' then
        return false, 'player inventories are owned by kora_core'
    end
    if not state.ready then
        return false, state.lastError or 'persistence is not ready'
    end
    local cleanKind, cleanId = cleanType(kind), tostring(id)
    local inventoryKey = ('%s:%s'):format(cleanKind, cleanId)
    local snapshot = dirty[inventoryKey]
    local ok, err = db(
        'DELETE FROM `kora_inventory_inventories` WHERE `inventory_type` = ? AND `inventory_id` = ?',
        { cleanKind, cleanId }
    )
    if not ok then
        return ok, err
    end
    -- A recreation may have replaced this snapshot while SQL was pending.
    if dirty[inventoryKey] == snapshot then
        dirty[inventoryKey] = nil
    end
    if cleanKind == 'shop' then
        return db('DELETE FROM `kora_inventory_shop_stock` WHERE `shop_id` = ?', { cleanId })
    end
    return true
end

-- The stock police trash command deletes native storage, not the archival
-- import source. Commit a tombstone with the delete so a later import/retry
-- cannot restore the old contents after a restart.
function persistence.deleteLegacyPoliceTrash()
    -- Every deletion needs its own receipt: an older permanent tombstone does
    -- not establish whether this attempt committed after a connection failure.
    local token, tokenError = Kora.sql.scalar("SELECT REPLACE(UUID(),'-','')")
    if type(token) ~= 'string' or #token ~= 32 or token:find('[^%x]') then
        return false, tokenError or 'inventory deletion receipt could not be created'
    end
    local called, result, err = pcall(Kora.sql.transactionChecked, {
        { query = [[INSERT INTO `kora_inventory_migration_rows`
            (`source_name`,`source_key`,`source_checksum`,`inventory_type`,`inventory_id`,`status`)
            VALUES ('inventories','stash:policetrash',?,'stash','policetrash','deleted'),
                   ('stashitems','stash:policetrash',?,'stash','policetrash','deleted')
            ON DUPLICATE KEY UPDATE `status`='deleted', `imported_at`=CURRENT_TIMESTAMP]],
          values = { string.rep('0', 64), string.rep('0', 64) } },
        { query = [[DELETE FROM `kora_inventory_inventories`
            WHERE `inventory_type` = 'stash' AND `inventory_id` = 'policetrash']] },
        -- ROW_COUNT() is the immediately preceding DELETE's durable result.
        { query = [[UPDATE `kora_inventory_migration_rows` SET `source_checksum`=CONCAT(?,':',ROW_COUNT())
            WHERE `source_name`='inventories' AND `source_key`='stash:policetrash']], values = { token }, expectedRows = 1 },
    })
    if not called then err, result = tostring(result), nil end
    if result and result.success then return true, nil, result.results[2].affectedRows end
    local failure = err or (result and result.message) or 'inventory deletion could not be confirmed'
    if result and result.code ~= 'indeterminate' then return false, failure end

    -- The caller retains the mutation and persistence locks while this yields.
    -- A locking read on the write pool waits for the original transaction even
    -- if its COMMIT acknowledgement was lost. Never release old dirty snapshots
    -- until this attempt's commit/rollback is known; another UUID is not ours.
    Kora.logging.warn('persistence.policetrash_pending', 'Policetrash deletion is awaiting durable reconciliation')
    while true do
        local readOK, snapshot = pcall(Kora.sql.transactionChecked, {
            { query = [[SELECT `source_checksum` FROM `kora_inventory_migration_rows`
                WHERE `source_name`='inventories' AND `source_key`='stash:policetrash' FOR UPDATE]] },
        })
        if readOK and snapshot and snapshot.success then
            local row = snapshot.results[1][1]
            local receipt = row and row.source_checksum
            if receipt == token .. ':0' then return true, nil, 0 end
            if receipt == token .. ':1' then return true, nil, 1 end
            return false, failure
        end
        Wait(1000)
    end
end

function persistence.load(kind, id)
    if kind == 'player' then
        return nil, 'player inventories are owned by kora_core'
    end
    local rows, err = dbQuery(
        [[SELECT `inventory_type`,`inventory_id`,`label`,`slots`,`max_weight`,`revision`,`items`,`properties`
        FROM `kora_inventory_inventories` WHERE `inventory_type` = ? AND `inventory_id` = ?]],
        { cleanType(kind), tostring(id) }
    )
    if not rows then
        return nil, err
    end
    local row = rows[1]
    if not row then
        return nil
    end
    local items, itemErr = persistence.normaliseItems(row.items)
    if not items then
        return nil, ('stored inventory is malformed: %s'):format(itemErr)
    end
    local properties = decode(row.properties or '{}') or {}
    local stock = nil
    if properties.stock then
        local stockErr
        stock, stockErr = persistence.normaliseItems(properties.stock)
        if not stock then
            return nil, ('stored shop stock is malformed: %s'):format(stockErr)
        end
    end
    -- A shop is rendered from `items` but sold from `stock`; at runtime they
    -- are one table. Both columns are saved, so restoring them separately
    -- left the panel showing the old `items` snapshot while purchases only
    -- lowered `stock` (stock looked like it refilled instantly after every
    -- restart). Purchases and restocks write `stock`, so it is authoritative.
    if row.inventory_type == 'shop' and stock then
        items = stock
    end
    return {
        type = row.inventory_type,
        id = row.inventory_id,
        label = row.label,
        slots = tonumber(row.slots),
        maxWeight = tonumber(row.max_weight),
        revision = tonumber(row.revision) or 0,
        items = items,
        coords = properties.coords,
        bucket = properties.bucket,
        distance = properties.distance,
        groups = properties.groups,
        owner = properties.owner,
        temporary = properties.temporary == true,
        stock = row.inventory_type == 'shop' and (stock or items) or nil,
        prices = properties.prices,
        currency = properties.currency,
        -- Historical rows cannot identify an omitted callback. Preserve their
        -- semantics; trusted registrations mark callbacks on future saves.
        accessRequired = properties.accessRequired == true,
        policyOwner = properties.policyOwner,
        _policyPersisted = properties.policyOwner ~= nil,
        blocked = properties.blocked == true,
    }
end

function persistence.restoreAll()
    local rows, err = dbQuery(
        [[SELECT `inventory_type`,`inventory_id`,`label`,`slots`,`max_weight`,`revision`,`items`,`properties`
        FROM `kora_inventory_inventories` ORDER BY `updated_at` ASC]],
        {}
    )
    if not rows then
        return nil, err
    end
    local restored, rejected = {}, {}
    for _, row in ipairs(rows) do
        local inv, why = persistence.load(row.inventory_type, row.inventory_id)
        if inv then
            restored[#restored + 1] = inv
        else
            rejected[#rejected + 1] = { type = row.inventory_type, id = row.inventory_id, reason = why }
        end
    end
    return restored, rejected
end

-- Item-creation audit storage (driven by server/audit_log.lua, which batches).
-- `rows` are audit entries: { at, action, citizenid, source, item, amount,
-- inventory, resource, reason }. One multi-row INSERT per batch.
local AUDIT_COLUMNS = '(`created_at`,`actor`,`action`,`inventory_type`,`inventory_id`,`details`,'
    .. '`citizenid`,`source`,`item`,`amount`,`resource`,`reason`)'
function persistence.auditInsertBatch(rows)
    if not state.ready then
        return nil, state.lastError or 'persistence is not ready'
    end
    if type(rows) ~= 'table' or #rows == 0 then
        return 0
    end
    local NULL = Kora.sql.NULL
    local marks, params = {}, {}
    for _, row in ipairs(rows) do
        local kind, id = tostring(row.inventory or ''):match('^([^:]+):(.+)$')
        marks[#marks + 1] = '(FROM_UNIXTIME(?),?,?,?,?,?,?,?,?,?,?,?)'
        local details = encode({ inventory = row.inventory }) or '{}'
        for _, value in ipairs({
            tonumber(row.at) or os.time(),
            row.citizenid or NULL,
            tostring(row.action),
            kind or NULL,
            id or NULL,
            details,
            row.citizenid or NULL,
            tonumber(row.source) or NULL,
            row.item or NULL,
            tonumber(row.amount) or NULL,
            row.resource or NULL,
            row.reason and tostring(row.reason):sub(1, 255) or NULL,
        }) do
            params[#params + 1] = value
        end
    end
    return db('INSERT INTO `kora_inventory_audit` ' .. AUDIT_COLUMNS .. ' VALUES ' .. table.concat(marks, ','), params)
end

function persistence.auditPrune(cutoff)
    return db('DELETE FROM `kora_inventory_audit` WHERE `created_at` < FROM_UNIXTIME(?)', { tonumber(cutoff) or 0 })
end

local function likeEscape(text)
    return '%' .. tostring(text):gsub('[\\%%_]', '\\%0') .. '%'
end

local function auditWhere(filter)
    local where, params = { '`created_at` >= FROM_UNIXTIME(?)' }, { tonumber(filter.since) or 0 }
    if filter.citizenid then
        where[#where + 1], params[#params + 1] = '`citizenid` = ?', filter.citizenid
    end
    if filter.source then
        where[#where + 1], params[#params + 1] = '`source` = ?', filter.source
    end
    if filter.item then
        where[#where + 1], params[#params + 1] = '`item` LIKE ?', likeEscape(filter.item)
    end
    if filter.resource then
        where[#where + 1], params[#params + 1] = '`resource` LIKE ?', likeEscape(filter.resource)
    end
    return ' WHERE ' .. table.concat(where, ' AND '), params
end

---Newest-first page. Returns (rows, hasMore). `filter` is the normalised table
---from audit_log.normaliseFilter, never raw client input.
function persistence.auditQuery(filter, limit, offset)
    limit, offset = math.floor(tonumber(limit) or 100), math.floor(tonumber(offset) or 0)
    local where, params = auditWhere(filter)
    params[#params + 1], params[#params + 2] = limit + 1, offset
    local rows, err = dbQuery(
        'SELECT UNIX_TIMESTAMP(`created_at`) AS `at`,`action`,`citizenid`,`source`,`item`,`amount`,'
            .. '`inventory_type`,`inventory_id`,`resource`,`reason` FROM `kora_inventory_audit`'
            .. where .. ' ORDER BY `created_at` DESC,`id` DESC LIMIT ? OFFSET ?',
        params
    )
    if not rows then
        return nil, err
    end
    local more = #rows > limit
    if more then
        rows[#rows] = nil
    end
    for _, row in ipairs(rows) do
        row.inventory = row.inventory_type and (row.inventory_type .. ':' .. tostring(row.inventory_id or '')) or nil
        row.inventory_type, row.inventory_id = nil, nil
    end
    return rows, more
end

---Top resources and items by added amount since `since` (unix seconds).
function persistence.auditSummary(since, limit)
    limit = math.floor(tonumber(limit) or 5)
    local summary = { resources = {}, items = {} }
    for _, spec in ipairs({ { 'resources', 'resource' }, { 'items', 'item' } }) do
        local rows, err = dbQuery(
            ('SELECT `%s` AS `name`,SUM(`amount`) AS `amount`,COUNT(*) AS `count` FROM `kora_inventory_audit` '
                .. "WHERE `created_at` >= FROM_UNIXTIME(?) AND `action` <> 'remove' AND `%s` IS NOT NULL "
                .. 'GROUP BY `%s` ORDER BY `amount` DESC LIMIT ?'):format(spec[2], spec[2], spec[2]),
            { tonumber(since) or 0, limit }
        )
        if not rows then
            return nil, err
        end
        summary[spec[1]] = rows
    end
    return summary
end

local LEGACY = {
    inventories = {
        type = 'kind',
        id = { 'identifier', 'id' },
        items = { 'items' },
        slots = { 'slots' },
        maxWeight = { 'maxweight', 'max_weight' },
    },
    stashitems = {
        type = 'stash',
        id = { 'stash', 'stashid', 'identifier', 'id' },
        items = { 'items' },
        slots = { 'slots' },
        maxWeight = { 'maxweight', 'max_weight' },
    },
    trunkitems = {
        type = 'trunk',
        id = { 'plate', 'identifier', 'id' },
        items = { 'items' },
        slots = { 'slots' },
        maxWeight = { 'maxweight', 'max_weight' },
    },
    gloveboxitems = {
        type = 'glovebox',
        id = { 'plate', 'identifier', 'id' },
        items = { 'items' },
        slots = { 'slots' },
        maxWeight = { 'maxweight', 'max_weight' },
    },
}

local function firstColumn(columns, candidates)
    for _, candidate in ipairs(candidates) do
        if columns[candidate] then
            return candidate
        end
    end
end

local function tableColumns(tableName)
    local rows, err = dbQuery(
        [[SELECT `COLUMN_NAME` FROM `INFORMATION_SCHEMA`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = ?]],
        { tableName }
    )
    if not rows then
        return nil, err
    end
    local columns = {}
    for _, row in ipairs(rows) do
        columns[row.COLUMN_NAME] = true
    end
    return columns
end

local function readLegacy(tableName)
    local shape = LEGACY[tableName]
    if not shape then
        return nil, 'unsupported legacy table'
    end
    local columns, err = tableColumns(tableName)
    if not columns then
        return nil, err
    end
    local id, items = firstColumn(columns, shape.id), firstColumn(columns, shape.items)
    if not id or not items then
        return {}, 'legacy table has no identifier/items columns'
    end
    local slots, maxWeight = firstColumn(columns, shape.slots), firstColumn(columns, shape.maxWeight)
    local kind = shape.type == 'kind' and firstColumn(columns, { 'kind', 'type' }) or nil
    local function projection(column, alias)
        return column and ('`%s` AS `%s`'):format(column, alias) or ('NULL AS `%s`'):format(alias)
    end
    local query = ('SELECT %s, %s, %s, %s, %s FROM `%s`'):format(
        projection(id, 'legacy_id'),
        projection(items, 'legacy_items'),
        projection(slots, 'legacy_slots'),
        projection(maxWeight, 'legacy_max_weight'),
        projection(kind, 'legacy_type'),
        tableName
    )
    return dbQuery(query, {})
end

local function migrationRow(source, sourceKey)
    local rows, err = dbQuery(
        [[SELECT `source_checksum`,`status` FROM `kora_inventory_migration_rows`
        WHERE `source_name` = ? AND `source_key` = ?]],
        { source, sourceKey }
    )
    if not rows then
        return nil, err
    end
    return rows[1]
end

local function writeMigrationRow(source, sourceKey, sourceChecksum, status, kind, id, err)
    return db(
        [[INSERT INTO `kora_inventory_migration_rows`
        (`source_name`,`source_key`,`source_checksum`,`inventory_type`,`inventory_id`,`status`,`error`)
        VALUES (?,?,?,?,?,?,?) ON DUPLICATE KEY UPDATE `source_checksum`=VALUES(`source_checksum`),
        `inventory_type`=VALUES(`inventory_type`), `inventory_id`=VALUES(`inventory_id`),
        `status`=VALUES(`status`), `error`=VALUES(`error`), `imported_at`=CURRENT_TIMESTAMP]],
        -- `err` is nil on the success path; bind it as a real NULL so the
        -- array keeps its seven elements.
        { source, sourceKey, sourceChecksum, kind, id, status, err or Kora.sql.NULL }
    )
end

local function quarantine(source, sourceKey, raw, reason)
    local ok, err = db(
        [[INSERT INTO `kora_inventory_quarantine` (`source_name`,`source_key`,`reason`,`raw_payload`)
        VALUES (?,?,?,?)]],
        { source, sourceKey, tostring(reason):sub(1, 255), tostring(raw) }
    )
    return ok, err
end

local function setMigrationState(source, status)
    return db(
        [[INSERT INTO `kora_inventory_migration_state`
        (`source_name`,`status`,`last_started_at`,`last_finished_at`,`imported_count`,`skipped_count`,`quarantined_count`,`last_error`)
        VALUES (?, ?, CURRENT_TIMESTAMP, NULL, 0, 0, 0, NULL)
        ON DUPLICATE KEY UPDATE `status`=VALUES(`status`), `last_started_at`=CURRENT_TIMESTAMP,
        `last_finished_at`=NULL, `last_error`=NULL]],
        { source, status }
    )
end

local function finishMigrationState(source, status, report)
    return db(
        [[UPDATE `kora_inventory_migration_state` SET `status`=?, `last_finished_at`=CURRENT_TIMESTAMP,
        `imported_count`=?, `skipped_count`=?, `quarantined_count`=?, `last_error`=? WHERE `source_name`=?]],
        { status, report.imported, report.skipped, report.quarantined, Kora.sql.NULL, source }
    )
end

local function emitProgress(report, source, phase, row)
    TriggerEvent(
        'kora_inventory:server:migrationProgress',
        inventory.copy(report),
        source,
        phase,
        row and inventory.copy(row) or nil
    )
end

local function importLegacyRowUnlocked(source, kind, id, row, opts, report)
    local sourceKey = ('%s:%s'):format(kind, id)
    if id == '' or #id > 128 then
        report.quarantined = report.quarantined + 1
        if not opts.dryRun then
            quarantine(source, sourceKey, row.legacy_items, 'invalid legacy inventory identifier')
        end
        return
    end
    local raw = type(row.legacy_items) == 'string' and row.legacy_items or encode(row.legacy_items)
    local digest = checksum((raw or '') .. '\0' .. kind .. '\0' .. id)
    local old, oldErr = migrationRow(source, sourceKey)
    if not old and oldErr then
        error(oldErr)
    end
    if old and old.status == 'deleted' then
        report.skipped = report.skipped + 1
        return
    end
    if old and old.status == 'imported' and old.source_checksum == digest then
        report.skipped = report.skipped + 1
        return
    end
    if old and old.status == 'imported' and old.source_checksum ~= digest then
        -- Never overwrite an inventory kora_inventory may already have changed.
        report.skipped = report.skipped + 1
        if not opts.dryRun then
            writeMigrationRow(source, sourceKey, digest, 'changed', kind, id, 'legacy data changed after import')
        end
        return
    end
    if old and not opts.retry then
        -- A normal run is repeat-safe: only `retry` revisits failed/quarantined
        -- rows, preventing a bad legacy row from filling quarantine repeatedly.
        report.skipped = report.skipped + 1
        return
    end
    local items, itemErr = persistence.normaliseItems(raw or '{}')
    if not items then
        report.quarantined = report.quarantined + 1
        if not opts.dryRun then
            quarantine(source, sourceKey, raw or '', itemErr)
            writeMigrationRow(source, sourceKey, digest, 'quarantined', kind, id, itemErr)
        end
        return
    end
    report.imported = report.imported + 1
    if opts.dryRun then
        return
    end
    local saved, saveErr = persistence.save({
        type = kind,
        id = id,
        label = id,
        slots = tonumber(row.legacy_slots) or Config.kora_inventory.defaultSlots,
        maxWeight = tonumber(row.legacy_max_weight) or Config.kora_inventory.defaultMaxWeight,
        revision = 0,
        items = items,
    })
    if not saved then
        error(('could not import %s: %s'):format(sourceKey, tostring(saveErr)))
    end
    local done, doneErr = writeMigrationRow(source, sourceKey, digest, 'imported', kind, id, nil)
    if not done then
        error(doneErr)
    end
end

-- Hold the same persistence lock through the import decision and save. A
-- deletion must not race a pending legacy read and resurrect its old items.
local function importLegacyRow(source, defaultType, row, opts, report)
    local id = tostring(row.legacy_id or '')
    local kind = cleanType(defaultType == 'kind' and row.legacy_type or defaultType)
    local ok, err = persistence.withLock(kind, id, function()
        importLegacyRowUnlocked(source, kind, id, row, opts, report)
        return true
    end)
    if not ok then error(err) end
end

-- Idempotent, non-destructive import. It never deletes or modifies a legacy
-- table. A changed row after a successful import is reported and left alone;
-- use an explicit operational migration rather than silently overwriting live
-- kora_inventory data.
function persistence.migrateLegacy(opts)
    opts = opts or {}
    if state.migrating then
        return nil, 'migration already running'
    end
    if not state.ready then
        return nil, state.lastError or 'persistence is not ready'
    end
    state.migrating = true
    local report = { dryRun = opts.dryRun == true, imported = 0, skipped = 0, quarantined = 0, sources = {} }
    local ok, result = xpcall(function()
        for _, source in ipairs(opts.sources or persistenceConfig.legacyTables or {}) do
            if LEGACY[source] then
                local rows, readErr = readLegacy(source)
                local sourceReport = { imported = 0, skipped = 0, quarantined = 0 }
                report.sources[source] = sourceReport
                if readErr then
                    sourceReport.error = readErr
                    report.skipped = report.skipped + 1
                else
                    if not opts.dryRun then
                        setMigrationState(source, 'running')
                    end
                    for index, row in ipairs(rows) do
                        local before =
                            { imported = report.imported, skipped = report.skipped, quarantined = report.quarantined }
                        importLegacyRow(source, LEGACY[source].type, row, opts, report)
                        sourceReport.imported = sourceReport.imported + report.imported - before.imported
                        sourceReport.skipped = sourceReport.skipped + report.skipped - before.skipped
                        sourceReport.quarantined = sourceReport.quarantined + report.quarantined - before.quarantined
                        if index % (tonumber(persistenceConfig.migrationBatchSize) or 100) == 0 then
                            emitProgress(report, source, 'importing', row)
                        end
                    end
                    if not opts.dryRun then
                        finishMigrationState(source, 'complete', sourceReport)
                    end
                end
                emitProgress(report, source, 'complete')
            end
        end
        return report
    end, debug.traceback)
    state.migrating = false
    if not ok then
        state.lastError = result
        Kora.logging.error('persistence.legacy_migration_failed', 'Legacy migration failed', { error = tostring(result) })
        return nil, result
    end
    state.lastMigration = result
    return result
end

function persistence.verifyMigration()
    if not state.ready then
        return nil, state.lastError or 'persistence is not ready'
    end
    local rows, err = dbQuery([[SELECT `inventory_type`,`inventory_id`,`items` FROM `kora_inventory_inventories`]], {})
    if not rows then
        return nil, err
    end
    local report = { checked = #rows, malformed = {} }
    for _, row in ipairs(rows) do
        local _, itemErr = persistence.normaliseItems(row.items)
        if itemErr then
            report.malformed[#report.malformed + 1] =
                { type = row.inventory_type, id = row.inventory_id, reason = itemErr }
        end
    end
    local progress, stateErr = dbQuery('SELECT * FROM `kora_inventory_migration_state` ORDER BY `source_name`', {})
    if not progress then
        return nil, stateErr
    end
    report.state = progress
    return report
end

local function bootstrap()
    if not persistenceConfig.enabled then
        state.ready = true
        Kora.logging.warn('persistence.disabled', 'Secondary persistence disabled by configuration')
        return
    end
    local sqlReady, readyErr = Kora.sql.ready(60000)
    if not sqlReady then
        state.lastError = readyErr or 'kora_sql did not become ready'
        Kora.logging.error('persistence.sql_not_ready', 'Secondary persistence unavailable', { error = tostring(state.lastError) })
        return
    end
    local reports, migrationErr = Kora.sql.ensureTables(KoraInventorySchema)
    if migrationErr then
        state.lastError = migrationErr
        Kora.logging.error('schema.setup_failed', 'Secondary-inventory schema setup failed', { error = tostring(migrationErr) })
        return
    end
    for _, report in ipairs(type(reports) == 'table' and reports or {}) do
        for _, warning in ipairs(type(report) == 'table' and report.warnings or {}) do
            Kora.logging.warn('schema.warning', 'Secondary-inventory schema warning', { warning = tostring(warning) })
        end
    end
    state.ready = true
    Kora.logging.info('schema.ready', 'Secondary-inventory schema ready')
    TriggerEvent('kora_inventory:server:persistenceReady', reports)
end

local MIGRATE_ACTIONS = {
    ['dry-run'] = {
        options = { dryRun = true },
        done = { 'migrate.dry_run_complete', 'Legacy migration dry run complete' },
        failed = { 'migrate.dry_run_failed', 'Legacy migration dry run failed' },
    },
    run = {
        options = {},
        done = { 'migrate.run_complete', 'Legacy migration complete' },
        failed = { 'migrate.run_failed', 'Legacy migration failed' },
    },
    retry = {
        options = { retry = true },
        done = { 'migrate.retry_complete', 'Legacy migration retry complete' },
        failed = { 'migrate.retry_failed', 'Legacy migration retry failed' },
    },
}

RegisterCommand('kora_inventory-migrate', function(source, args)
    if source ~= 0 and not IsPlayerAceAllowed(source, 'command.kora_inventory') then
        return TriggerClientEvent('chat:addMessage', source, { args = { 'kora_inventory', 'Permission denied.' } })
    end
    local action = (args[1] or 'help'):lower()
    CreateThread(function()
        local migrate = MIGRATE_ACTIONS[action]
        if migrate then
            local report, err = persistence.migrateLegacy(migrate.options)
            if report then
                Kora.logging.info(migrate.done[1], migrate.done[2],
                    { imported = report.imported, skipped = report.skipped, quarantined = report.quarantined })
            else
                Kora.logging.error(migrate.failed[1], migrate.failed[2], { error = tostring(err) })
            end
        elseif action == 'verify' then
            local report, err = persistence.verifyMigration()
            if report then
                Kora.logging.info('migrate.verify_complete', 'Legacy migration verification complete',
                    { checked = report.checked, malformed = #report.malformed })
            else
                Kora.logging.error('migrate.verify_failed', 'Legacy migration verification failed', { error = tostring(err) })
            end
        else
            Kora.logging.warn('migrate.usage', 'Usage: kora_inventory-migrate dry-run|run|retry|verify')
        end
    end)
end, true)

CreateThread(bootstrap)

CreateThread(function()
    while true do
        Wait(math.max(1000, tonumber(persistenceConfig.flushInterval) or 5000))
        if state.ready and next(dirty) then
            persistence.flush()
        end
    end
end)

AddEventHandler('onResourceStop', function(stopped)
    if stopped ~= resource or not state.ready or not next(dirty) then
        return
    end
    -- Resource-stop handlers may not yield safely, so flush in a dedicated
    -- coroutine. kora_sql's queue will still drain before its own shutdown when
    -- the configured startup order is respected.
    CreateThread(function()
        persistence.flush()
    end)
end)
