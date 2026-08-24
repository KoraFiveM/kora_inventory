-- qb-inventory server-realm callback bridge.
--
-- Four of upstream's NUI actions (drop discovery, dropping, buying and giving)
-- travel over QBCore callbacks rather than net events, so registering the event
-- names in qb_events.lua is not enough on its own: an unmodified qb-inventory
-- client hangs on the callback until something answers it.
--
-- REGISTRATION. qbcore's compat exposes
-- `QBCore.Functions.CreateCallback(name, fn)` as a one-line wrapper over
-- `QB.callback.register(name, fn)` which forwards the handler's RETURN VALUES.
-- It deliberately does NOT hand the handler upstream's `cb` continuation, so
-- writing upstream's literal `function(source, cb, item)` shape here would bind
-- `cb` to the first real argument and the client's callback would never
-- resolve. The bodies below are therefore upstream's logic in return-value
-- form, registered straight onto qblib -- the same registry the client compat's
-- TriggerCallback actually awaits, and one fewer load-order dependency than
-- reaching through the qbcore compat resource for an identical wrapper.
--
-- SECURITY: identical posture to qb_events.lua. The client supplies intent only
-- -- a slot, an amount, a target server id -- and every item name, weight,
-- price, metadata blob and inventory key is re-read from authoritative state
-- inside the lock that commits the change. Nothing here is a new mutation
-- primitive: drops, purchases and gives are composed from the public funnel
-- (RemoveItem/AddItem/dropCreate/BuyItem), so qbcore keeps ownership of player
-- items and the revision bump, live broadcast and audit entry stay intact.

local I = assert(QbInventory, 'qbinventory authority missing')
local internal = assert(I and I.internal, 'qbinventory internal authority must load before qb callback compatibility')
local api = assert(I.api, 'qbinventory api must load before qb callback compatibility')
local C = internal.config or {}

---Upstream's contract is a bare `cb(true/false)`, so the reason travels to the
---client on the same rejection channel qb_events.lua uses rather than as a
---second return value the caller's one-argument callback would drop anyway.
local function reject(src, reason)
    TriggerClientEvent('qbinventory:client:rejected', src, reason)
    return false
end

---A whole positive count, matching shared.lua's I.amount convention: floor it,
---then refuse anything that is not at least 1. Upstream only guards
---`amount < 0`, which lets a non-numeric or fractional amount reach the funnel.
local function count(value, fallback)
    local n = tonumber(value)
    if n == nil then n = fallback end
    if type(n) ~= 'number' or n ~= n or n < 1 then return nil end
    return math.floor(n)
end

local function slotOf(value)
    local n = tonumber(value)
    if not n or n < 1 then return nil end
    return math.floor(n)
end

---Routing bucket is authority state, so it is read from the server natives
---rather than from anything the caller sent. Mirrors server.lua's own rule.
local function sameBucket(a, b)
    if C.requireSameBucket == false then return true end
    return GetPlayerRoutingBucket(a) == GetPlayerRoutingBucket(b)
end

---Upstream blocks a give while either party is dead, downed or cuffed. The
---metadata comes from qbcore, which owns it -- never from the payload.
local function incapacitated(src)
    local metadata = exports.qbcore:getPlayerData(src, { 'metadata' })
    if type(metadata) ~= 'table' then return true end
    return metadata.isdead == true or metadata.inlaststand == true or metadata.ishandcuffed == true
end

---The caller's own inventory, and only ever that one. Upstream's drop payload
---carries an `inventory` field; accepting any spelling other than the session
---primary would let a crafted payload name a stash the caller merely knows the
---id of. Deliberately narrower than qb_events' sessionKeyFor -- there is no
---legitimate reason to drop or give out of the session's SECONDARY inventory,
---so the secondary is not reachable from here at all.
local function primaryKeyFor(session, identifier)
    if identifier == nil or identifier == 'player' or identifier == session.primary then
        return session.primary
    end
    return nil
end

-- Ids of the drops this bridge created, with their creation time. This is an
-- index, not a second authority: every read below re-resolves the id against
-- live inventory state and forgets anything that no longer exists.
local bridgeDrops = {}

-- Upstream keeps a server-side `Drops` table and hands the WHOLE thing --
-- including every drop's full item list -- to any client that asks for it.
-- Inventory contents are session-gated here, so this returns positional
-- metadata only; the coordinates are already broadcast to everyone by
-- dropCreate, so nothing new is disclosed.
--
-- Two further divergences, both consequences of drops being server-resolved in
-- this resource (see client/compat.lua's setupDropTarget note): the map is keyed
-- by the bare qbinventory drop id, because upstream's client feeds that key
-- straight back to `qb-inventory:server:openDrop`, and `entityId` is 0 because
-- qbinventory never spawns a networked bag prop -- upstream's client skips a
-- drop whose entity does not exist, which is the intended outcome.
QB.callback.register('qb-inventory:server:GetCurrentDrops', function()
    local drops = {}
    for id, createdTime in pairs(bridgeDrops) do
        local _, inventory = internal.resolveInventory(internal.key('drop', id), 'drop')
        if inventory then
            drops[id] = {
                name = 'drop-' .. id,
                label = inventory.label or 'Drop',
                entityId = 0,
                coords = inventory.coords,
                createdTime = createdTime,
                maxweight = inventory.maxWeight,
                slots = inventory.slots,
            }
        else
            bridgeDrops[id] = nil
        end
    end
    return drops
end)

-- Upstream removes `item.name`/`item.amount` exactly as the browser spelled
-- them and then stores that same client record as the drop's contents, so a
-- crafted payload mints an item. Here the payload contributes a slot and an
-- amount; the item record dropped is a copy of whatever the authority says is
-- really in that slot, and the drop's position is read from the player's ped.
QB.callback.register('qb-inventory:server:createDrop', function(src, item)
    if type(item) ~= 'table' then return false end
    local session = internal.sessionOf(src)
    if not session then return reject(src, 'no open inventory session') end
    local primary = primaryKeyFor(session, item.inventory or item.fromInventory)
    if not primary then return reject(src, 'items can only be dropped from your inventory') end

    -- Upstream's NUI sends `fromSlot`; older forks send `slot`.
    local slot = slotOf(item.fromSlot or item.slot)
    if not slot then return reject(src, 'invalid item slot') end

    return (internal.lock({ primary }, function()
        local _, inventory = internal.resolveInventory(primary)
        local owned = inventory and inventory.items[slot]
        if not owned then return reject(src, 'invalid item slot') end
        local amount = count(item.amount, owned.amount)
        if not amount or amount > owned.amount then return reject(src, 'invalid item amount') end

        local ped = GetPlayerPed(src)
        if not ped or ped == 0 then return reject(src, 'player entity unavailable') end
        local coords = GetEntityCoords(ped)

        -- Snapshot BEFORE the removal, from authority: RemoveItem reports only
        -- success, and the drop needs the real name and metadata.
        local dropped = internal.copy(owned)
        dropped.amount = amount
        dropped.slot = 1

        if not api.RemoveItem(src, owned.name, amount, slot, 'dropped item') then
            return reject(src, 'could not drop item')
        end
        local id = api.dropCreate(coords, { [1] = dropped })
        bridgeDrops[tostring(id)] = os.time()
        -- Upstream returns the bag prop's network id and its client appends
        -- 'drop-'. qbinventory has no prop, so this is the drop's own id, which
        -- is what its open path expects back.
        return id
    end))
end)

-- Upstream trusts `data.item.name`, `.slot` and `.info`, then charges the price
-- it finds at that slot. BuyItem already re-resolves the shop, its stock, the
-- price, the caller's access/distance and the payment inside one lock, so the
-- payload contributes only the shop id, the slot and the amount.
--
-- Divergence: upstream's hardcoded 10.0 shop distance is replaced by the shop
-- inventory's own configured `distance`, enforced by canAccess inside BuyItem
-- along with its group/owner policy -- the same gate qbinventory's own shop UI
-- passes through.
QB.callback.register('qb-inventory:server:attemptPurchase', function(src, data)
    if type(data) ~= 'table' or type(data.item) ~= 'table' then return false end
    local amount = count(data.amount, nil)
    if not amount then return false end
    local slot = slotOf(data.item.slot)
    if not slot then return false end

    local shopId = data.shop
    if type(shopId) == 'table' then shopId = shopId.id end
    if type(shopId) ~= 'string' and type(shopId) ~= 'number' then return false end
    -- Upstream's own prefix strip: the NUI names a shop 'shop-<id>'.
    shopId = tostring(shopId):gsub('^shop%-', '')

    local _, shop = internal.resolveInventory(internal.key('shop', shopId), 'shop')
    if not shop then return false end
    local stock = (shop.stock or shop.items or {})[slot]
    if not stock or (tonumber(stock.amount) or 0) < amount then
        return reject(src, 'out of stock')
    end
    -- The item NAME comes from the shop's stock, never from data.item.name, so
    -- the capacity check and the purchase can only ever agree.
    if not api.CanAddItem(src, stock.name, amount) then
        return reject(src, 'cannot carry that')
    end
    return (api.BuyItem(src, shopId, slot, amount))
end)

-- Upstream takes the item name, amount, slot AND metadata from the browser and
-- hands the metadata straight to the recipient. Only `target`, `slot` and
-- `amount` are read here; `item` is used solely as a fallback lookup key into
-- the caller's OWN items when the payload omits a slot, and `info` is dropped
-- entirely in favour of the source item's real metadata (AGENTS.md: metadata
-- always comes from the source item).
--
-- Divergence: upstream's hardcoded 5.0 give distance is replaced by
-- Config.qbinventory.interactionDistance (3.0 by default), which is what
-- qbinventory's own give intent enforces; the routing bucket is checked too,
-- which upstream does not do at all.
QB.callback.register('qb-inventory:server:giveItem', function(src, target, item, amount, slot, _info)
    local session = internal.sessionOf(src)
    if not session then return reject(src, 'no open inventory session') end

    target = math.floor(tonumber(target) or 0)
    if target < 1 or target == src then return reject(src, 'invalid give recipient') end
    if incapacitated(src) or incapacitated(target) then return reject(src, 'cannot give right now') end
    if not sameBucket(src, target) then return reject(src, 'different routing bucket') end

    local targetPed = GetPlayerPed(target)
    if not targetPed or targetPed == 0
        or not QB.distance.player(src, GetEntityCoords(targetPed), C.interactionDistance) then
        return reject(src, 'recipient is too far away')
    end

    local primary, targetKey = session.primary, internal.playerKey(target)
    return (internal.lock({ primary, targetKey }, function()
        local _, inventory = internal.resolveInventory(primary)
        if not inventory then return reject(src, 'inventory unavailable') end

        local chosen = slotOf(slot)
        if not chosen and type(item) == 'string' then
            -- Name lookup against the caller's own authoritative items only.
            -- It selects a slot, it never asserts what is in one.
            local wanted = item:lower()
            for candidate, held in pairs(inventory.items) do
                if type(held) == 'table' and type(held.name) == 'string' and held.name:lower() == wanted then
                    chosen = tonumber(candidate)
                    break
                end
            end
        end
        local owned = chosen and inventory.items[chosen]
        if not owned then return reject(src, 'invalid item slot') end

        local giving = count(amount, owned.amount)
        if not giving or giving > owned.amount then return reject(src, 'invalid item amount') end

        -- Refuse before removing rather than relying on the rollback.
        if not api.CanAddItem(target, owned.name, giving) then
            return reject(src, 'recipient cannot carry that')
        end

        local info = internal.copy(owned.info)
        if not api.RemoveItem(src, owned.name, giving, chosen, 'Item given to ID #' .. target) then
            return reject(src, 'could not give item')
        end
        if not api.AddItem(target, owned.name, giving, nil, info, 'Item given from ID #' .. src) then
            -- Same rollback contract as server.lua's give intent: put it back in
            -- the original slot, and be loud if even that fails.
            if not api.AddItem(src, owned.name, giving, chosen, info, 'give-rollback') then
                print(('^1[qbinventory]^7 qb give rollback failed for %s: %s'):format(primary, owned.name))
            end
            return reject(src, 'recipient could not receive item')
        end
        return true
    end))
end)

I.compat = I.compat or {}
I.compat.qbCallbacks = { drops = bridgeDrops }
