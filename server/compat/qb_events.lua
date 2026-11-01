-- qb-inventory server-realm net event and callback bridge.
--
-- Upstream qb-inventory drives its UI entirely over net events, so a stock
-- third-party script talks to those names rather than to exports. Registering
-- them is what makes an unmodified qb-inventory dependant work here.
--
-- SECURITY: none of these accept inventory contents from the client. Upstream's
-- SetInventoryData is a move/split/swap engine that trusts the client's
-- inventory ids; here it is translated onto kora_inventory's own validated
-- transfer funnel, which rechecks the session token, both revisions, access,
-- routing bucket and distance inside a lock. The translation can only ever name
-- the two inventories the caller's own server-issued session already
-- authorises, so a crafted payload cannot reach a third inventory.
-- test/smoke/contract.lua asserts there is no client-authorised full-inventory
-- replacement path, and that stays true.

local inventory = assert(QbInventory, 'qbinventory authority missing')
local internal =
    assert(inventory and inventory.internal, 'qbinventory internal authority must load before qb event compatibility')
local api = assert(inventory.api, 'qbinventory api must load before qb event compatibility')

local function reject(src, reason)
    TriggerClientEvent('qbinventory:client:rejected', src, reason)
    return false, reason
end

---Translate an upstream qb-inventory inventory id onto a key the caller's live
---session already holds. Returning only session keys is the security property:
---'player' is the caller's own inventory, anything else can only be whatever
---the server itself put in the secondary slot when it opened the session.
---@return string|nil
local function sessionKeyFor(session, identifier)
    if identifier == nil or identifier == 'player' then
        return session.primary
    end
    if type(identifier) ~= 'string' then
        return nil
    end

    -- 'otherplayer-<id>' addresses a player inventory; every other upstream
    -- prefix ('drop-', 'shop-', a bare stash name) addresses the secondary.
    local otherPlayer = identifier:match('^otherplayer%-(%d+)$')
    if otherPlayer then
        local key = internal.playerKey(tonumber(otherPlayer))
        return (key == session.primary or key == session.secondary) and key or nil
    end

    if session.secondary then
        local _, inventory = internal.resolveInventory(session.secondary)
        if inventory then
            -- Accept the caller's spelling only if it actually denotes the
            -- inventory the server already opened for them.
            local id = tostring(inventory.id)
            local stripped = identifier:gsub('^drop%-', ''):gsub('^shop%-', '')
            if identifier == session.secondary or stripped == id or identifier == id then
                return session.secondary
            end
        end
    end
    return nil
end

RegisterNetEvent(
    'qb-inventory:server:SetInventoryData',
    function(fromInventory, toInventory, fromSlot, toSlot, fromAmount, _toAmount)
        if type(GetInvokingResource) == 'function' and GetInvokingResource() then
            return
        end
        local src = source
        local session = internal.sessionOf(src)
        if not session then
            return reject(src, 'no open inventory session')
        end

        local fromKey = sessionKeyFor(session, fromInventory)
        local toKey = sessionKeyFor(session, toInventory)
        if not fromKey or not toKey then
            return reject(src, 'inventory not in session')
        end

        -- Supply the token and CURRENT revisions ourselves: upstream's protocol has
        -- no concept of either, and a client must never be able to assert them.
        return internal.transfer(src, {
            token = session.token,
            fromInventory = fromKey,
            toInventory = toKey,
            fromSlot = fromSlot,
            toSlot = toSlot,
            amount = fromAmount,
            fromRevision = internal.getRevision(fromKey),
            toRevision = internal.getRevision(toKey),
        })
    end
)

RegisterNetEvent('qb-inventory:server:closeInventory', function()
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    internal.close(source, 'requested')
end)

RegisterNetEvent('qb-inventory:server:useItem', function(item)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    local src = source
    -- Only the slot is read. The item's name, weight and metadata are re-read
    -- from qbcore-owned player data by useItem itself, so a forged payload
    -- cannot use an item the player does not hold.
    local slot = tonumber(type(item) == 'table' and item.slot or item)
    if not slot then
        return
    end
    api.useItem(src, slot)
end)

RegisterNetEvent('qb-inventory:server:openDrop', function(dropId)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    local src = source
    if type(dropId) ~= 'string' and type(dropId) ~= 'number' then
        return
    end
    -- Upstream addresses drops as 'drop-<id>' while kora_inventory's key is
    -- key('drop', id), so the prefix has to come off first -- forwarding it
    -- verbatim builds 'drop:drop-<id>' and never resolves.
    local id = tostring(dropId):gsub('^drop%-', '')
    -- open() runs the full access/distance/bucket check for the drop.
    api.OpenInventory(src, id, { type = 'drop', id = id })
end)

RegisterNetEvent('qb-inventory:server:openVending', function()
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    local src = source
    api.OpenInventory(src, 'vending', { type = 'shop', id = 'vending' })
end)

-- Upstream writes Drops[dropId].coords straight from the client. Position is
-- authority state here (it gates every distance check), so this is accepted as
-- a deliberate no-op rather than a client-writable field.
RegisterNetEvent('qb-inventory:server:updateDrop', function()
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
end)

-- Upstream's snowball hooks add/remove a weapon on demand from a client event.
-- Granting an item on client say-so is exactly the shape this resource refuses;
-- a server-side script wanting it can call AddItem directly.
RegisterNetEvent('qb-inventory:server:snowball', function()
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
end)

-- Older qb-inventory (1.x) use event, `(inventoryName, item)`; also accepts the
-- bare `(item)` form. Same posture as useItem above: only a slot is read, from
-- the caller's own inventory, and the item is re-resolved from player data.
local function legacyUse(first, second)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    local item = second ~= nil and second or first
    local slot = tonumber(type(item) == 'table' and item.slot or item)
    if not slot then
        return
    end
    api.useItem(source, slot)
end
RegisterNetEvent('qb-inventory:server:UseItem', legacyUse)
RegisterNetEvent('inventory:server:UseItem', legacyUse)

-- Older qb-inventory (1.x) open event: `(type, id, other)`. `other` carried a
-- client-chosen capacity or shop stock and is never read. The open is the same
-- validated path as `qbinventory:server:open`: only an inventory that already
-- exists server-side can be opened, and its access policy, owner, groups,
-- coordinates and routing bucket are enforced. A stash the server has not
-- registered is refused, never created on a client's say-so; server scripts
-- create stashes with the OpenInventory export. Trunks and gloveboxes are
-- refused too, because the legacy id is a plate and a plate is not a network id.
local legacyOpenTypes = { stash = true, shop = true, drop = true, player = true, otherplayer = true }

local function legacyOpen(invType, id)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    local src = source
    if type(invType) ~= 'string' or not legacyOpenTypes[invType:lower()] then
        return reject(src, 'inventory type not supported')
    end
    invType = invType:lower()
    if type(id) ~= 'string' and type(id) ~= 'number' then
        return reject(src, 'invalid inventory identifier')
    end
    id = tostring(id)
    if #id < 1 or #id > 96 or not id:match('^[%w_%-:]+$') then
        return reject(src, 'invalid inventory identifier')
    end
    local ok, result
    if invType == 'player' or invType == 'otherplayer' then
        local target = tonumber((id:gsub('^otherplayer%-', '')))
        if not target then
            return reject(src, 'invalid inventory identifier')
        end
        ok, result = internal.openInventory(src, 'player', target)
    else
        local prefix = invType .. '-'
        if id:sub(1, #prefix) == prefix then
            id = id:sub(#prefix + 1)
        end
        ok, result = internal.openInventory(src, invType, { id = id })
    end
    if not ok then
        reject(src, result)
    end
end
RegisterNetEvent('qb-inventory:server:OpenInventory', legacyOpen)
RegisterNetEvent('inventory:server:OpenInventory', legacyOpen)

-- Older qb-inventory marked a stash open or closed from the client. Open state
-- is the server session here and a client must never be able to flip it, so
-- these are accepted as no-ops.
RegisterNetEvent('qb-inventory:server:SetIsOpenState', function() end)
RegisterNetEvent('inventory:server:SetIsOpenState', function() end)

inventory.compat = inventory.compat or {}
inventory.compat.qbEvents = { sessionKeyFor = sessionKeyFor }
